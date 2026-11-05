import Foundation
import Observation
import TranscriptCore
import UIKit

/// AI preferences. The API key lives in the Keychain; the model choice in
/// UserDefaults.
@MainActor
@Observable
final class AISettings {
    @ObservationIgnored private let defaults: UserDefaults

    var model: ClaudeModel {
        didSet { defaults.set(model.rawValue, forKey: "ai.model") }
    }

    /// Send the session's photos (slides) to Claude along with the transcript.
    var includePhotos: Bool {
        didSet { defaults.set(includePhotos, forKey: "ai.includePhotos") }
    }

    private(set) var hasAPIKey: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        model = ClaudeModel(rawValue: defaults.string(forKey: "ai.model") ?? "") ?? .default
        includePhotos = defaults.object(forKey: "ai.includePhotos") as? Bool ?? true
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
    /// Estimates are cached because building a request formats the whole transcript.
    @ObservationIgnored private var estimateCache: [String: (tokens: Int, cost: Double)] = [:]

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
        let key = "\(session.id)|\(session.items.count)|\(settings.model.rawValue)|\(format.pauseThreshold)|\(settings.includePhotos)"
        if let cached = estimateCache[key] { return cached }
        guard let request = try? InsightsRequest(session: session, model: settings.model, format: format) else {
            return nil
        }
        // Photos are prepared only when generating; assume ~1568×1176 each.
        let photoCount = settings.includePhotos ? min(session.photos.count, InsightsRequest.maxPhotos) : 0
        let photoTokens = photoCount * InsightsPhoto(
            id: UUID(), takenAt: Date(), jpegData: Data(),
            pixelWidth: InsightsRequest.recommendedPhotoMaxPixels, pixelHeight: InsightsRequest.recommendedPhotoMaxPixels * 3 / 4
        ).visualTokens
        let tokens = request.estimatedInputTokens + photoTokens
        let value = (tokens, settings.model.cost(inputTokens: tokens, outputTokens: 8_000))
        estimateCache[key] = value
        return value
    }

    /// Calls Claude and returns the insights, or nil on failure (the error is
    /// available through `phase(for:)`).
    func generate(for session: TranscriptSession, format: FormatOptions, store: FileSessionStore) async -> SessionInsights? {
        let id = session.id
        guard !isRunning(id) else { return nil }
        guard let apiKey = settings.apiKey() else {
            phases[id] = .failed(ClaudeAPIError.missingAPIKey.errorDescription ?? "Missing API key")
            return nil
        }
        // Ask iOS for time to finish if the user locks the phone or switches
        // apps while Claude is writing. When the time runs out the task must be
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
            let request = try InsightsRequest(session: session, model: settings.model, format: format, photos: photos)
            log.log("Insights: model=\(request.model.rawValue) paragraphs=\(request.paragraphStarts.count) photos=\(request.photoIDs.count) ~\(request.estimatedInputTokens) input tokens", category: "ai")

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
