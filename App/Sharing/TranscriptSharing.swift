import Foundation
import UIKit
import TranscriptCore

/// Getting transcripts out of the app: copy, share, and Apple Notes.
@MainActor
enum TranscriptSharing {
    enum SharingError: LocalizedError {
        case zipFailed(String)

        var errorDescription: String? {
            switch self {
            case .zipFailed(let reason): "Couldn't create the zip file: \(reason)"
            }
        }
    }

    // MARK: - Text

    /// Plain text with the user's timestamp settings, for copying and Notes.
    static func plainText(for session: TranscriptSession, settings: AppSettings) -> String {
        TranscriptExporter.plainText(for: session, options: settings.exportOptions)
    }

    /// Copies the plain-text transcript to the clipboard.
    static func copyToClipboard(_ session: TranscriptSession, settings: AppSettings) {
        UIPasteboard.general.string = plainText(for: session, settings: settings)
    }

    // MARK: - Files for the share sheet

    /// A folder named after the session (e.g. `2026-11-04 1402 Team meeting`)
    /// containing `transcript.md`, `transcript.txt` and a `photos` folder with
    /// the session's photos. Returns the folder URL to share (e.g. Save to Files).
    /// The files are written off the main thread (a talk can have many photos).
    static func exportFolder(for session: TranscriptSession, store: FileSessionStore, settings: AppSettings) async throws -> URL {
        let options = settings.exportOptions
        return try await Task.detached(priority: .userInitiated) {
            try writeExportFolder(for: session, store: store, options: options)
        }.value
    }

    nonisolated private static func writeExportFolder(
        for session: TranscriptSession,
        store: FileSessionStore,
        options: ExportOptions
    ) throws -> URL {
        let fm = FileManager.default
        removeOldExports()
        let folder = try makeExportContainer()
            .appending(path: TranscriptExporter.suggestedFileName(for: session), directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let markdown = TranscriptExporter.markdown(for: session, options: options) { "photos/\($0.fileName)" }
        try Data(markdown.utf8).write(to: folder.appending(path: "transcript.md"), options: .atomic)
        let text = TranscriptExporter.plainText(for: session, options: options)
        try Data(text.utf8).write(to: folder.appending(path: "transcript.txt"), options: .atomic)

        let photos = session.photos
        if !photos.isEmpty {
            let photosFolder = folder.appending(path: "photos", directoryHint: .isDirectory)
            try fm.createDirectory(at: photosFolder, withIntermediateDirectories: true)
            for photo in photos {
                let source = store.photoURL(sessionID: session.id, fileName: photo.fileName)
                // A missing photo file shouldn't block exporting the text.
                guard fm.fileExists(atPath: source.path) else { continue }
                try fm.copyItem(at: source, to: photosFolder.appending(path: photo.fileName))
            }
        }
        return folder
    }

    /// The export folder as one `.zip` file, for apps that don't accept
    /// folders (Mail, Messages, AirDrop to non-Apple devices).
    static func exportZip(for session: TranscriptSession, store: FileSessionStore, settings: AppSettings) async throws -> URL {
        let folder = try await exportFolder(for: session, store: store, settings: settings)
        let zipURL = folder.deletingLastPathComponent().appending(path: folder.lastPathComponent + ".zip")
        var coordinationError: NSError?
        var copyError: Error?
        // Reading a directory "for uploading" makes the system zip it.
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &coordinationError) { temporaryZip in
            do {
                try FileManager.default.copyItem(at: temporaryZip, to: zipURL)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError {
            throw SharingError.zipFailed(error.localizedDescription)
        }
        return zipURL
    }

    /// Just the plain-text transcript as a `.txt` file.
    static func plainTextFile(for session: TranscriptSession, settings: AppSettings) throws -> URL {
        removeOldExports()
        let url = try makeExportContainer()
            .appending(path: TranscriptExporter.suggestedFileName(for: session) + ".txt")
        try Data(plainText(for: session, settings: settings).utf8).write(to: url, options: .atomic)
        return url
    }

    /// Deletes exports older than an hour (the share sheet is long done with them).
    nonisolated static func removeOldExports(olderThan age: TimeInterval = 3600) {
        let fm = FileManager.default
        let directory = AppPaths.exportsDirectory
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified > cutoff { continue }
            try? fm.removeItem(at: entry)
        }
    }

    /// A unique, empty folder inside the exports directory.
    nonisolated private static func makeExportContainer() throws -> URL {
        let container = AppPaths.exportsDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        return container
    }

    // MARK: - Apple Notes

    /// `shortcuts://run-shortcut?name=<shortcut>&input=text&text=<session id>`
    static func notesShortcutURL(for session: TranscriptSession, settings: AppSettings) -> URL? {
        ShortcutLink.runShortcutURL(name: settings.notesShortcutName, inputText: session.id.uuidString)
    }

    /// Runs the user's "save to Notes" Shortcut for this session. Returns false
    /// if the Shortcuts app couldn't be opened (or no Shortcut name is set).
    /// Shortcuts itself reports a missing Shortcut; the app can't detect that.
    @discardableResult
    static func sendToNotes(_ session: TranscriptSession, settings: AppSettings) async -> Bool {
        guard let url = notesShortcutURL(for: session, settings: settings) else { return false }
        return await UIApplication.shared.open(url)
    }
}
