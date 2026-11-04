import AVFoundation
import SwiftUI
import UIKit

/// Full-screen camera for photographing slides while recording. Stays open
/// for several shots; every photo goes into the transcript at the moment the
/// shutter was pressed. Recording is not interrupted.
struct CameraView: View {
    /// Saves a captured JPEG taken at the given moment. Throwing shows an error.
    let onCapture: @MainActor (Data, Date) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var controller: CameraController?
    @State private var authorization = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var isRunning = false
    @State private var savedCount = 0
    @State private var inFlight = 0
    @State private var shutterCount = 0
    @State private var flashOpacity = 0.0
    @State private var errorMessage: String?
    /// Done was tapped while photos were still being saved.
    @State private var isClosing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch authorization {
            case .authorized:
                cameraContent
            case .notDetermined:
                ProgressView()
                    .tint(.white)
            default:
                permissionMessage
            }

            Color.white
                .opacity(flashOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .statusBarHidden()
        .sensoryFeedback(.impact(weight: .medium), trigger: shutterCount)
        .task { await prepare() }
        .onDisappear { controller?.stop() }
        .onChange(of: inFlight) {
            if isClosing && inFlight == 0 { dismiss() }
        }
        .task(id: isClosing) {
            // Safety net: don't keep the screen open if a capture never finishes.
            guard isClosing else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    // MARK: - Content

    private var cameraContent: some View {
        ZStack {
            if let controller, isRunning {
                CameraPreview(session: controller.session)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            } else {
                ProgressView()
                    .tint(.white)
            }

            VStack {
                topBar
                Spacer()
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal)
                }
                shutterButton
                    .padding(.top, 12)
                Text("Photos go into the transcript at the moment you take them. Recording continues.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
        }
    }

    private var topBar: some View {
        HStack {
            if savedCount > 0 || inFlight > 0 {
                Label(
                    inFlight > 0 ? "Saving…" : "\(savedCount) photo\(savedCount == 1 ? "" : "s") added",
                    systemImage: inFlight > 0 ? "arrow.down.circle" : "checkmark.circle.fill"
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.black.opacity(0.5), in: Capsule())
            }
            Spacer()
            Button(isClosing ? "Saving…" : "Done") {
                if inFlight == 0 {
                    dismiss()
                } else {
                    isClosing = true
                }
            }
            .font(.headline)
            .buttonStyle(.borderedProminent)
            .disabled(isClosing)
        }
        .padding()
    }

    private var shutterButton: some View {
        Button(action: shoot) {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: 78, height: 78)
                Circle()
                    .fill(.white)
                    .frame(width: 64, height: 64)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isRunning)
        .accessibilityLabel("Take photo")
    }

    private var permissionMessage: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.largeTitle)
            Text("Camera access is off")
                .font(.title3.weight(.bold))
            Text("To photograph slides while recording, allow Dictation to use the camera in Settings. Your recording keeps running either way.")
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            .buttonStyle(.borderedProminent)
            Button("Close") { dismiss() }
                .buttonStyle(.bordered)
                .tint(.white)
        }
        .foregroundStyle(.white)
        .padding(32)
    }

    // MARK: - Actions

    private func prepare() async {
        if authorization == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            authorization = AVCaptureDevice.authorizationStatus(for: .video)
        }
        guard authorization == .authorized, controller == nil else { return }
        let camera = CameraController()
        controller = camera
        do {
            try await camera.start()
            if Task.isCancelled {
                // The screen closed while the camera was starting.
                camera.stop()
                return
            }
            if let device = camera.device {
                camera.rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            }
            isRunning = true
        } catch {
            errorMessage = "The camera couldn't start: \(error.localizedDescription)"
        }
    }

    private func shoot() {
        guard let controller, isRunning, !isClosing else { return }
        let takenAt = Date()
        let angle = controller.rotationCoordinator?.videoRotationAngleForHorizonLevelCapture
        shutterCount += 1
        flashOpacity = 0.7
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation(.easeOut(duration: 0.3)) { flashOpacity = 0 }
        }
        inFlight += 1
        Task {
            defer { inFlight -= 1 }
            do {
                let data = try await controller.capturePhoto(rotationAngle: angle)
                try onCapture(data, takenAt)
                savedCount += 1
                errorMessage = nil
            } catch {
                errorMessage = "Couldn't save the photo: \(error.localizedDescription)"
            }
        }
    }
}

/// Live camera preview.
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            // swiftlint:disable:next force_cast
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
