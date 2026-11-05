import AppIntents
import Foundation
import TranscriptCore

/// Shortcuts action "Get Dictation Transcript": returns a recording's
/// transcript as plain text, e.g. to pass to Notes' "Create Note".
struct GetTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Dictation Transcript"
    static let description = IntentDescription(
        "Returns the text of a Dictation recording. Leave Session ID empty to get the most recent finished recording."
    )
    static let openAppWhenRun: Bool = false

    @Parameter(
        title: "Session ID",
        description: "The recording to get. Dictation fills this in when you tap Send to Notes."
    )
    var sessionID: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let store = AppPaths.makeStore()
        // Fast path: Send to Notes passes the session id, so load just that file.
        if let id = UUID(uuidString: sessionID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") {
            guard let session = try? store.load(id: id) else { throw TranscriptIntentError.sessionNotFound }
            let text = TranscriptExporter.plainText(for: session, options: AppSettings().exportOptions)
            return .result(value: text)
        }
        let sessions = try store.listSessions()
        switch SessionLookup.find(sessionID, in: sessions) {
        case .found(let session):
            let text = TranscriptExporter.plainText(for: session, options: AppSettings().exportOptions)
            return .result(value: text)
        case .notFound:
            throw TranscriptIntentError.sessionNotFound
        case .noFinishedSessions:
            throw TranscriptIntentError.noSessions
        }
    }
}

enum TranscriptIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noSessions
    case sessionNotFound

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noSessions:
            "There are no finished Dictation recordings yet."
        case .sessionNotFound:
            "That Dictation recording wasn't found. It may have been deleted."
        }
    }
}

/// Makes the action show up in Shortcuts and Siri without any setup.
struct DictationShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetTranscriptIntent(),
            phrases: [
                "Get transcript from \(.applicationName)",
                "Get my latest \(.applicationName) transcript",
            ],
            shortTitle: "Get Transcript",
            systemImageName: "text.quote"
        )
    }
}
