import Foundation

/// An OpenAI-style chat completions request for an `InsightsPrompt`, used for
/// ChatGPT, Gemini (Google's OpenAI-compatible endpoint) and Qwen (via
/// OpenRouter). Streams, with strict JSON-schema output.
public struct ChatCompletionsRequest: Sendable {
    public enum BuildError: Error, Equatable, LocalizedError {
        case notAChatCompletionsProvider

        public var errorDescription: String? {
            "This AI provider doesn't use the chat completions format."
        }
    }

    public let provider: AIProvider
    public let model: String
    public let prompt: InsightsPrompt
    public let endpoint: URL
    /// JSON request body.
    public let body: Data

    /// HTTP headers (the caller adds `Authorization: Bearer <key>`).
    public var headers: [String: String] {
        var headers = ["content-type": "application/json"]
        if provider == .qwen { headers["X-Title"] = "Dictation" }
        return headers
    }

    public var estimatedInputTokens: Int { prompt.estimatedInputTokens }

    /// Typical cost in USD when the model's price is known (~8k output tokens).
    public var estimatedCost: Double? {
        ModelPricing.cost(modelID: model, inputTokens: estimatedInputTokens, outputTokens: 8_000)
    }

    public init(prompt: InsightsPrompt, provider: AIProvider, model: String? = nil) throws {
        guard let endpoint = provider.chatCompletionsURL else { throw BuildError.notAChatCompletionsProvider }
        let model = (model?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? provider.defaultModel
        self.provider = provider
        self.model = model
        self.prompt = prompt
        self.endpoint = endpoint

        let userContent: Any
        if prompt.photos.isEmpty {
            userContent = prompt.userText
        } else {
            var parts: [[String: Any]] = []
            for (label, photo) in zip(prompt.photoLabels, prompt.photos) {
                parts.append(["type": "text", "text": label])
                parts.append([
                    "type": "image_url",
                    "image_url": ["url": "data:image/jpeg;base64," + photo.jpegData.base64EncodedString()],
                ])
            }
            parts.append(["type": "text", "text": prompt.userText])
            userContent = parts
        }

        var json: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": [
                ["role": "system", "content": prompt.systemText],
                ["role": "user", "content": userContent],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "session_insights",
                    "strict": true,
                    "schema": InsightsPrompt.schema,
                ],
            ],
        ]
        // Token usage in the last streamed chunk (not offered by Gemini's endpoint).
        if provider != .gemini {
            json["stream_options"] = ["include_usage": true]
        }
        self.body = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }
}

/// Accumulates a streamed chat completions response (`data: {...}` lines,
/// ending with `data: [DONE]`).
public struct ChatCompletionStreamAccumulator: Sendable {
    public private(set) var text = ""
    public private(set) var model: String?
    public private(set) var finishReason: String?
    public private(set) var inputTokens: Int?
    public private(set) var outputTokens: Int?
    public private(set) var streamError: AIServiceError?
    public private(set) var isComplete = false

    public init() {}

    public mutating func consume(line: String) {
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            isComplete = true
            return
        }
        guard let data = payload.data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        if let error = event["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? 500
            streamError = .http(status: code, type: error["type"] as? String ?? error["status"] as? String, message: error["message"] as? String)
            return
        }
        if let model = event["model"] as? String { self.model = model }
        if let choices = event["choices"] as? [[String: Any]], let choice = choices.first {
            if let delta = choice["delta"] as? [String: Any], let content = delta["content"] as? String {
                text += content
            }
            if let reason = choice["finish_reason"] as? String { finishReason = reason }
        }
        if let usage = event["usage"] as? [String: Any] {
            if let prompt = usage["prompt_tokens"] as? Int { inputTokens = prompt }
            if let completion = usage["completion_tokens"] as? Int { outputTokens = completion }
        }
    }

    /// The final text, or the reason there is none.
    public func finalText() throws -> String {
        if let streamError { throw streamError }
        switch finishReason {
        case "length": throw AIServiceError.truncated
        case "content_filter": throw AIServiceError.refusal(category: "content_filter")
        default: break
        }
        guard isComplete || finishReason != nil else {
            throw AIServiceError.network("the response ended early")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIServiceError.emptyResponse }
        return trimmed
    }
}
