import Foundation

/// The Claude Messages API request for an `InsightsPrompt`. The app sends it
/// over HTTPS (there is no Swift SDK).
public struct InsightsRequest: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2026-10-21"
    /// Beta header for `fallbacks: "default"` (server-side refusal fallback).
    public static let fallbackBeta = "server-side-fallback-2026-07-01"

    public typealias BuildError = InsightsPrompt.BuildError
    public static var recommendedPhotoMaxPixels: Int { InsightsPrompt.recommendedPhotoMaxPixels }
    public static var maxPhotos: Int { InsightsPrompt.maxPhotos }

    public static func spread<T>(_ items: [T], limit: Int) -> [T] {
        InsightsPrompt.spread(items, limit: limit)
    }

    public let model: ClaudeModel
    public let prompt: InsightsPrompt
    /// JSON request body.
    public let body: Data

    public var paragraphStarts: [Date] { prompt.paragraphStarts }
    public var transcriptText: String { prompt.transcriptText }
    public var photoIDs: [UUID] { prompt.photoIDs }
    public var photoTokens: Int { prompt.photoTokens }

    /// HTTP headers for the request (the API key is added by the caller).
    public var headers: [String: String] {
        var headers = [
            "content-type": "application/json",
            "anthropic-version": Self.apiVersion,
        ]
        if model.supportsServerFallback { headers["anthropic-beta"] = Self.fallbackBeta }
        return headers
    }

    public var estimatedInputTokens: Int { prompt.estimatedInputTokens }

    /// Typical cost in USD, assuming ~8k output tokens (thinking included).
    /// A rough guide, not a limit.
    public var estimatedCost: Double {
        model.cost(inputTokens: estimatedInputTokens, outputTokens: 8_000)
    }

    public init(prompt: InsightsPrompt, model: ClaudeModel = .default) throws {
        self.prompt = prompt
        self.model = model

        let content: Any
        if prompt.photos.isEmpty {
            content = prompt.userText
        } else {
            // Each photo is introduced by a label, then the transcript and instructions.
            var blocks: [[String: Any]] = []
            for (label, photo) in zip(prompt.photoLabels, prompt.photos) {
                blocks.append(["type": "text", "text": label])
                blocks.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": photo.jpegData.base64EncodedString(),
                    ],
                ])
            }
            blocks.append(["type": "text", "text": prompt.userText])
            content = blocks
        }

        var json: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 64_000,
            "stream": true,
            "system": prompt.systemText,
            "messages": [
                ["role": "user", "content": content],
            ],
            "output_config": [
                "effort": "medium",
                "format": ["type": "json_schema", "schema": InsightsPrompt.schema],
            ],
        ]
        if model.supportsServerFallback { json["fallbacks"] = "default" }
        self.body = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    public init(
        session: TranscriptSession,
        model: ClaudeModel = .default,
        format: FormatOptions = .init(),
        timeZone: TimeZone = .current,
        photos: [InsightsPhoto] = [],
        language: SummaryLanguage = .automatic
    ) throws {
        try self.init(
            prompt: InsightsPrompt(session: session, format: format, timeZone: timeZone, photos: photos, language: language),
            model: model
        )
    }
}
