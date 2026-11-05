import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct DictationWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
    }
}

/// The recording on the Lock Screen: status, elapsed time, the latest
/// caption, counts, and New speaker / Bookmark buttons. The iPhone 13 has no
/// Dynamic Island, so the island presentations are kept minimal.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            RecordingLockScreenView(context: context)
                .activitySystemActionForegroundColor(.indigo)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StatusDot(isPaused: context.state.isPaused)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedText(startedAt: context.attributes.startedAt)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.caption)
                        .font(.footnote)
                        .lineLimit(2)
                }
            } compactLeading: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.indigo)
            } compactTrailing: {
                ElapsedText(startedAt: context.attributes.startedAt)
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.indigo)
            }
        }
    }
}

struct RecordingLockScreenView: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusDot(isPaused: context.state.isPaused)
                Text(context.state.statusText)
                    .font(.subheadline.weight(.semibold))
                Text(context.attributes.language)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                ElapsedText(startedAt: context.attributes.startedAt)
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: 90, alignment: .trailing)
            }

            if !context.state.caption.isEmpty {
                Text(context.state.caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Button(intent: MarkSpeakerIntent()) {
                    Label("New speaker", systemImage: "person.wave.2.fill")
                }
                Button(intent: AddBookmarkIntent()) {
                    Label("Bookmark", systemImage: "star.fill")
                }
                Spacer(minLength: 4)
                HStack(spacing: 10) {
                    Label("\(context.state.photoCount)", systemImage: "camera")
                    Label("\(context.state.bookmarkCount)", systemImage: "star")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .font(.footnote.weight(.medium))
            .buttonStyle(.bordered)
            .tint(.indigo)
        }
        .padding(16)
    }
}

/// Small state dot: red while recording, orange while paused.
struct StatusDot: View {
    let isPaused: Bool

    var body: some View {
        Circle()
            .fill(isPaused ? Color.orange : Color.red)
            .frame(width: 8, height: 8)
            .accessibilityLabel(isPaused ? "Paused" : "Recording")
    }
}

/// Time since the recording started. The system keeps it ticking; the app
/// never has to update it.
struct ElapsedText: View {
    let startedAt: Date

    var body: some View {
        Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
    }
}
