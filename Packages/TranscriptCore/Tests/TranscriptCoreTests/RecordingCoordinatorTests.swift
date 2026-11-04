import XCTest
@testable import TranscriptCore

@MainActor
final class RecordingCoordinatorTests: XCTestCase {
    private var store: FileSessionStore!
    private var engine: MockEngine!
    private var clock: TestClock!
    private var coordinator: RecordingCoordinator!

    override func setUp() async throws {
        store = FileSessionStore(rootDirectory: try makeTempDirectory())
        engine = MockEngine()
        clock = TestClock()
        let clock = clock!
        coordinator = RecordingCoordinator(
            store: store,
            engine: engine,
            autosaveInterval: .seconds(3600),
            now: { clock.now() }
        )
    }

    func testFullSessionLifecycle() async throws {
        try await coordinator.start(language: "en-US", saveAudio: false)
        XCTAssertEqual(coordinator.state, .recording)
        XCTAssertNil(engine.configurations.first?.audioDirectory)
        let id = try XCTUnwrap(coordinator.session?.id)
        XCTAssertEqual(try store.load(id: id).startedAt, t0, "session is saved as soon as it starts")

        coordinator.handle(.volatile("Hello wor"))
        XCTAssertEqual(coordinator.volatileText, "Hello wor")
        coordinator.handle(.final(text: " Hello world. ", start: at(1), end: at(2)))
        XCTAssertEqual(coordinator.volatileText, "")
        coordinator.handle(.final(text: "   ", start: at(2), end: at(3)))
        XCTAssertEqual(coordinator.session?.speechSegments.map(\.text), ["Hello world."])

        clock.advance(10)
        coordinator.markSpeakerChange()
        try coordinator.addPhoto(jpegData: Data([0xFF, 0xD8]))
        engine.eventsOnStop = [.final(text: "Last words.", start: at(11), end: at(12))]
        clock.advance(5)

        let stopped = await coordinator.stop()
        let finished = try XCTUnwrap(stopped)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(coordinator.session)
        XCTAssertEqual(finished.endedAt, at(15))
        XCTAssertEqual(finished.speechSegments.map(\.text), ["Hello world.", "Last words."])
        XCTAssertEqual(finished.photos.count, 1)
        XCTAssertEqual(try store.load(id: id), finished)
        let photo = try XCTUnwrap(finished.photos.first)
        XCTAssertEqual(try Data(contentsOf: store.photoURL(sessionID: id, fileName: photo.fileName)), Data([0xFF, 0xD8]))
    }

    func testEventsSentThroughStreamAreProcessedBeforeStopReturns() async throws {
        try await coordinator.start(language: "en-US", saveAudio: false)
        engine.send(.final(text: "Via stream.", start: at(1), end: at(2)))
        let finished = await coordinator.stop()
        XCTAssertEqual(finished?.speechSegments.map(\.text), ["Via stream."])
    }

    func testSaveAudioPassesSessionAudioDirectory() async throws {
        try await coordinator.start(language: "zh-CN", saveAudio: true)
        let id = try XCTUnwrap(coordinator.session?.id)
        XCTAssertEqual(engine.configurations.first?.audioDirectory, store.audioDirectory(for: id))
        XCTAssertEqual(engine.configurations.first?.localeIdentifier, "zh-CN")
        coordinator.handle(.audioFileStarted(fileName: "run-1.m4a", at: t0))
        coordinator.handle(.audioFileFinished(fileName: "run-1.m4a", at: at(30)))
        coordinator.handle(.audioFileStarted(fileName: "run-2.m4a", at: at(60)))
        clock.advance(100)
        let finished = await coordinator.stop()
        XCTAssertEqual(finished?.audioRecordings.map(\.endedAt), [at(30), at(100)])
    }

    func testInterruptionCreatesGapAndResumes() async throws {
        try await coordinator.start(language: "en-US", saveAudio: false)
        coordinator.handle(.volatile("half a sent"))
        coordinator.handle(.interrupted(at: at(20), reason: "Phone call"))
        XCTAssertEqual(coordinator.state, .interrupted(reason: "Phone call"))
        XCTAssertEqual(coordinator.volatileText, "")
        // A second interruption while already interrupted doesn't open another gap.
        coordinator.handle(.interrupted(at: at(25), reason: "Siri"))
        coordinator.handle(.resumed(at: at(50)))
        XCTAssertEqual(coordinator.state, .recording)

        let id = try XCTUnwrap(coordinator.session?.id)
        let saved = try store.load(id: id)
        let gaps = saved.items.compactMap { if case .gap(let g) = $0 { g } else { nil } }
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.start, at(20))
        XCTAssertEqual(gaps.first?.end, at(50))
    }

    func testStopWhileInterruptedClosesGap() async throws {
        try await coordinator.start(language: "en-US", saveAudio: false)
        coordinator.handle(.interrupted(at: at(20), reason: "Camera"))
        clock.advance(40)
        let stopped = await coordinator.stop()
        let finished = try XCTUnwrap(stopped)
        guard case .gap(let gap) = finished.items.last else { return XCTFail("expected gap") }
        XCTAssertEqual(gap.end, at(40))
    }

    func testStartFailureDiscardsSession() async throws {
        engine.startError = MockEngine.StartFailure()
        do {
            try await coordinator.start(language: "en-US", saveAudio: false)
            XCTFail("expected error")
        } catch {}
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(coordinator.session)
        XCTAssertEqual(coordinator.lastError, "Microphone permission denied")
        XCTAssertEqual(try store.listSessions(), [])
    }

    func testEngineDyingClosesSessionAndKeepsVolatileText() async throws {
        var finishedSessions: [TranscriptSession] = []
        coordinator.onSessionFinished = { finishedSessions.append($0) }
        try await coordinator.start(language: "en-US", saveAudio: false)
        engine.send(.final(text: "Saved.", start: at(1), end: at(2)))
        engine.send(.volatile("not yet final"))
        engine.send(.failed("Speech model crashed"))
        engine.finishStream()
        for _ in 0..<50 where coordinator.state != .idle { await Task.yield() }

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(coordinator.lastError, "Speech model crashed")
        XCTAssertEqual(finishedSessions.first?.speechSegments.map(\.text), ["Saved.", "not yet final"])
    }

    func testAutosaveOnlyWritesWhenDirty() async throws {
        try await coordinator.start(language: "en-US", saveAudio: false)
        let id = try XCTUnwrap(coordinator.session?.id)
        coordinator.handle(.final(text: "Autosaved.", start: at(1), end: at(2)))
        XCTAssertEqual(try store.load(id: id).speechSegments.count, 0, "finals are batched until autosave")
        coordinator.saveIfNeeded()
        XCTAssertEqual(try store.load(id: id).speechSegments.map(\.text), ["Autosaved."])
    }

    func testCaptionTail() async throws {
        try await coordinator.start(language: "en-US", saveAudio: false)
        coordinator.handle(.final(text: "One two three.", start: at(1), end: at(2)))
        coordinator.handle(.final(text: "Four five six.", start: at(3), end: at(4)))
        coordinator.handle(.volatile("seven"))
        XCTAssertEqual(coordinator.captionTail(), "One two three. Four five six. seven")
        XCTAssertEqual(coordinator.captionTail(maxCharacters: 10), "…six. seven")
    }

    func testActionsIgnoredWhenIdle() throws {
        coordinator.markSpeakerChange()
        XCTAssertThrowsError(try coordinator.addPhoto(jpegData: Data()))
        coordinator.handle(.final(text: "ignored", start: t0, end: t0))
        XCTAssertNil(coordinator.session)
    }

    func testCancelWhileStartingDiscardsSessionAndStopsLateEngine() async throws {
        let gated = GatedEngine()
        let clock = clock!
        let coordinator = RecordingCoordinator(store: store, engine: gated, autosaveInterval: .seconds(3600), now: { clock.now() })
        let startTask = Task { try await coordinator.start(language: "en-US", saveAudio: false) }
        while !gated.isWaiting { await Task.yield() }
        XCTAssertEqual(coordinator.state, .starting)
        XCTAssertEqual(try store.listSessions().count, 1)

        coordinator.cancelStart()
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(coordinator.session)
        XCTAssertEqual(try store.listSessions(), [])

        // The engine finishes starting later and must be shut down again.
        gated.release()
        try await startTask.value
        XCTAssertEqual(gated.stopCount, 1)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(coordinator.session)
        XCTAssertEqual(try store.listSessions(), [])

        // A new recording works normally afterwards.
        let next = Task { try await coordinator.start(language: "en-US", saveAudio: false) }
        while !gated.isWaiting { await Task.yield() }
        gated.release()
        try await next.value
        XCTAssertEqual(coordinator.state, .recording)
    }

    func testRecoveryClosesUnfinishedSessions() throws {
        let open = TranscriptSession(localeIdentifier: "en-US", startedAt: t0, items: [speech("hi", 1, 5)])
        var closed = TranscriptSession(localeIdentifier: "en-US", startedAt: t0)
        closed.endedAt = at(10)
        try store.save(open)
        try store.save(closed)
        XCTAssertEqual(SessionRecovery.recoverUnfinished(in: store), 1)
        let recovered = try store.load(id: open.id)
        XCTAssertEqual(recovered.endedAt, at(5))
        XCTAssertTrue(recovered.wasRecovered)
        XCTAssertEqual(try store.load(id: closed.id), closed)
    }
}
