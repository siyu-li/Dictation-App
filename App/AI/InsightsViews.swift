import SwiftUI
import TranscriptCore

/// AI summary card for a session's detail screen: generate button, progress,
/// errors, and the results (summary, key points, action items, speakers).
struct InsightsSection: View {
    let sessionID: UUID

    @Environment(AppModel.self) private var model

    var body: some View {
        if let session = model.session(id: sessionID) {
            VStack(alignment: .leading, spacing: 12) {
                header(session)
                switch model.insights.phase(for: sessionID) {
                case .running(let count):
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(count == 0 ? "Claude is reading the transcript…" : "Writing summary… (\(count) characters)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                    generateButton(session, title: "Try again")
                case .idle:
                    if let insights = session.insights {
                        InsightsContent(insights: insights, session: session)
                        generateButton(session, title: "Regenerate")
                    } else {
                        intro(session)
                    }
                }
            }
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func header(_ session: TranscriptSession) -> some View {
        Label("AI summary", systemImage: "sparkles")
            .font(.headline)
    }

    @ViewBuilder
    private func intro(_ session: TranscriptSession) -> some View {
        let ai = model.insights.settings
        Text("\(ai.provider.shortName) can write a title, a summary, key points, action items and chapters, and guess who was speaking.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        if !ai.hasAPIKey {
            Text("Add your \(ai.provider.shortName) API key in Settings to use this.")
                .font(.footnote)
                .foregroundStyle(.orange)
        } else {
            if let estimate = model.insights.estimate(for: session, format: model.settings.formatOptions) {
                let photoCount = ai.includePhotos ? min(session.photos.count, InsightsPrompt.maxPhotos) : 0
                let photoText = photoCount == 0 ? "" : " and \(photoCount) photo\(photoCount == 1 ? "" : "s")"
                let costText = estimate.cost.map { ", typically around \($0.formatted(.currency(code: "USD")))" } ?? ""
                Text("About \(estimate.tokens.formatted()) tokens\(costText) with \(ai.modelID(for: ai.provider)). Sends this transcript's text\(photoText) to \(ai.provider.shortName).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            generateButton(session, title: "Generate title & summary")
        }
    }

    private func generateButton(_ session: TranscriptSession, title: String) -> some View {
        Button {
            Task { await model.generateInsights(for: sessionID) }
        } label: {
            Label(title, systemImage: "sparkles")
        }
        .buttonStyle(.bordered)
        .disabled(!model.insights.settings.hasAPIKey || session.speechSegments.isEmpty)
    }
}

private struct InsightsContent: View {
    let insights: SessionInsights
    let session: TranscriptSession

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if insights.title != session.title {
                HStack {
                    Text("Suggested title: \(insights.title)")
                        .font(.subheadline)
                    Spacer()
                    Button("Use") {
                        var updated = session
                        updated.title = insights.title
                        model.update(updated)
                    }
                    .buttonStyle(.borderless)
                }
            }

            Text(insights.summary)
                .textSelection(.enabled)

            list("Key points", insights.keyPoints, symbol: "circle.fill")
            list("Action items", insights.actionItems, symbol: "checkmark.square")

            if !insights.speakers.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Speakers (guessed)").font(.subheadline.bold())
                    ForEach(insights.speakers, id: \.label) { speaker in
                        Text("\(speaker.label) — \(speaker.description)")
                            .font(.subheadline)
                    }
                }
            }

            Text(footer)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: String {
        var parts = [insights.model, insights.generatedAt.formatted(date: .abbreviated, time: .shortened)]
        if let input = insights.inputTokens, let output = insights.outputTokens {
            var usage = "\(input.formatted()) in / \(output.formatted()) out tokens"
            if let cost = ModelPricing.cost(modelID: insights.model, inputTokens: input, outputTokens: output) {
                usage += " ≈ \(cost.formatted(.currency(code: "USD")))"
            }
            parts.append(usage)
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func list(_ title: String, _ items: [String], symbol: String) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.bold())
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Label {
                        Text(item).textSelection(.enabled)
                    } icon: {
                        Image(systemName: symbol).imageScale(.small)
                    }
                    .font(.subheadline)
                }
            }
        }
    }
}

/// Settings section: provider, API key, model, summary language, photos.
struct AISettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var keyDraft = ""

    var body: some View {
        let ai = model.insights.settings
        let provider = ai.provider
        Section {
            Picker("AI", selection: Bindable(ai).provider) {
                ForEach(AIProvider.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }

            if ai.hasAPIKey(for: provider) {
                LabeledContent("API key", value: "Saved on this iPhone")
                Button("Remove \(provider.shortName) API key", role: .destructive) {
                    ai.setAPIKey("", for: provider)
                }
            } else {
                SecureField(provider.keyPlaceholder, text: $keyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save API key") {
                    ai.setAPIKey(keyDraft, for: provider)
                    keyDraft = ""
                }
                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if provider == .claude {
                Picker("Model", selection: Bindable(ai).claudeModel) {
                    ForEach(ClaudeModel.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            } else {
                LabeledContent("Model") {
                    TextField(provider.defaultModel, text: Binding(
                        get: { ai.customModel(for: provider) },
                        set: { ai.setCustomModel($0, for: provider) }
                    ))
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }
            }

            Picker("Summary language", selection: Bindable(ai).summaryLanguage) {
                ForEach(SummaryLanguage.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            Toggle("Include photos (slides)", isOn: Bindable(ai).includePhotos)
        } header: {
            Text("AI summaries")
        } footer: {
            Text("Get a \(provider.shortName) API key at \(provider.keyWebsite). Keys are stored in this iPhone's Keychain. When you tap Generate, that recording's transcript text (and its photos, if included) is sent to \(provider.shortName); nothing is sent otherwise. Leave Model empty to use \(provider.defaultModel).")
        }
        .onChange(of: provider) { keyDraft = "" }
    }
}
