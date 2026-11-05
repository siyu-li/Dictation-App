import SwiftUI
import TranscriptCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    Picker("Language", selection: $settings.language) {
                        ForEach(TranscriptLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    Toggle("Save audio", isOn: $settings.saveAudio)
                } header: {
                    Text("Recording")
                } footer: {
                    Text("Speech is recognized on your iPhone, one language per recording. Saving audio keeps a sound recording next to the transcript, about 15–30 MB per hour; it's off by default to save storage.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("New paragraph after a pause of")
                            Spacer()
                            Text(String(format: "%.1f s", settings.pauseThreshold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.pauseThreshold, in: 1...5, step: 0.5) {
                            Text("Paragraph pause")
                        } minimumValueLabel: {
                            Text("1 s")
                        } maximumValueLabel: {
                            Text("5 s")
                        }
                        .accessibilityValue(Text(String(format: "%.1f seconds", settings.pauseThreshold)))
                    }
                    Picker("Timestamps", selection: $settings.timestampStyle) {
                        ForEach(TimestampStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                } header: {
                    Text("Transcript")
                }

                Section {
                    LabeledContent("Shortcut name") {
                        TextField("Dictation to Notes", text: $settings.notesShortcutName)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    Toggle("Send to Notes after stopping", isOn: $settings.sendToNotesAfterStop)
                    DisclosureGroup("How to set up") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("1. Open the Shortcuts app and create a new shortcut named exactly as above.")
                            Text("2. Add the action “Get Dictation Transcript” and set its Session ID to Shortcut Input.")
                            Text("3. Add the Notes action “Create Note” with the transcript as the body.")
                            Text("Then use Send to Notes on a transcript, or turn on the switch above.")
                                .foregroundStyle(.secondary)
                        }
                        .font(.footnote)
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Apple Notes")
                } footer: {
                    Text("Apps can't write into Notes directly, so Dictation runs a Shortcut that creates the note.")
                }

                AISettingsSection()

                Section {
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                } footer: {
                    Text("A log of what the app did while recording. Share it after testing so problems can be fixed.")
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// Recent log lines plus sharing the full log as a text file.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model

    @State private var entries: [String] = []
    @State private var logFileURL: URL?
    @State private var showClearConfirmation = false

    var body: some View {
        List {
            Section {
                if let logFileURL {
                    ShareLink(item: logFileURL) {
                        Label("Share full log", systemImage: "square.and.arrow.up")
                    }
                }
                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    Label("Clear log", systemImage: "trash")
                }
            } footer: {
                Text("The full log includes earlier launches. It contains app events and errors, not your transcripts.")
            }

            Section("Since the app was opened") {
                if entries.isEmpty {
                    Text("No entries yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(entries.reversed().enumerated()), id: \.offset) { _, entry in
                    Text(entry)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { reload() }
        .task { reload() }
        .confirmationDialog("Clear the diagnostics log?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Clear log", role: .destructive) {
                model.log.clear()
                reload()
            }
        }
    }

    private func reload() {
        entries = model.log.recentEntries()
        let url = FileManager.default.temporaryDirectory.appending(path: "Dictation-diagnostics.txt")
        do {
            try Data(model.log.exportText().utf8).write(to: url, options: .atomic)
            logFileURL = url
        } catch {
            logFileURL = nil
        }
    }
}
