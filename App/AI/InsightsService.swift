import Foundation
import Observation
import TranscriptCore

/// AI preferences. The API key lives in the Keychain; the model choice in
/// UserDefaults.
@MainActor
@Observable
final class AISettings {
    @ObservationIgnored private let defaults: UserDefaults

    var model: ClaudeModel {
        didSet { defaults.set(model.rawValue, forKey: "ai.model") }
    }

    private(set) var hasAPIKey: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        model = ClaudeModel(rawValue: defaults.string(forKey: "ai.model") ?? "") ?? .default
        hasAPIKey = KeychainStore.readAPIKey() != nil
    }

    func apiKey() -> String? {
        KeychainStore.readAPIKey()
    }

    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.deleteAPIKey()
        } else {
            KeychainStore.saveAPIKey(trimmed)
        }
        hasAPIKey = KeychainStore.readAPIKey() != nil
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
    @ObservationIgnored private let client = ClaudeClient()
    private var phases: [UUID: Phase] = [:]

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

    /// Rough input size and upper-end cost, or nil if there's nothing to send.
    func estimate(for session: TranscriptSession, format: FormatOptions) -> (tokens: Int, cost: Double)? {
        guard let request = try? InsightsRequest(session: session, model: settings.model, format: format) else {
            return nil
        }
        return (request.estimatedInputTokens, request.estimatedMaxCost)
    }

    /// Calls Claude and returns the insights, or nil on failure (the error is
    /// available through `phase(for:)`).
    func generate(for session: TranscriptSession, format: FormatOptions) async -> SessionInsights? {
        let id = session.id
        guard !isRunning(id) else { return nil }
        guard let apiKey = settings.apiKey() else {
            phases[id] = .failed(ClaudeAPIError.missingAPIKey.errorDescription ?? "Missing API key")
            return nil
        }
        do {
            let request = try InsightsRequest(session: session, model: settings.model, format: format)
            phases[id] = .running(receivedCharacters: 0)
            log.log("Insights: model=\(request.model.rawValue) paragraphs=\(request.paragraphStarts.count) ~\(request.estimatedInputTokens) input tokens", category: "ai")

            let result = try await client.send(request, apiKey: apiKey) { [weak self] count in
                Task { @MainActor in
                    guard let self, case .running = self.phases[id] else { return }
                    self.phases[id] = .running(receivedCharacters: count)
                }
            }
            let text = try result.finalText()
            let insights = try InsightsResponseParser.parse(
                text,
                request: request,
                model: result.model,
                inputTokens: result.inputTokens,
                outputTokens: result.outputTokens
            )
            phases[id] = .idle
            log.log("Insights done: model=\(insights.model) in=\(insights.inputTokens ?? -1) out=\(insights.outputTokens ?? -1)", category: "ai")
            return insights
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phases[id] = .failed(message)
            log.log("Insights failed: \(error)", category: "ai")
            return nil
        }
    }
}

extension AppModel {
    /// Generates insights for a saved session and stores them. Uses the latest
    /// saved version of the session, so edits made meanwhile are kept. Fills
    /// in the title if the session has none.
    func generateInsights(for sessionID: UUID) async {
        guard let session = session(id: sessionID) else { return }
        guard let insights = await insights.generate(for: session, format: settings.formatOptions) else { return }
        guard var latest = self.session(id: sessionID) else { return }
        latest.insights = insights
        if (latest.title ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            latest.title = insights.title
        }
        update(latest)
    }
}
