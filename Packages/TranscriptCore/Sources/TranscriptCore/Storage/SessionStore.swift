import Foundation

/// Persistence for sessions and their attachments.
///
/// Layout on disk:
/// ```
/// <root>/Sessions/<session-id>/session.json
/// <root>/Sessions/<session-id>/photos/<file>.jpg
/// <root>/Sessions/<session-id>/audio/<file>.m4a
/// ```
public protocol SessionStoring: Sendable {
    func save(_ session: TranscriptSession) throws
    func load(id: UUID) throws -> TranscriptSession
    /// All readable sessions, newest first. Unreadable files are skipped.
    func listSessions() throws -> [TranscriptSession]
    func delete(id: UUID) throws

    func sessionDirectory(for id: UUID) -> URL
    func photosDirectory(for id: UUID) -> URL
    func audioDirectory(for id: UUID) -> URL
    @discardableResult
    func writePhoto(_ data: Data, sessionID: UUID, fileName: String) throws -> URL
}

extension SessionStoring {
    public func photoURL(sessionID: UUID, fileName: String) -> URL {
        photosDirectory(for: sessionID).appendingPathComponent(fileName)
    }

    public func audioURL(sessionID: UUID, fileName: String) -> URL {
        audioDirectory(for: sessionID).appendingPathComponent(fileName)
    }
}

public enum SessionStoreError: Error, Equatable {
    case notFound(UUID)
}

public struct FileSessionStore: SessionStoring {
    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    private var sessionsDirectory: URL {
        rootDirectory.appendingPathComponent("Sessions", isDirectory: true)
    }

    public func sessionDirectory(for id: UUID) -> URL {
        sessionsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func photosDirectory(for id: UUID) -> URL {
        sessionDirectory(for: id).appendingPathComponent("photos", isDirectory: true)
    }

    public func audioDirectory(for id: UUID) -> URL {
        sessionDirectory(for: id).appendingPathComponent("audio", isDirectory: true)
    }

    private func sessionFile(for id: UUID) -> URL {
        sessionDirectory(for: id).appendingPathComponent("session.json")
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    public func save(_ session: TranscriptSession) throws {
        let directory = sessionDirectory(for: session.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.makeEncoder().encode(session)
        // Atomic: a crash mid-write leaves the previous version intact.
        try data.write(to: sessionFile(for: session.id), options: .atomic)
    }

    public func load(id: UUID) throws -> TranscriptSession {
        let url = sessionFile(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw SessionStoreError.notFound(id) }
        return try Self.makeDecoder().decode(TranscriptSession.self, from: Data(contentsOf: url))
    }

    public func listSessions() throws -> [TranscriptSession] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessionsDirectory.path) else { return [] }
        let decoder = Self.makeDecoder()
        return try fm.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil)
            .compactMap { directory -> TranscriptSession? in
                let file = directory.appendingPathComponent("session.json")
                guard let data = try? Data(contentsOf: file) else { return nil }
                return try? decoder.decode(TranscriptSession.self, from: data)
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func delete(id: UUID) throws {
        let directory = sessionDirectory(for: id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    public func writePhoto(_ data: Data, sessionID: UUID, fileName: String) throws -> URL {
        let directory = photosDirectory(for: sessionID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
        return url
    }
}
