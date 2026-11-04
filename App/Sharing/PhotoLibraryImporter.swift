import Foundation
import TranscriptCore

/// Pulls in photos taken with the system Camera app during a session.
@MainActor
enum PhotoLibraryImporter {
    /// Imports library photos taken between the session's start and end that
    /// aren't in the session yet. Returns the updated session and how many
    /// photos were added. Placeholder.
    static func importPhotos(
        into session: TranscriptSession,
        store: FileSessionStore,
        log: DiagnosticsLog
    ) async throws -> (session: TranscriptSession, added: Int) {
        (session, 0)
    }
}
