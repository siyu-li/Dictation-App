import ImageIO
import SwiftUI
import TranscriptCore
import UIKit
import UniformTypeIdentifiers

// MARK: - Small model helpers for the UI

extension AppModel {
    /// File URL of a photo that belongs to `session`.
    func photoURL(_ photo: PhotoAttachment, in session: TranscriptSession) -> URL {
        store.photoURL(sessionID: session.id, fileName: photo.fileName)
    }
}

extension TranscriptSession {
    /// The first few phrases, for a one-line preview in lists. Cheap even for
    /// very long sessions.
    var previewText: String {
        TextJoiner.join(speechSegments.prefix(8).map(\.text))
    }
}

extension TranscriptLanguage {
    /// Short label for the language switch on the home screen.
    var shortName: String {
        switch self {
        case .englishUS: "English"
        case .chineseMandarin: "中文"
        }
    }
}

/// Timestamp label for a moment in a session, following the user's setting.
func timestampLabel(_ date: Date, in session: TranscriptSession, style: TimestampStyle) -> String {
    switch style {
    case .clock: TimestampFormatter().clock(date)
    case .elapsed: TimestampFormatter.elapsed(date.timeIntervalSince(session.startedAt))
    }
}

// MARK: - Images

/// Memory-friendly image decoding with ImageIO. Safe to call off the main thread.
enum ImageDownsampler {
    static func downsample(url: URL, maxPixelSize: CGFloat) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        return downsample(source: source, maxPixelSize: maxPixelSize)
    }

    static func downsample(data: Data, maxPixelSize: CGFloat) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        return downsample(source: source, maxPixelSize: maxPixelSize)
    }

    /// Re-encodes an image as an upright JPEG no larger than `maxPixelSize`.
    static func jpegData(from data: Data, maxPixelSize: CGFloat, quality: CGFloat) -> Data? {
        guard let image = downsample(data: data, maxPixelSize: maxPixelSize) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let properties = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func downsample(source: CGImageSource, maxPixelSize: CGFloat) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Applies the EXIF orientation, so the result is upright.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Caches decoded thumbnails so scrolling a long transcript stays smooth.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.countLimit = 60
    }

    func image(for url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        let key = "\(url.path)#\(Int(maxPixelSize))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            ImageDownsampler.downsample(url: url, maxPixelSize: maxPixelSize).map { UIImage(cgImage: $0) }
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

/// A photo loaded lazily at a reduced size.
struct PhotoThumbnail: View {
    let url: URL
    var maxPixelSize: CGFloat = 1200

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .overlay {
                        if failed {
                            Image(systemName: "photo.badge.exclamationmark")
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                        }
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: url) {
            image = await ThumbnailCache.shared.image(for: url, maxPixelSize: maxPixelSize)
            failed = image == nil
        }
    }
}

// MARK: - Share sheet

/// A file or folder to hand to the system share sheet.
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// `UIActivityViewController` for things `ShareLink` can't share well
/// (e.g. a folder with a Markdown file and photos).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Toast

/// A short message that slides in at the bottom and hides itself.
private struct ToastModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message {
                    Text(message)
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .accessibilityAddTraits(.isStaticText)
                        .task(id: message) {
                            try? await Task.sleep(for: .seconds(3))
                            withAnimation { self.message = nil }
                        }
                }
            }
            .animation(.default, value: message)
    }
}

extension View {
    func toast(_ message: Binding<String?>) -> some View {
        modifier(ToastModifier(message: message))
    }
}
