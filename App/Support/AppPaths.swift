import Foundation
import TranscriptCore

/// Where the app keeps its data. Shared by the app and its Shortcuts actions
/// (App Intents run in the app's process, so they see the same files).
enum AppPaths {
    /// `Application Support/Dictation`
    static var root: URL {
        URL.applicationSupportDirectory.appending(path: "Dictation", directoryHint: .isDirectory)
    }

    static var diagnosticsLog: URL {
        root.appending(path: "diagnostics.log")
    }

    static func makeStore() -> FileSessionStore {
        FileSessionStore(rootDirectory: root)
    }

    /// Temporary files made for sharing. Safe to delete at any time.
    static var exportsDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "Exports", directoryHint: .isDirectory)
    }
}
