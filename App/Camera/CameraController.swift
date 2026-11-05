import AVFoundation
import Foundation

/// Photo-only camera. It has no audio input and never configures the app's
/// audio session, so the recording keeps running while photos are taken.
///
/// All session work happens on a private serial queue. `rotationCoordinator`
/// is created and read on the main thread.
final class CameraController: NSObject, @unchecked Sendable {
    enum CameraError: LocalizedError {
        case noCamera
        case cannotConfigure
        case notRunning
        case noPhotoData

        var errorDescription: String? {
            switch self {
            case .noCamera: "No camera is available."
            case .cannotConfigure: "The camera couldn't be set up."
            case .notRunning: "The camera isn't running."
            case .noPhotoData: "The photo couldn't be read."
            }
        }
    }

    /// Longest side of the saved JPEG. Slides stay readable; files stay small.
    static let maxPhotoPixelSize: CGFloat = 2560

    let session = AVCaptureSession()

    /// Tracks how the phone is held, so photos of slides taken in landscape
    /// come out upright. Main thread only.
    var rotationCoordinator: AVCaptureDevice.RotationCoordinator?

    private let queue = DispatchQueue(label: "Dictation.camera.session")
    private let photoOutput = AVCapturePhotoOutput()
    private let lock = NSLock()
    private var pending: [Int64: CheckedContinuation<Data, Error>] = [:]
    private var isConfigured = false
    private(set) var device: AVCaptureDevice?

    /// Configures (once) and starts the capture session.
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.configureIfNeeded()
                    if !self.session.isRunning {
                        self.session.startRunning()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Digital zoom (the iPhone 13 has no telephoto lens), e.g. 1, 2 or 3.
    func setZoom(_ factor: CGFloat) {
        queue.async {
            guard let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                let upper = min(device.maxAvailableVideoZoomFactor, 10)
                let clamped = min(max(factor, device.minAvailableVideoZoomFactor), upper)
                device.ramp(toVideoZoomFactor: clamped, withRate: 8)
                device.unlockForConfiguration()
            } catch {
                // Zoom is optional; ignore failures.
            }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    /// Takes a photo and returns it as an upright JPEG.
    /// - Parameter rotationAngle: from `rotationCoordinator`, read on the main thread.
    func capturePhoto(rotationAngle: CGFloat?) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            queue.async {
                guard self.session.isRunning else {
                    continuation.resume(throwing: CameraError.notRunning)
                    return
                }
                if let rotationAngle,
                   let connection = self.photoOutput.connection(with: .video),
                   connection.isVideoRotationAngleSupported(rotationAngle) {
                    connection.videoRotationAngle = rotationAngle
                }
                let settings: AVCapturePhotoSettings
                if self.photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
                    settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                } else {
                    settings = AVCapturePhotoSettings()
                }
                settings.photoQualityPrioritization = .balanced
                self.lock.withLock {
                    self.pending[settings.uniqueID] = continuation
                }
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    // MARK: - Setup (on `queue`)

    private func configureIfNeeded() throws {
        guard !isConfigured else { return }
        // Never touch the audio session: the recorder owns it.
        session.automaticallyConfiguresApplicationAudioSession = false

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: camera)

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(photoOutput) else {
            throw CameraError.cannotConfigure
        }
        session.addInput(input)
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .balanced
        device = camera
        isConfigured = true
    }

    private func takeContinuation(for id: Int64) -> CheckedContinuation<Data, Error>? {
        lock.withLock { pending.removeValue(forKey: id) }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let continuation = takeContinuation(for: photo.resolvedSettings.uniqueID) else { return }
        if let error {
            continuation.resume(throwing: error)
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            continuation.resume(throwing: CameraError.noPhotoData)
            return
        }
        // Smaller, upright JPEG (also converts HEIC if JPEG wasn't available).
        let jpeg = ImageDownsampler.jpegData(from: data, maxPixelSize: Self.maxPhotoPixelSize, quality: 0.8) ?? data
        continuation.resume(returning: jpeg)
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        // Normally the photo was already delivered above; this only catches
        // captures that ended without a photo.
        guard let continuation = takeContinuation(for: resolvedSettings.uniqueID) else { return }
        continuation.resume(throwing: error ?? CameraError.noPhotoData)
    }
}
