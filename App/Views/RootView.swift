import SwiftUI
import TranscriptCore

/// Placeholder home screen: list of sessions plus a start/stop button.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(RecordingCoordinator.self) private var recorder

    var body: some View {
        NavigationStack {
            List(model.sessions) { session in
                VStack(alignment: .leading, spacing: 4) {
                    Text(TranscriptExporter.displayTitle(for: session))
                        .font(.headline)
                    Text(TranscriptExporter.subtitle(for: session))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Dictation")
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if let error = recorder.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    Button(recorder.isActive ? "Stop" : "Start recording") {
                        Task {
                            if recorder.isActive {
                                await model.stopRecording()
                            } else {
                                await model.startRecording()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
    }
}
