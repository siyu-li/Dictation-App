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

    /// Saved sessions, newest first.
    private(set) var sessions: [TranscriptSession] = []

    init() {
        let root = AppPaths.root
        let log = DiagnosticsLog(fileURL: root.appending(path: "diagnostics.log"))
        let store = FileSessionStore(rootDirectory: root)
        self.log = log
        self.store = store
        self.settings = AppSettings()
        self.recorder = RecordingCoordinator(store: store, engine: SpeechAnalyzerEngine(log: log), log: log)

        log.log("App launched", category: "app")
        SessionRecovery.recoverUnfinished(in: store, log: log)
        reloadSessions()
        recorder.onSessionFinished = { [weak self] _ in
            self?.reloadSessions()
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
    func update(_ session: TranscriptSession) {
        do {
            try store.save(session)
            reloadSessions()
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
        reloadSessions()
    }

    // MARK: - Recording

    /// Starts recording with the current settings. Errors are shown through
    /// `recorder.lastError`.
    func startRecording() async {
        do {
            try await recorder.start(language: settings.language.rawValue, saveAudio: settings.saveAudio)
        } catch {
            // Already logged and exposed via recorder.lastError.
        }
    }

    @discardableResult
    func stopRecording() async -> TranscriptSession? {
        await recorder.stop()
    }
}
