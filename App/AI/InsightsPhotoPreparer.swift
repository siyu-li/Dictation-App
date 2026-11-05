import Foundation
import ImageIO
import TranscriptCore
import UniformTypeIdentifiers

/// Shrinks session photos for sending to Claude: at most
/// `InsightsPrompt.maxPhotos`, spread over the session, each downscaled so
/// its long edge is `InsightsPrompt.recommendedPhotoMaxPixels` (slide text
/// stays legible, the request stays small) and re-encoded as JPEG.
enum InsightsPhotoPreparer {
    static func prepare(_ photos: [PhotoAttachment], sessionID: UUID, store: FileSessionStore) async -> [InsightsPhoto] {
        let chosen = InsightsPrompt.spread(photos.sorted { $0.takenAt < $1.takenAt }, limit: InsightsPrompt.maxPhotos)
        guard !chosen.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) {
            chosen.compactMap { photo -> InsightsPhoto? in
                let url = store.photoURL(sessionID: sessionID, fileName: photo.fileName)
                guard let data = try? Data(contentsOf: url),
                      let scaled = downscale(data, maxPixelSize: InsightsPrompt.recommendedPhotoMaxPixels) else {
                    return nil
                }
                return InsightsPhoto(
                    id: photo.id,
                    takenAt: photo.takenAt,
                    jpegData: scaled.data,
                    pixelWidth: scaled.width,
                    pixelHeight: scaled.height
                )
            }
        }.value
    }

    static func downscale(_ data: Data, maxPixelSize: Int, quality: Double = 0.8) -> (data: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let destinationOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, image.width, image.height)
    }
}
