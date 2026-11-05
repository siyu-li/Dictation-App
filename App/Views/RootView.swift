import SwiftUI
import TranscriptCore

/// Home screen: saved recordings and the Start button. While a recording is
/// active, the recording screen covers everything.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(RecordingCoordinator.self) private var recorder

    @State private var path: [UUID] = []
    @State private var showSettings = false
    @State private var pendingDelete: TranscriptSession?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.sessions.isEmpty {
                    ContentUnavailableView(
                        "No recordings yet",
                        systemImage: "waveform",
                        description: Text("Tap Record to capture a conversation. The transcript is saved as you go. While recording, tap Slide photo to add slides to the transcript.")
                    )
                } else {
                    sessionList
                }
            }
            .navigationTitle("Dictation")
            .navigationDestination(for: UUID.self) { id in
                SessionDetailView(sessionID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                StartRecordingBar()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(model)
                .environment(settings)
                .environment(recorder)
        }
        .fullScreenCover(isPresented: recordingPresented) {
            RecordingView()
                .environment(model)
                .environment(settings)
                .environment(recorder)
        }
        .confirmationDialog(
            "Delete this recording?",
            isPresented: deletePresented,
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { session in
            Button("Delete", role: .destructive) {
                model.delete(id: session.id)
            }
        } message: { session in
            Text("“\(TranscriptExporter.displayTitle(for: session))” and its photos will be removed from this iPhone.")
        }
        // When a recording ends (Stop, or the engine gave up), open its transcript.
        .onChange(of: recorder.session?.id) { oldID, newID in
            guard let oldID, newID == nil, let finished = model.session(id: oldID) else { return }
            path = [finished.id]
            if settings.sendToNotesAfterStop {
                Task { await TranscriptSharing.sendToNotes(finished, settings: settings) }
            }
        }
    }

    private var sessionList: some View {
        List {
            Section {
                ForEach(model.sessions) { session in
                    NavigationLink(value: session.id) {
                        SessionRow(session: session)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            pendingDelete = session
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
            } footer: {
                Text("While recording, tap Slide photo to add slides to the transcript.")
            }
        }
        .listStyle(.insetGrouped)
    }

    private var recordingPresented: Binding<Bool> {
        Binding(get: { recorder.isActive }, set: { _ in })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }
}

/// One saved recording in the list.
private struct SessionRow: View {
    let session: TranscriptSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(TranscriptExporter.displayTitle(for: session))
                .font(.headline)
                .lineLimit(1)
            Text(TranscriptExporter.subtitle(for: session))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            let preview = session.previewText
            Text(preview.isEmpty ? "No speech recognized" : preview)
                .font(.subheadline)
                .foregroundStyle(preview.isEmpty ? HierarchicalShapeStyle.tertiary : HierarchicalShapeStyle.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// A compact language chip and the Record button, floating at the bottom of
/// the home screen.
private struct StartRecordingBar: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(RecordingCoordinator.self) private var recorder

    var body: some View {
        @Bindable var settings = settings
        VStack(spacing: 10) {
            if let error = recorder.lastError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        recorder.clearError()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss message")
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

            HStack(spacing: 10) {
                Menu {
                    Picker("Language", selection: $settings.language) {
                        ForEach(TranscriptLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                } label: {
                    Label(settings.language.shortName, systemImage: "globe")
                        .font(.subheadline.weight(.medium))
                        .frame(minHeight: 44)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Recording language, \(settings.language.displayName)")

                Button {
                    Task { await model.startRecording() }
                } label: {
                    Label("Record", systemImage: "mic.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glassProminent)
                .tint(.accentColor)
                .disabled(recorder.isActive)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}
