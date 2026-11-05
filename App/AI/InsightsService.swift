import Foundation
import Observation
import TranscriptCore
import UIKit

/// AI preferences: which provider writes summaries (ChatGPT by default), the
/// model for each provider, the summary language and whether photos are
/// sent. API keys live in the Keychain, one per provider.
@MainActor
@Observable
final class AISettings {
    @ObservationIgnored private let defaults: UserDefaults

    var provider: AIProvider {
        didSet { defaults.set(provider.rawValue, forKey: "ai.provider") }
    }

    /// Model used when the provider is Claude.
    var claudeModel: ClaudeModel {
        didSet { defaults.set(claudeModel.rawValue, forKey: "ai.model") }
    }

    /// Model ids typed in Settings for ChatGPT, Gemini and Qwen (empty = default).
    private(set) var customModels: [AIProvider: String] = [:]

    var summaryLanguage: SummaryLanguage {
        didSet { defaults.set(summaryLanguage.rawValue, forKey: "ai.summaryLanguage") }
    }

    /// Send the session's photos (slides) along with the transcript.
    var includePhotos: Bool {
        didSet { defaults.set(includePhotos, forKey: "ai.includePhotos") }
    }

    private var savedKeys: Set<AIProvider> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        provider = AIProvider(rawValue: defaults.string(forKey: "ai.provider") ?? "") ?? .default
        claudeModel = ClaudeModel(rawValue: defaults.string(forKey: "ai.model") ?? "") ?? .default
        summaryLanguage = SummaryLanguage(rawValue: defaults.string(forKey: "ai.summaryLanguage") ?? "") ?? .automatic
        includePhotos = defaults.object(forKey: "ai.includePhotos") as? Bool ?? true
        for provider in AIProvider.allCases {
            if let model = defaults.string(forKey: Self.modelKey(provider)) { customModels[provider] = model }
            if KeychainStore.readAPIKey(for: provider) != nil { savedKeys.insert(provider) }
        }
    }

    private static func modelKey(_ provider: AIProvider) -> String { "ai.model.\(provider.rawValue)" }

    // MARK: Models

    /// The model id that will be used for a provider.
    func modelID(for provider: AIProvider) -> String {
        if provider == .claude { return claudeModel.rawValue }
        let custom = (customModels[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? provider.defaultModel : custom
    }

    /// The text in the model field (empty when the default is used).
    func customModel(for provider: AIProvider) -> String {
        customModels[provider] ?? ""
    }

    func setCustomModel(_ model: String, for provider: AIProvider) {
        customModels[provider] = model
        defaults.set(model, forKey: Self.modelKey(provider))
    }

    // MARK: Keys

    var hasAPIKey: Bool { hasAPIKey(for: provider) }

    func hasAPIKey(for provider: AIProvider) -> Bool {
        savedKeys.contains(provider)
    }

    func apiKey(for provider: AIProvider) -> String? {
        KeychainStore.readAPIKey(for: provider)
    }

    func setAPIKey(_ key: String, for provider: AIProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.deleteAPIKey(for: provider)
        } else {
            KeychainStore.saveAPIKey(trimmed, for: provider)
        }
        if KeychainStore.readAPIKey(for: provider) != nil {
            savedKeys.insert(provider)
        } else {
            savedKeys.remove(provider)
        }
    }
}

/// Generates AI insights for sessions, one request per session at a time.
@MainActor
@Observable
final class InsightsService {
    enum Phase: Equatable {
        case idle
        case running(receivedCharacters: Int)
        case failed(String)
    }

    let settings: AISettings
    @ObservationIgnored private let log: DiagnosticsLog
    @ObservationIgnored private let claudeClient = ClaudeClient()
    @ObservationIgnored private let chatClient = ChatCompletionsClient()
    private var phases: [UUID: Phase] = [:]
    /// Estimates are cached because building a request formats the whole transcript.
    @ObservationIgnored private var estimateCache: [String: (tokens: Int, cost: Double?)] = [:]

    init(settings: AISettings, log: DiagnosticsLog) {
        self.settings = settings
        self.log = log
    }

    func phase(for sessionID: UUID) -> Phase {
        phases[sessionID] ?? .idle
    }

    func isRunning(_ sessionID: UUID) -> Bool {
        if case .running = phase(for: sessionID) { return true }
        return false
    }

    /// Rough input size and typical cost (nil cost when the model's price is
    /// unknown), or nil if there's nothing to send.
    func estimate(for session: TranscriptSession, format: FormatOptions) -> (tokens: Int, cost: Double?)? {
        let provider = settings.provider
        let model = settings.modelID(for: provider)
        let key = "\(session.id)|\(session.items.count)|\(model)|\(format.pauseThreshold)|\(settings.includePhotos)|\(settings.summaryLanguage.rawValue)"
        if let cached = estimateCache[key] { return cached }
        guard let prompt = try? InsightsPrompt(session: session, format: format, language: settings.summaryLanguage) else {
            return nil
        }
        // Photos are prepared only when generating; assume ~1568×1176 each.
        let photoCount = settings.includePhotos ? min(session.photos.count, InsightsPrompt.maxPhotos) : 0
        let photoTokens = photoCount * InsightsPhoto(
            id: UUID(), takenAt: Date(), jpegData: Data(),
            pixelWidth: InsightsPrompt.recommendedPhotoMaxPixels, pixelHeight: InsightsPrompt.recommendedPhotoMaxPixels * 3 / 4
        ).visualTokens
        let tokens = prompt.estimatedInputTokens + photoTokens
        let value = (tokens: tokens, cost: ModelPricing.cost(modelID: model, inputTokens: tokens, outputTokens: 8_000))
        estimateCache[key] = value
        return value
    }

    /// Calls the selected AI and returns the insights, or nil on failure (the
    /// error is available through `phase(for:)`).
    func generate(for session: TranscriptSession, format: FormatOptions, store: FileSessionStore) async -> SessionInsights? {
        let id = session.id
        guard !isRunning(id) else { return nil }
        let provider = settings.provider
        guard let apiKey = settings.apiKey(for: provider) else {
            phases[id] = .failed("Add your \(provider.shortName) API key in Settings first.")
            return nil
        }
        // Ask iOS for time to finish if the user locks the phone or switches
        // apps while the AI is writing. When the time runs out the task must be
        // ended, or iOS terminates the app; the request then fails and the
        // user can tap Try again.
        let backgroundTask = BackgroundTaskHandle()
        backgroundTask.id = UIApplication.shared.beginBackgroundTask(withName: "AI summary") {
            MainActor.assumeIsolated { backgroundTask.end() }
        }
        defer { backgroundTask.end() }
        do {
            phases[id] = .running(receivedCharacters: 0)
            let photos = settings.includePhotos
                ? await InsightsPhotoPreparer.prepare(session.photos, sessionID: session.id, store: store)
                : []
            let prompt = try InsightsPrompt(session: session, format: format, photos: photos, language: settings.summaryLanguage)
            let progress: @Sendable (Int) -> Void = { [weak self] count in
                Task { @MainActor in
                    guard let self, case .running = self.phases[id] else { return }
                    self.phases[id] = .running(receivedCharacters: count)
                }
            }

            let text: String
            let model: String
            let inputTokens: Int?
            let outputTokens: Int?
            switch provider {
            case .claude:
                let request = try InsightsRequest(prompt: prompt, model: settings.claudeModel)
                logRequest(provider, request.model.rawValue, prompt)
                let result = try await claudeClient.send(request, apiKey: apiKey, progress: progress)
                text = try result.finalText()
                model = result.model ?? request.model.rawValue
                inputTokens = result.inputTokens
                outputTokens = result.outputTokens
            case .chatGPT, .gemini, .qwen:
                let request = try ChatCompletionsRequest(prompt: prompt, provider: provider, model: settings.modelID(for: provider))
                logRequest(provider, request.model, prompt)
                let result = try await chatClient.send(request, apiKey: apiKey, progress: progress)
                text = try result.finalText()
                model = result.model ?? request.model
                inputTokens = result.inputTokens
                outputTokens = result.outputTokens
            }

            let insights = try InsightsResponseParser.parse(
                text,
                prompt: prompt,
                model: model,
                inputTokens: inputTokens,
                outputTokens: outputTokens
            )
            phases[id] = .idle
            log.log("Insights done: model=\(insights.model) in=\(insights.inputTokens ?? -1) out=\(insights.outputTokens ?? -1)", category: "ai")
            return insights
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phases[id] = .failed(message)
            log.log("Insights failed (\(provider.rawValue)): \(error)", category: "ai")
            return nil
        }
    }

    private func logRequest(_ provider: AIProvider, _ model: String, _ prompt: InsightsPrompt) {
        log.log("Insights: provider=\(provider.rawValue) model=\(model) paragraphs=\(prompt.paragraphStarts.count) photos=\(prompt.photoIDs.count) ~\(prompt.estimatedInputTokens) input tokens", category: "ai")
    }
}

extension AppModel {
    /// Generates insights for a saved session and stores them. Uses the latest
    /// saved version of the session, so edits made meanwhile are kept. Fills
    /// in the title if the session has none.
    func generateInsights(for sessionID: UUID) async {
        guard let session = session(id: sessionID) else { return }
        guard let insights = await insights.generate(for: session, format: settings.formatOptions, store: store) else { return }
        guard var latest = self.session(id: sessionID) else { return }
        latest.insights = insights
        if (latest.title ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            latest.title = insights.title
        }
        update(latest)
    }
}

/// A UIKit background task id shared by the expiration handler and the
/// normal end, so it's ended exactly once.
@MainActor
private final class BackgroundTaskHandle {
    var id: UIBackgroundTaskIdentifier = .invalid

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
