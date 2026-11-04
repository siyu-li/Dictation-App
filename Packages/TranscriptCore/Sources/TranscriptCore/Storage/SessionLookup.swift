import Foundation

/// Finds the session a Shortcut asked for.
public enum SessionLookup {
    public enum Result: Equatable, Sendable {
        case found(TranscriptSession)
        /// A valid session id was given but no such session exists (e.g. deleted).
        case notFound(UUID)
        /// No id was given and there is no finished session yet.
        case noFinishedSessions
    }

    /// - If `idString` is a session id (surrounding whitespace ignored, any
    ///   letter case), returns that session, finished or not.
    /// - If `idString` is empty or not an id, returns the most recent finished
    ///   session, so a Shortcut run by hand still does something useful.
    public static func find(_ idString: String?, in sessions: [TranscriptSession]) -> Result {
        let raw = idString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let id = UUID(uuidString: raw) {
            return sessions.first { $0.id == id }.map(Result.found) ?? .notFound(id)
        }
        return sessions
            .filter(\.isFinished)
            .max { $0.startedAt < $1.startedAt }
            .map(Result.found) ?? .noFinishedSessions
    }
}
