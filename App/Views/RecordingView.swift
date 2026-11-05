import SwiftUI
import TranscriptCore
import UIKit

/// Shown full-screen while a recording is active. Designed to be glanced at,
/// not watched: a caption card, the elapsed time, and big buttons. Same light
/// (system) look as the rest of the app. The phone may lock; recording
/// continues in the background. Nothing here animates continuously except the
/// small level meter, which only runs while this screen is visible.
struct RecordingView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(RecordingCoordinator.self) private var recorder

    @State private var showCamera = false
    @State private var showStopConfirmation = false
    @State private var showLiveTranscript = false
    /// Bumped on every New speaker / Bookmark tap (haptic + confirmation).
    @State private var markCount = 0
    @State private var confirmation: String?

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
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .sheet(isPresented: $showLiveTranscript) {
            LiveTranscriptView()
                .environment(model)
                .environment(settings)
                .environment(recorder)
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraView { data, takenAt in
                let photo = try recorder.addPhoto(jpegData: data, takenAt: takenAt)
                if let sessionID = recorder.session?.id {
                    model.recognizeSlideText(in: photo, sessionID: sessionID)
                }
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
        .sensoryFeedback(.impact(weight: .light), trigger: markCount)
    }

    // MARK: - Parts

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
                if recorder.state == .recording {
                    AudioLevelBars(meter: model.audioLevel)
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
                .font(.system(size: 60, weight: .light, design: .rounded).monospacedDigit())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .accessibilityLabel("Elapsed time \(TimestampFormatter.duration(elapsed))")
        }
    }

    /// The last few lines of the live transcript. Tap to see more.
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
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Live captions")
        .accessibilityValue(recorder.captionTail(maxCharacters: 200))
        .accessibilityHint("Shows the full live transcript")
    }

    private var infoLine: some View {
        let session = recorder.session
        let savingAudio = !(session?.audioRecordings.isEmpty ?? true)
        let bookmarkCount = session?.bookmarks.count ?? 0
        return VStack(spacing: 4) {
            if let confirmation {
                Label(confirmation, systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
            HStack(spacing: 16) {
                if bookmarkCount > 0 {
                    Label("\(bookmarkCount) bookmark\(bookmarkCount == 1 ? "" : "s")", systemImage: "star.fill")
                }
                if savingAudio {
                    Label("Saving audio", systemImage: "waveform")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .animation(.default, value: confirmation)
    }

    /// The camera is the main control (used at every slide). New speaker,
    /// Bookmark and a small Stop share the row below it.
    private var actionButtons: some View {
        VStack(spacing: 12) {
            recentPhotos
            Button {
                showCamera = true
            } label: {
                Label("Slide photo", systemImage: "camera.fill")
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            .buttonStyle(.glassProminent)
            .tint(.accentColor)
            .disabled(!recorder.isRecording)
            .accessibilityHint("Photos of slides go into the transcript at this moment and into the AI summary")

            HStack(spacing: 10) {
                RecordingActionButton(title: "New speaker", systemImage: "person.wave.2.fill") {
                    mark("New speaker marked") { recorder.markSpeakerChange() }
                }
                .disabled(!recorder.isRecording)
                .accessibilityHint("Marks that a different person started talking")

                RecordingActionButton(title: "Bookmark", systemImage: "star.fill") {
                    mark("Bookmarked") { recorder.markBookmark() }
                }
                .disabled(!recorder.isRecording)
                .accessibilityHint("Marks this moment as important; the AI summary will cover it")

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
            RecordingActionButton(title: "Cancel", systemImage: "xmark") {
                model.cancelStart()
            }
        } else {
            RecordingActionButton(
                title: recorder.state == .stopping ? "Finishing" : "Stop",
                systemImage: "stop.fill",
                tint: .red
            ) {
                showStopConfirmation = true
            }
            .disabled(!recorder.isRecording)
        }
    }

    // MARK: - Actions

    /// Runs a marker action with a light haptic and a short confirmation.
    private func mark(_ message: String, action: () -> Void) {
        action()
        markCount += 1
        confirmation = message
        let current = markCount
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if current == markCount { confirmation = nil }
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

/// A compact icon-over-title button for the row under Slide photo.
private struct RecordingActionButton: View {
    let title: String
    let systemImage: String
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .foregroundStyle(tint ?? .primary)
        }
        .buttonStyle(.glass)
    }
}

/// Five small bars showing that the microphone hears sound. Refreshed 10
/// times a second only while visible (TimelineView pauses off screen and when
/// the phone is locked); a static icon when Reduce Motion is on.
private struct AudioLevelBars: View {
    let meter: AudioLevelMeter

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                Image(systemName: "waveform")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    bars(level: CGFloat(meter.currentLevel))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func bars(level: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(level > CGFloat(index) / 5 ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 3, height: 6 + CGFloat(index) * 2.5)
            }
        }
        .frame(height: 18)
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
