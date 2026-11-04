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

    @ScaledMetric(relativeTo: .footnote) private var captionHeight: CGFloat = 54

    var body: some View {
        VStack(spacing: 20) {
            statusHeader
            elapsedTime
            captionStrip
            Spacer(minLength: 0)
            infoLine
            actionButtons
            stopButton
        }
        .padding()
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
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

    private var statusHeader: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                    .symbolEffect(.pulse, isActive: recorder.state == .recording)
                    .accessibilityHidden(true)
                Text(statusTitle)
                    .font(.headline)
            }
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
                .font(.system(.largeTitle, design: .rounded).weight(.light).monospacedDigit())
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
                .font(.footnote)
                .foregroundStyle(caption.isEmpty ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                // Bottom-aligned and clipped, so the newest words are always visible.
                .frame(maxWidth: .infinity, minHeight: captionHeight, maxHeight: captionHeight, alignment: .bottomLeading)
                .clipped()
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Live captions")
        .accessibilityValue(recorder.captionTail(maxCharacters: 200))
        .accessibilityHint("Shows the full live transcript")
    }

    private var infoLine: some View {
        let photoCount = recorder.session?.photos.count ?? 0
        let savingAudio = !(recorder.session?.audioRecordings.isEmpty ?? true)
        return VStack(spacing: 4) {
            if speakerConfirmationVisible {
                Label("New speaker marked", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
            HStack(spacing: 16) {
                if let session = recorder.session {
                    Label(TranscriptLanguage.displayName(for: session.localeIdentifier), systemImage: "globe")
                }
                Label("\(photoCount) photo\(photoCount == 1 ? "" : "s")", systemImage: "photo")
                if savingAudio {
                    Label("Saving audio", systemImage: "waveform")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .animation(.default, value: speakerConfirmationVisible)
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            BigActionButton(title: "Photo", systemImage: "camera.fill") {
                showCamera = true
            }
            .accessibilityHint("Takes photos that are placed in the transcript at this moment")

            BigActionButton(title: "New speaker", systemImage: "person.wave.2.fill") {
                markSpeaker()
            }
            .accessibilityHint("Marks that a different person started talking")
        }
        .disabled(!recorder.isRecording)
    }

    private var stopButton: some View {
        Button {
            showStopConfirmation = true
        } label: {
            Label(recorder.state == .stopping ? "Finishing…" : "Stop", systemImage: "stop.fill")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
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
        case .starting: "First use may download the speech model."
        case .interrupted(let reason): "Paused: \(reason). Will resume automatically."
        case .stopping: "Saving the last words of the transcript."
        case .recording: "You can lock your phone. Recording continues."
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

/// A large square-ish button with an icon above its title.
private struct BigActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title)
                Text(title)
                    .font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 88)
        }
        .buttonStyle(.bordered)
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
                                ForEach(TranscriptFormatter.blocks(for: session.items, options: settings.formatOptions)) { block in
                                    TranscriptBlockRow(
                                        block: block,
                                        session: session,
                                        style: settings.timestampStyle,
                                        photoURL: { model.photoURL($0, in: session) }
                                    )
                                }
                            }
                            if !recorder.volatileText.isEmpty {
                                Text(recorder.volatileText)
                                    .foregroundStyle(.secondary)
                                    .italic()
                            }
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
