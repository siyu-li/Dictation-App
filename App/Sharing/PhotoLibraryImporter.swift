import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers
import TranscriptCore

/// Pulls in photos taken with the system Camera app (and screenshots) during
/// a session.
@MainActor
enum PhotoLibraryImporter {
    enum ImportError: LocalizedError {
        case accessDenied
        case restricted
        case unreadableImage

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                "Dictation can't see your photos. Allow access in Settings → Privacy & Security → Photos → Dictation."
            case .restricted:
                "Photo access is restricted on this iPhone (for example by Screen Time)."
            case .unreadableImage:
                "A photo couldn't be read."
            }
        }
    }

    /// Imports library photos taken between the session's start and end that
    /// aren't in the session yet. Returns the updated session and how many
    /// photos were added. The caller saves the session (`AppModel.update`).
    static func importPhotos(
        into session: TranscriptSession,
        store: FileSessionStore,
        log: DiagnosticsLog
    ) async throws -> (session: TranscriptSession, added: Int) {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        switch status {
        case .authorized:
            break
        case .limited:
            log.log("Photo access is limited; only photos the user selected are visible", category: "photos")
        case .restricted:
            throw ImportError.restricted
        case .denied, .notDetermined:
            throw ImportError.accessDenied
        @unknown default:
            throw ImportError.accessDenied
        }

        let end = session.endedAt ?? Date()
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@",
            session.startedAt as NSDate,
            end as NSDate
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        for index in 0..<result.count {
            assets.append(result.object(at: index))
        }

        let alreadyImported = Set(session.photos.compactMap(\.libraryIdentifier))
        var updated = session
        var added = 0
        for asset in assets where !alreadyImported.contains(asset.localIdentifier) {
            guard let takenAt = asset.creationDate else { continue }
            do {
                let original = try await imageData(for: asset)
                let jpeg = try await Task.detached(priority: .userInitiated) {
                    try PhotoLibraryImporter.makeJPEG(from: original)
                }.value
                let photoID = UUID()
                let fileName = "\(photoID.uuidString).jpg"
                try store.writePhoto(jpeg, sessionID: session.id, fileName: fileName)
                updated.insert(.photo(PhotoAttachment(
                    id: photoID,
                    takenAt: takenAt,
                    fileName: fileName,
                    source: .photoLibrary,
                    libraryIdentifier: asset.localIdentifier
                )))
                added += 1
            } catch {
                log.log("Skipped library photo \(asset.localIdentifier): \(error)", category: "photos")
            }
        }
        log.log("Imported \(added) of \(assets.count) library photos into \(session.id)", category: "photos")
        return (updated, added)
    }

    /// The asset's original image data (downloaded from iCloud if needed).
    private static func imageData(for asset: PHAsset) async throws -> Data {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        return try await withCheckedThrowingContinuation { continuation in
            _ = PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                // Only the final, full-quality result resumes the continuation.
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: (info?[PHImageErrorKey] as? Error) ?? ImportError.unreadableImage)
                }
            }
        }
    }

    /// Re-encodes any image (HEIC, PNG, JPEG) as an upright JPEG no larger
    /// than `maxPixelSize` on its long side.
    nonisolated static func makeJPEG(from data: Data, maxPixelSize: Int = 2048, quality: Double = 0.8) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImportError.unreadableImage
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw ImportError.unreadableImage
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ImportError.unreadableImage
        }
        let destinationOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImportError.unreadableImage
        }
        return output as Data
    }
}
