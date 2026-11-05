import Foundation
import Observation
import TranscriptCore

/// Composition root: owns storage, settings, the diagnostics log and the
/// recording coordinator, and keeps the list of saved sessions.
@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let store: FileSessionStore
    let log: DiagnosticsLog
    let recorder: RecordingCoordinator
    /// AI title/summary generation (Claude).
    let insights: InsightsService
    /// Microphone loudness for the recording screen's level meter.
    let audioLevel: AudioLevelMeter
    /// Reads slide text from photos in the background.
    let slideText: SlideTextRecognizer

    /// Saved sessions, newest first.
    private(set) var sessions: [TranscriptSession] = []
    /// Sessions with a Photos-library import in progress.
    private(set) var importingSessionIDs: Set<UUID> = []
    @ObservationIgnored private var startTask: Task<Void, Never>?

    init() {
        let root = AppPaths.root
        let log = DiagnosticsLog(fileURL: root.appending(path: "diagnostics.log"))
        let store = FileSessionStore(rootDirectory: root)
        self.log = log
        self.store = store
        self.settings = AppSettings()
        let audioLevel = AudioLevelMeter()
        self.audioLevel = audioLevel
        self.slideText = SlideTextRecognizer(log: log)
        self.recorder = RecordingCoordinator(
            store: store,
            engine: SpeechAnalyzerEngine(log: log, levelMeter: audioLevel),
            log: log
        )
        self.insights = InsightsService(settings: AISettings(), log: log)

        log.log("App launched", category: "app")
        do {
            // One read of the store at launch; sessions left open by a crash are closed.
            sessions = SessionRecovery.recoverUnfinished(try store.listSessions(), store: store, log: log).sessions
        } catch {
            log.log("Listing sessions failed: \(error)", category: "app")
        }
        recorder.onSessionFinished = { [weak self] finished in
            self?.upsert(finished)
        }
    }

    // MARK: - Sessions

    func reloadSessions() {
        do {
            sessions = try store.listSessions()
        } catch {
            log.log("Listing sessions failed: \(error)", category: "app")
        }
    }

    func session(id: UUID) -> TranscriptSession? {
        sessions.first { $0.id == id }
    }

    /// Saves changes to a finished session (rename, imported photos, AI results, ...).
    /// Callers should start from the latest `session(id:)` so they don't
    /// overwrite changes made meanwhile.
    func update(_ session: TranscriptSession) {
        do {
            try store.save(session)
            upsert(session)
        } catch {
            log.log("Saving session \(session.id) failed: \(error)", category: "app")
        }
    }

    func delete(id: UUID) {
        do {
            try store.delete(id: id)
        } catch {
            log.log("Deleting session \(id) failed: \(error)", category: "app")
        }
        sessions.removeAll { $0.id == id }
    }

    /// Replaces the in-memory copy (or inserts it, newest first) without
    /// re-reading every session from disk.
    private func upsert(_ session: TranscriptSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            let index = sessions.firstIndex { $0.startedAt < session.startedAt } ?? sessions.count
            sessions.insert(session, at: index)
        }
    }

    /// Imports Photos-library pictures taken during a session and merges them
    /// into the *latest* saved version (the import can take a while, and the
    /// user may rename, summarize or delete the recording meanwhile).
    /// Returns how many photos were added.
    func importLibraryPhotos(for id: UUID) async throws -> Int {
        guard !importingSessionIDs.contains(id), let original = session(id: id) else { return 0 }
        importingSessionIDs.insert(id)
        defer { importingSessionIDs.remove(id) }

        let result = try await PhotoLibraryImporter.importPhotos(into: original, store: store, log: log)
        let originalIDs = Set(original.photos.map(\.id))
        let newPhotos = result.session.photos.filter { !originalIDs.contains($0.id) }
        guard !newPhotos.isEmpty else { return 0 }

        guard var latest = session(id: id) else {
            // Deleted while importing: remove the files the import wrote.
            try? store.delete(id: id)
            log.log("Session \(id) was deleted during photo import; discarded imported photos", category: "photos")
            return 0
        }
        let known = Set(latest.photos.compactMap(\.libraryIdentifier))
        var added = 0
        var addedPhotos: [PhotoAttachment] = []
        for photo in newPhotos where !(photo.libraryIdentifier.map(known.contains) ?? false) {
            latest.insert(.photo(photo))
            addedPhotos.append(photo)
        }
        update(latest)
        for photo in addedPhotos {
            recognizeSlideText(in: photo, sessionID: id)
        }
        return addedPhotos.count
    }

    /// Reads the text on a photo in the background and stores it with the
    /// photo: in the recording if it's still running, otherwise in the latest
    /// saved session.
    func recognizeSlideText(in photo: PhotoAttachment, sessionID: UUID) {
        let url = store.photoURL(sessionID: sessionID, fileName: photo.fileName)
        let photoID = photo.id
        let recognizer = slideText
        Task { [weak self] in
            guard let text = await recognizer.recognizeText(at: url) else { return }
            guard let self else { return }
            if self.recorder.setRecognizedText(text, forPhoto: photoID) {
                self.log.log("Slide text recognized for a photo (\(text.count) characters)", category: "vision")
                return
            }
            guard var latest = self.session(id: sessionID), latest.setRecognizedText(text, forPhoto: photoID) else { return }
            self.update(latest)
            self.log.log("Slide text recognized for a saved photo (\(text.count) characters)", category: "vision")
        }
    }

    // MARK: - Recording

    /// Starts recording with the current settings. Errors are shown through
    /// `recorder.lastError`.
    func startRecording() async {
        let language = settings.language.rawValue
        let saveAudio = settings.saveAudio
        let recorder = recorder
        let task = Task {
            do {
                try await recorder.start(language: language, saveAudio: saveAudio)
            } catch {
                // Already logged and exposed via recorder.lastError.
            }
        }
        startTask = task
        await task.value
        startTask = nil
    }

    /// Cancels a start that's taking too long (e.g. the first speech model download).
    func cancelStart() {
        recorder.cancelStart()
        startTask?.cancel()
    }

    @discardableResult
    func stopRecording() async -> TranscriptSession? {
        await recorder.stop()
    }
}
