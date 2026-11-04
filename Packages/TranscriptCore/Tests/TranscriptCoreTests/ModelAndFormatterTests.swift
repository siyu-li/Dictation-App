import XCTest
@testable import TranscriptCore

final class SessionModelTests: XCTestCase {
    func testInsertKeepsTimeOrderAndIsStable() {
        var session = TranscriptSession(localeIdentifier: "en-US", startedAt: t0)
        session.insert(speech("b", 10, 12))
        session.insert(speech("a", 1, 3))
        let photo = PhotoAttachment(takenAt: at(10), fileName: "p.jpg", source: .camera)
        session.insert(.photo(photo))
        XCTAssertEqual(session.items.map(\.time), [at(1), at(10), at(10)])
        // Equal times keep insertion order: the speech came first.
        if case .photo = session.items[2] {} else { XCTFail("photo should be last") }
    }

    func testCodableRoundTripWithAllItemKinds() throws {
        var session = TranscriptSession(title: "Standup", localeIdentifier: "zh-CN", startedAt: t0)
        session.insert(speech("你好", 1, 2))
        session.insert(.speakerChange(SpeakerChange(at: at(3), label: "Alice")))
        session.insert(.photo(PhotoAttachment(takenAt: at(4), fileName: "x.jpg", source: .photoLibrary, libraryIdentifier: "ABC")))
        session.insert(.gap(AudioGap(start: at(5), end: at(9), reason: "Phone call")))
        session.audioRecordings = [AudioRecording(fileName: "run-1.m4a", startedAt: t0, endedAt: at(5))]
        session.endedAt = at(20)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(TranscriptSession.self, from: encoder.encode(session))
        XCTAssertEqual(decoded, session)
    }

    func testDecodesMinimalOlderFormat() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","startedAt":1793800800}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let session = try decoder.decode(TranscriptSession.self, from: Data(json.utf8))
        XCTAssertEqual(session.localeIdentifier, "en-US")
        XCTAssertTrue(session.items.isEmpty)
        XCTAssertFalse(session.wasRecovered)
        XCTAssertNil(session.endedAt)
    }

    func testRecoveryClosesSessionAtLastActivity() {
        var session = TranscriptSession(localeIdentifier: "en-US", startedAt: t0)
        session.insert(speech("hello", 1, 4))
        session.insert(.gap(AudioGap(start: at(6), reason: "Siri")))
        session.audioRecordings = [AudioRecording(fileName: "a.m4a", startedAt: t0)]
        let recovered = session.recoveredIfUnfinished()
        XCTAssertEqual(recovered.endedAt, at(6))
        XCTAssertTrue(recovered.wasRecovered)
        XCTAssertEqual(recovered.audioRecordings.first?.endedAt, at(6))
        guard case .gap(let gap) = recovered.items.last else { return XCTFail("expected gap") }
        XCTAssertEqual(gap.end, at(6))
        // Finished sessions are untouched.
        XCTAssertEqual(recovered.recoveredIfUnfinished(), recovered)
    }

    func testFullTextJoinsSpeechOnly() {
        let session = TranscriptSession(
            localeIdentifier: "en-US",
            startedAt: t0,
            items: [speech("One.", 0, 1), .speakerChange(SpeakerChange(at: at(2))), speech("Two.", 3, 4)]
        )
        XCTAssertEqual(session.fullText, "One. Two.")
    }
}

final class TranscriptFormatterTests: XCTestCase {
    func testShortPausesStayInOneParagraph() {
        let blocks = TranscriptFormatter.blocks(for: [speech("Hello", 0, 1), speech("world.", 1.5, 2.5)])
        XCTAssertEqual(blocks.count, 1)
        guard case .paragraph(let p) = blocks[0] else { return XCTFail() }
        XCTAssertEqual(p.text, "Hello world.")
        XCTAssertEqual(p.start, at(0))
        XCTAssertEqual(p.end, at(2.5))
        XCTAssertEqual(p.segmentIDs.count, 2)
    }

    func testLongPauseStartsNewParagraph() {
        let blocks = TranscriptFormatter.blocks(
            for: [speech("First.", 0, 1), speech("Second.", 3.5, 4)],
            options: FormatOptions(pauseThreshold: 2)
        )
        XCTAssertEqual(blocks.count, 2)
    }

    func testParagraphLengthLimit() {
        let items = (0..<10).map { speech("w\($0)", Double($0) * 10, Double($0) * 10 + 9.5) }
        let blocks = TranscriptFormatter.blocks(for: items, options: FormatOptions(pauseThreshold: 5, maxParagraphDuration: 30))
        // Each paragraph closes once it spans >= 30 s: segments 0-3, 4-7, 8-9.
        XCTAssertEqual(blocks.count, 3)
    }

    func testMarkersSplitParagraphsAndSortByTime() {
        let photo = PhotoAttachment(takenAt: at(2), fileName: "p.jpg", source: .camera)
        let change = SpeakerChange(at: at(5))
        // Deliberately unsorted input.
        let blocks = TranscriptFormatter.blocks(for: [
            speech("After photo", 3, 4), .speakerChange(change), speech("Before photo", 0, 1),
            .photo(photo), speech("New person", 5.5, 6),
        ])
        let kinds = blocks.map { block -> String in
            switch block {
            case .paragraph(let p): "p:\(p.text)"
            case .photo: "photo"
            case .speakerChange: "speaker"
            case .gap: "gap"
            }
        }
        XCTAssertEqual(kinds, ["p:Before photo", "photo", "p:After photo", "speaker", "p:New person"])
    }
}
