import SwiftUI
import TranscriptCore
import UIKit

/// Shown full-screen while a recording is active. Designed to be glanced at,
/// not watched: a small caption strip, the elapsed time, and big buttons.
/// The phone may lock; recording continues in the background.
struct RecordingView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(RecordingCoordinator.self) private var recorder

    @State private var showCamera = false
    @State private var showStopConfirmation = false
    @State private var showLiveTranscript = false
    @State private var speakerMarkCount = 0
    @State private var speakerConfirmationVisible = false

    @ScaledMetric(relativeTo: .title3) private var captionHeight: CGFloat = 104

    var body: some View {
        VStack(spacing: 18) {
            statusHeader
            elapsedTime
            captionStrip
            Spacer(minLength: 0)
            infoLine
            actionButtons
        }
        .padding()
        .background(background.ignoresSafeArea())
        // Dark while recording: calm, readable, and no bright screen in a
        // dark room. Nothing here animates continuously (battery).
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showLiveTranscript) {
            LiveTranscriptView()
                .environment(model)
                .environment(settings)
                .environment(recorder)
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraView { data, takenAt in
                _ = try recorder.addPhoto(jpegData: data, takenAt: takenAt)
            }
        }
        .confirmationDialog("Stop recording?", isPresented: $showStopConfirmation, titleVisibility: .visible) {
            Button("Stop and save", role: .destructive) {
                Task { await model.stopRecording() }
            }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("The transcript is saved and opened.")
        }
        .sensoryFeedback(.success, trigger: speakerMarkCount)
    }

    // MARK: - Parts

    /// A static, mostly black gradient with a faint indigo glow.
    private var background: some View {
        MeshGradient(
            width: 2,
            height: 2,
            points: [SIMD2<Float>(0, 0), SIMD2<Float>(1, 0), SIMD2<Float>(0, 1), SIMD2<Float>(1, 1)],
            colors: [
                Color(red: 0.10, green: 0.07, blue: 0.20),
                .black,
                .black,
                Color(red: 0.04, green: 0.05, blue: 0.12),
            ]
        )
    }

    private var statusHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
                Text(statusTitle)
                    .font(.headline)
                if let session = recorder.session {
                    Text("· " + TranscriptLanguage.displayName(for: session.localeIdentifier))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: Capsule())
            if let detail = statusDetail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let error = recorder.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    private var elapsedTime: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = recorder.session?.duration(now: context.date) ?? 0
            Text(TimestampFormatter.elapsed(elapsed))
                .font(.system(size: 64, weight: .light, design: .rounded).monospacedDigit())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .accessibilityLabel("Elapsed time \(TimestampFormatter.duration(elapsed))")
        }
    }

    /// The last two or three lines of the live transcript. Tap to see more.
    private var captionStrip: some View {
        Button {
            showLiveTranscript = true
        } label: {
            let caption = recorder.captionTail(maxCharacters: 400)
            Text(caption.isEmpty ? "Listening…" : caption)
                .font(.title3)
                .foregroundStyle(caption.isEmpty ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                // Bottom-aligned and clipped, so the newest words are always visible.
                .frame(maxWidth: .infinity, minHeight: captionHeight, maxHeight: captionHeight, alignment: .bottomLeading)
                .clipped()
                .padding(14)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Live captions")
        .accessibilityValue(recorder.captionTail(maxCharacters: 200))
        .accessibilityHint("Shows the full live transcript")
    }

    private var infoLine: some View {
        let savingAudio = !(recorder.session?.audioRecordings.isEmpty ?? true)
        return VStack(spacing: 4) {
            if speakerConfirmationVisible {
                Label("New speaker marked", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
            HStack(spacing: 16) {
                if savingAudio {
                    Label("Saving audio", systemImage: "waveform")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .animation(.default, value: speakerConfirmationVisible)
    }

    /// The camera is the main control (used at every slide); New speaker and
    /// a small Stop sit below it, Stop away from the thumb's main target.
    private var actionButtons: some View {
        VStack(spacing: 12) {
            recentPhotos
            Button {
                showCamera = true
            } label: {
                Label("Slide photo", systemImage: "camera.fill")
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 72)
            }
            .buttonStyle(.glassProminent)
            .tint(.indigo)
            .disabled(!recorder.isRecording)
            .accessibilityHint("Photos of slides go into the transcript at this moment and into the AI summary")

            HStack(spacing: 12) {
                Button {
                    markSpeaker()
                } label: {
                    Label("New speaker", systemImage: "person.wave.2.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.glass)
                .disabled(!recorder.isRecording)
                .accessibilityHint("Marks that a different person started talking")

                stopButton
            }
        }
    }

    /// The last few photos, so it's clear they went into the transcript.
    @ViewBuilder
    private var recentPhotos: some View {
        if let session = recorder.session {
            let photos = session.photos
            if !photos.isEmpty {
                HStack(spacing: 6) {
                    ForEach(photos.suffix(4)) { photo in
                        PhotoThumbnail(url: model.photoURL(photo, in: session), maxPixelSize: 160)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Text("\(photos.count) in transcript")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(photos.count) photos in the transcript")
            }
        }
    }

    @ViewBuilder
    private var stopButton: some View {
        if recorder.state == .starting {
            Button {
                model.cancelStart()
            } label: {
                Label("Cancel", systemImage: "xmark")
                    .font(.headline)
                    .frame(minWidth: 100, minHeight: 50)
            }
            .buttonStyle(.glass)
        } else {
            stopRecordingButton
        }
    }

    private var stopRecordingButton: some View {
        Button {
            showStopConfirmation = true
        } label: {
            Label(recorder.state == .stopping ? "Finishing…" : "Stop", systemImage: "stop.fill")
                .font(.headline)
                .frame(minWidth: 100, minHeight: 50)
        }
        .buttonStyle(.glass)
        .tint(.red)
        .disabled(!recorder.isRecording)
    }

    // MARK: - Actions

    private func markSpeaker() {
        recorder.markSpeakerChange()
        speakerMarkCount += 1
        speakerConfirmationVisible = true
        let mark = speakerMarkCount
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if mark == speakerMarkCount { speakerConfirmationVisible = false }
        }
    }

    // MARK: - Status text

    private var statusTitle: String {
        switch recorder.state {
        case .idle: "Stopped"
        case .starting: "Preparing…"
        case .recording: "Recording"
        case .interrupted: "Paused"
        case .stopping: "Finishing…"
        }
    }

    private var statusDetail: String? {
        switch recorder.state {
        case .starting: "Getting the microphone and speech model ready. The first time you use a language, the model downloads, which can take a few minutes on a slow connection."
        case .interrupted(let reason): "Paused: \(reason). Will resume automatically."
        case .stopping: "Saving the last words of the transcript."
        case .recording: "You can lock your phone."
        case .idle: nil
        }
    }

    private var statusSymbol: String {
        switch recorder.state {
        case .recording: "record.circle.fill"
        case .interrupted: "pause.circle.fill"
        default: "hourglass"
        }
    }

    private var statusColor: Color {
        switch recorder.state {
        case .recording: .red
        case .interrupted: .orange
        default: .secondary
        }
    }
}

/// The whole live transcript, opened from the caption strip. Follows the
/// newest text unless the user turns that off.
struct LiveTranscriptView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(RecordingCoordinator.self) private var recorder
    @Environment(\.dismiss) private var dismiss

    @State private var follow = true
    private let bottomID = "live-transcript-bottom"

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if let session = recorder.session {
                                // Re-formatted only when the timeline changes,
                                // not on every in-progress caption update.
                                TranscriptBlocksList(
                                    session: session,
                                    options: settings.formatOptions,
                                    style: settings.timestampStyle,
                                    photoURL: { model.photoURL($0, in: session) }
                                )
                                .equatable()
                            }
                            LiveVolatileText()
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(bottomID)
                    }
                    .padding()
                }
                .onAppear { proxy.scrollTo(bottomID, anchor: .bottom) }
                .onChange(of: recorder.volatileText) {
                    if follow { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
                .onChange(of: recorder.session?.items.count) {
                    if follow { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
            }
            .navigationTitle("Live transcript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Toggle(isOn: $follow) {
                        Label("Follow", systemImage: "arrow.down.to.line")
                    }
                    .toggleStyle(.button)
                    .accessibilityHint("Keeps the newest words in view")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// The in-progress (not yet final) caption text. Its own view so that its
/// frequent updates don't re-render the whole transcript.
private struct LiveVolatileText: View {
    @Environment(RecordingCoordinator.self) private var recorder

    var body: some View {
        if !recorder.volatileText.isEmpty {
            Text(recorder.volatileText)
                .foregroundStyle(.secondary)
                .italic()
        }
    }
}
