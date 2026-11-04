import Foundation
import TranscriptCore

/// Getting transcripts out of the app: copy, share, and Apple Notes.
@MainActor
enum TranscriptSharing {
    /// Plain text with the user's timestamp settings, for copying and Notes.
    static func plainText(for session: TranscriptSession, settings: AppSettings) -> String {
        TranscriptExporter.plainText(for: session, options: settings.exportOptions)
    }

    /// A Markdown file (plus a `photos` folder) for the share sheet.
    /// Placeholder; returns the folder URL to share.
    static func exportFolder(for session: TranscriptSession, store: FileSessionStore, settings: AppSettings) throws -> URL {
        throw CocoaError(.featureUnsupported)
    }

    /// Runs the user's "save to Notes" Shortcut for this session.
    /// Placeholder; returns false if the Shortcut couldn't be opened.
    @discardableResult
    static func sendToNotes(_ session: TranscriptSession, settings: AppSettings) async -> Bool {
        false
    }
}
