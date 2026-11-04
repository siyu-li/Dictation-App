import Foundation
import Observation

/// Runs one recording session at a time: starts the engine, turns its events
/// into timeline items, autosaves every few seconds, and closes the session on
/// stop. The UI observes this object directly.
@MainActor
@Observable
public final class RecordingCoordinator {
    public enum State: Equatable, Sendable {
        case idle
        case starting
        case recording
        case interrupted(reason: String)
        case stopping
    }

    public enum CoordinatorError: Error, Equatable {
        case notRecording
    }

    public private(set) var state: State = .idle
    /// The session being recorded, `nil` when idle.
    public private(set) var session: TranscriptSession?
    /// Text still being recognized (not final yet).
    public private(set) var volatileText = ""
    /// The last problem worth showing to the user.
    public private(set) var lastError: String?

    /// Called after a session is finished and saved.
    @ObservationIgnored public var onSessionFinished: ((TranscriptSession) -> Void)?

    @ObservationIgnored private let store: any SessionStoring
    @ObservationIgnored private let engine: any TranscriptionEngine
    @ObservationIgnored private let log: DiagnosticsLog?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let autosaveInterval: Duration
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var hasUnsavedChanges = false
    @ObservationIgnored private var openGapID: UUID?
    /// Bumped by every start and by `cancelStart()`, so a start that finishes
    /// after being cancelled knows to shut the engine down again.
    @ObservationIgnored private var startGeneration = 0

    public init(
        store: any SessionStoring,
        engine: any TranscriptionEngine,
        log: DiagnosticsLog? = nil,
        autosaveInterval: Duration = .seconds(5),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.engine = engine
        self.log = log
        self.autosaveInterval = autosaveInterval
        self.now = now
    }

    public var isActive: Bool { state != .idle }

    /// True while capturing or waiting to resume after an interruption.
    public var isRecording: Bool {
        switch state {
        case .recording, .interrupted: true
        default: false
        }
    }

    public func clearError() { lastError = nil }

    // MARK: - Start / stop

    /// Starts a new session. Throws if the engine cannot start; the empty
    /// session is then discarded.
    public func start(language: String, saveAudio: Bool) async throws {
        guard state == .idle else { return }
        lastError = nil
        openGapID = nil
        hasUnsavedChanges = false
        state = .starting
        startGeneration += 1
        let generation = startGeneration
        let newSession = TranscriptSession(localeIdentifier: language, startedAt: now())
        session = newSession
        do {
            try store.save(newSession)
            let configuration = TranscriptionConfiguration(
                localeIdentifier: language,
                audioDirectory: saveAudio ? store.audioDirectory(for: newSession.id) : nil
            )
            let events = try await engine.start(configuration)
            guard generation == startGeneration else {
                // Cancelled while the engine was starting: shut it down again.
                log?.log("Engine started after cancel; stopping it", category: "recorder")
                let drain = Task { for await _ in events {} }
                await engine.stop()
                await drain.value
                return
            }
            state = .recording
            log?.log("Recording started: \(newSession.id) language=\(language) saveAudio=\(saveAudio)", category: "recorder")
            eventTask = Task { [weak self] in
                for await event in events {
                    self?.handle(event)
                }
                self?.engineStreamEnded()
            }
            startAutosave()
        } catch {
            // After cancelStart() everything is already cleaned up.
            guard generation == startGeneration else { return }
            log?.log("Start failed: \(error)", category: "recorder")
            try? store.delete(id: newSession.id)
            session = nil
            state = .idle
            lastError = Self.message(for: error)
            throw error
        }
    }

    /// Gives up on a start that is taking too long (e.g. a slow first-time
    /// speech model download). The empty session is discarded; if the engine
    /// finishes starting later, it is stopped right away.
    public func cancelStart() {
        guard state == .starting else { return }
        startGeneration += 1
        if let id = session?.id { try? store.delete(id: id) }
        session = nil
        volatileText = ""
        state = .idle
        log?.log("Start cancelled by the user", category: "recorder")
    }

    /// Stops recording, waits for the last results, saves and returns the
    /// finished session.
    @discardableResult
    public func stop() async -> TranscriptSession? {
        guard isRecording else { return nil }
        state = .stopping
        log?.log("Stopping", category: "recorder")
        await engine.stop()
        await eventTask?.value
        return finishSession()
    }

    // MARK: - User actions while recording

    /// Drops a "new speaker" marker at the current moment.
    public func markSpeakerChange(label: String? = nil) {
        guard isRecording else { return }
        session?.insert(.speakerChange(SpeakerChange(at: now(), label: label)))
        saveNow()
    }

    /// Saves a photo into the session and places it on the timeline.
    @discardableResult
    public func addPhoto(jpegData: Data, takenAt: Date? = nil) throws -> PhotoAttachment {
        guard isRecording, let id = session?.id else { throw CoordinatorError.notRecording }
        let photoID = UUID()
        let fileName = "\(photoID.uuidString).jpg"
        try store.writePhoto(jpegData, sessionID: id, fileName: fileName)
        let photo = PhotoAttachment(id: photoID, takenAt: takenAt ?? now(), fileName: fileName, source: .camera)
        session?.insert(.photo(photo))
        saveNow()
        return photo
    }

    /// The end of the live transcript, for a small caption display.
    public func captionTail(maxCharacters: Int = 280) -> String {
        var parts: [String] = []
        var count = volatileText.count
        if let items = session?.items {
            for item in items.reversed() {
                guard count < maxCharacters else { break }
                if case .speech(let segment) = item {
                    parts.append(segment.text)
                    count += segment.text.count + 1
                }
            }
        }
        let text = TextJoiner.join(parts.reversed() + [volatileText])
        return text.count > maxCharacters ? "…" + String(text.suffix(maxCharacters)) : text
    }

    // MARK: - Engine events

    func handle(_ event: TranscriptionEvent) {
        guard session != nil else { return }
        switch event {
        case .volatile(let text):
            volatileText = text
        case .final(let text, let start, let end):
            volatileText = ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            session?.insert(.speech(SpeechSegment(text: trimmed, start: start, end: end)))
            hasUnsavedChanges = true
            // While interrupted the app may be suspended or killed before the
            // next autosave, so save late results right away.
            if case .interrupted = state { saveNow() }
        case .interrupted(let at, let reason):
            log?.log("Interrupted: \(reason)", category: "recorder")
            // The interrupted run is over; text it never finalized is kept.
            keepVolatileText(endingAt: at)
            if openGapID == nil {
                let gap = AudioGap(start: at, reason: reason)
                openGapID = gap.id
                session?.insert(.gap(gap))
            }
            if state != .stopping { state = .interrupted(reason: reason) }
            saveNow()
        case .resumed(let at):
            log?.log("Resumed", category: "recorder")
            closeOpenGap(at: at)
            if state != .stopping { state = .recording }
            saveNow()
        case .audioFileStarted(let fileName, let at):
            session?.audioRecordings.append(AudioRecording(fileName: fileName, startedAt: at))
            hasUnsavedChanges = true
        case .audioFileFinished(let fileName, let at):
            if let index = session?.audioRecordings.lastIndex(where: { $0.fileName == fileName }) {
                session?.audioRecordings[index].endedAt = at
            }
            hasUnsavedChanges = true
        case .status(let message):
            log?.log(message, category: "engine")
        case .failed(let message):
            log?.log("Engine failed: \(message)", category: "engine")
            lastError = message
        }
    }

    /// Saves in-progress text that will never be finalized as a speech
    /// segment ending at `end`.
    private func keepVolatileText(endingAt end: Date) {
        let leftover = volatileText.trimmingCharacters(in: .whitespacesAndNewlines)
        volatileText = ""
        guard !leftover.isEmpty, let current = session else { return }
        let start = min(current.speechSegments.last?.end ?? current.startedAt, end)
        session?.insert(.speech(SpeechSegment(text: leftover, start: start, end: end)))
        hasUnsavedChanges = true
    }

    /// The event stream ended. During `stop()` that is expected; otherwise the
    /// engine died and the session is closed with what we have.
    private func engineStreamEnded() {
        guard state != .stopping, session != nil else { return }
        log?.log("Engine stream ended unexpectedly; closing session", category: "recorder")
        if lastError == nil { lastError = "Recording stopped unexpectedly. Everything up to now is saved." }
        finishSession()
    }

    @discardableResult
    private func finishSession() -> TranscriptSession? {
        autosaveTask?.cancel()
        autosaveTask = nil
        eventTask = nil
        guard var finished = session else {
            state = .idle
            return nil
        }
        let end = now()
        if let gapID = openGapID,
           let index = finished.items.firstIndex(where: { $0.id == gapID }),
           case .gap(var gap) = finished.items[index] {
            gap.end = max(gap.start, end)
            finished.items[index] = .gap(gap)
        }
        openGapID = nil
        // Text the engine never finalized is kept rather than lost.
        let leftover = volatileText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !leftover.isEmpty {
            let start = finished.items.map(\.endTime).max() ?? finished.startedAt
            finished.insert(.speech(SpeechSegment(text: leftover, start: start, end: max(start, end))))
        }
        for index in finished.audioRecordings.indices where finished.audioRecordings[index].endedAt == nil {
            finished.audioRecordings[index].endedAt = end
        }
        // Never end before the last thing on the timeline.
        finished.endedAt = max(end, finished.items.map(\.endTime).max() ?? end)
        volatileText = ""
        session = nil
        state = .idle
        save(finished)
        log?.log("Session finished: \(finished.id) items=\(finished.items.count)", category: "recorder")
        onSessionFinished?(finished)
        return finished
    }

    private func closeOpenGap(at date: Date) {
        guard let gapID = openGapID,
              let index = session?.items.firstIndex(where: { $0.id == gapID }),
              case .gap(var gap)? = session?.items[index] else { return }
        gap.end = max(gap.start, date)
        session?.items[index] = .gap(gap)
        openGapID = nil
    }

    // MARK: - Saving

    private func startAutosave() {
        autosaveTask?.cancel()
        let interval = autosaveInterval
        autosaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.saveIfNeeded()
            }
        }
    }

    func saveIfNeeded() {
        if hasUnsavedChanges { saveNow() }
    }

    private func saveNow() {
        guard let session else { return }
        save(session)
    }

    private func save(_ session: TranscriptSession) {
        do {
            try store.save(session)
            hasUnsavedChanges = false
        } catch {
            log?.log("Save failed: \(error)", category: "recorder")
            lastError = "Couldn't save the transcript: \(Self.message(for: error))"
        }
    }

    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

/// Closes sessions left open by a crash or by iOS terminating the app.
public enum SessionRecovery {
    /// Returns the number of sessions that were recovered.
    @discardableResult
    public static func recoverUnfinished(in store: any SessionStoring, log: DiagnosticsLog? = nil) -> Int {
        guard let sessions = try? store.listSessions() else { return 0 }
        return recoverUnfinished(sessions, store: store, log: log).recovered
    }

    /// Recovers unfinished sessions in an already-loaded list (saving each one)
    /// and returns the updated list, so the app reads the store only once at launch.
    public static func recoverUnfinished(
        _ sessions: [TranscriptSession],
        store: any SessionStoring,
        log: DiagnosticsLog? = nil
    ) -> (sessions: [TranscriptSession], recovered: Int) {
        var count = 0
        let updated = sessions.map { session -> TranscriptSession in
            guard !session.isFinished else { return session }
            let recovered = session.recoveredIfUnfinished()
            do {
                try store.save(recovered)
                count += 1
                log?.log("Recovered unfinished session \(session.id)", category: "recovery")
                return recovered
            } catch {
                log?.log("Recovery failed for \(session.id): \(error)", category: "recovery")
                return session
            }
        }
        return (updated, count)
    }
}
