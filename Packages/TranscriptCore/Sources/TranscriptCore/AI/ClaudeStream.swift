import Foundation

/// Problems talking to an AI service, with messages meant for the user.
public enum AIServiceError: Error, Equatable, LocalizedError {
    case missingAPIKey
    /// Non-2xx HTTP response (or an `error` event in the stream).
    case http(status: Int, type: String?, message: String?)
    case refusal(category: String?)
    case truncated
    case emptyResponse
    case invalidOutput(String)
    case network(String)
    /// The connection failed after the AI had started answering. Not retried
    /// automatically, because a retry is billed again.
    case streamInterrupted(String)

    /// Worth retrying automatically (rate limits, overload, server errors).
    public var isRetryable: Bool {
        switch self {
        case .http(let status, let type, _):
            // No credit left is reported as 429 by OpenAI; retrying won't help.
            if type == "insufficient_quota" { return false }
            return status == 429 || status >= 500 || type == "overloaded_error" || type == "api_error" || type == "rate_limit_error"
        case .network: return true
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add an API key for the selected AI in Settings first."
        case .http(let status, let type, let message):
            switch (status, type ?? "") {
            case (401, _), (_, "authentication_error"):
                return "The API key was rejected. Check it in Settings."
            case (_, "insufficient_quota"):
                return "Your API account has no credit left. API use is billed separately from a ChatGPT or Claude subscription: add credit on the provider's website, then try again." + Self.detail(message)
            case (402, _), (_, "billing_error"):
                return "Your API account has a billing problem (out of credit?)." + Self.detail(message)
            case (403, _), (_, "permission_error"):
                return "This API key isn't allowed to use that model."
            case (404, _), (_, "not_found_error"):
                return "That model isn't available to your account. Check the model in Settings."
            case (413, _), (_, "request_too_large"):
                return "This transcript is too long to send in one request."
            case (429, _), (_, "rate_limit_error"):
                return "Too many requests right now. Try again in a minute." + Self.detail(message)
            case (529, _), (_, "overloaded_error"):
                return "The AI service is busy right now. Try again in a few minutes."
            default:
                return "AI service error \(status)" + (message.map { ": \($0)" } ?? ".")
            }
        case .refusal:
            return "The AI declined to process this transcript."
        case .truncated:
            return "The answer was cut off. Try again."
        case .emptyResponse:
            return "The AI returned an empty answer. Try again."
        case .invalidOutput(let detail):
            return "Couldn't read the AI's answer (\(detail)). Try again."
        case .network(let detail):
            return "Network problem: \(detail)"
        case .streamInterrupted(let detail):
            return "The connection dropped while the AI was writing (\(detail)). Tap Try again."
        }
    }

    /// The server's own explanation, appended in parentheses.
    private static func detail(_ message: String?) -> String {
        guard let message = message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else { return "" }
        return " (\(message.prefix(200)))"
    }

    /// Parses an API error body: `{"error":{"type":...,"message":...}}`
    /// (Anthropic, OpenAI, OpenRouter) or a one-element array of it (Gemini).
    public static func fromResponse(status: Int, body: Data) -> AIServiceError {
        let json = try? JSONSerialization.jsonObject(with: body)
        let object = (json as? [String: Any]) ?? (json as? [[String: Any]])?.first
        let error = object?["error"] as? [String: Any]
        let type = error?["type"] as? String ?? error?["status"] as? String
        return .http(status: status, type: type, message: error?["message"] as? String)
    }
}

/// Accumulates a streamed (SSE) Messages API response. Feed it every line of
/// the response body; only `data:` lines matter. Text from `text` blocks is
/// concatenated; thinking blocks and other block types are ignored.
public struct ClaudeStreamAccumulator: Sendable {
    public private(set) var text = ""
    public private(set) var model: String?
    public private(set) var stopReason: String?
    public private(set) var refusalCategory: String?
    public private(set) var inputTokens: Int?
    public private(set) var outputTokens: Int?
    public private(set) var streamError: AIServiceError?
    public private(set) var isComplete = false
    private var textBlockIndexes: Set<Int> = []

    public init() {}

    public mutating func consume(line: String) {
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = event["type"] as? String else { return }

        switch type {
        case "message_start":
            let message = event["message"] as? [String: Any]
            model = message?["model"] as? String
            if let usage = message?["usage"] as? [String: Any] {
                inputTokens = Self.totalInput(usage)
                outputTokens = usage["output_tokens"] as? Int ?? outputTokens
            }
        case "content_block_start":
            if let index = event["index"] as? Int,
               let block = event["content_block"] as? [String: Any],
               block["type"] as? String == "text" {
                textBlockIndexes.insert(index)
                text += block["text"] as? String ?? ""
            }
        case "content_block_delta":
            if let index = event["index"] as? Int, textBlockIndexes.contains(index),
               let delta = event["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta" {
                text += delta["text"] as? String ?? ""
            }
        case "message_delta":
            if let delta = event["delta"] as? [String: Any] {
                if let reason = delta["stop_reason"] as? String { stopReason = reason }
                if let details = delta["stop_details"] as? [String: Any] {
                    refusalCategory = details["category"] as? String
                }
            }
            if let usage = event["usage"] as? [String: Any] {
                if let output = usage["output_tokens"] as? Int { outputTokens = output }
                if usage["input_tokens"] != nil { inputTokens = Self.totalInput(usage) }
            }
        case "message_stop":
            isComplete = true
        case "error":
            let error = event["error"] as? [String: Any]
            let errorType = error?["type"] as? String
            streamError = .http(
                status: errorType == "overloaded_error" ? 529 : 500,
                type: errorType,
                message: error?["message"] as? String
            )
        default:
            break // ping, content_block_stop, ...
        }
    }

    /// The final text, or the reason there is none.
    public func finalText() throws -> String {
        if let streamError { throw streamError }
        switch stopReason {
        case "refusal": throw AIServiceError.refusal(category: refusalCategory)
        case "max_tokens": throw AIServiceError.truncated
        default: break
        }
        guard isComplete || stopReason != nil else {
            throw AIServiceError.network("the response ended early")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIServiceError.emptyResponse }
        return trimmed
    }

    private static func totalInput(_ usage: [String: Any]) -> Int? {
        let keys = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
        let values = keys.compactMap { usage[$0] as? Int }
        return values.isEmpty ? nil : values.reduce(0, +)
    }
}

/// Turns the model's JSON answer into `SessionInsights`.
/// Older name, kept for existing code.
public typealias ClaudeAPIError = AIServiceError

public enum InsightsResponseParser {
    private struct Raw: Decodable {
        struct Speaker: Decodable { var label: String; var description: String }
        struct Turn: Decodable { var paragraph: Int; var speaker: String }
        struct Note: Decodable { var photo: Int; var description: String }
        struct Section: Decodable { var paragraph: Int; var title: String }
        var title: String
        var summary: String
        var key_points: [String]
        var action_items: [String]
        var speakers: [Speaker]
        var speaker_turns: [Turn]
        var photo_notes: [Note]?
        var chapters: [Section]?
    }

    /// Claude answers.
    public static func parse(
        _ text: String,
        request: InsightsRequest,
        model: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        now: Date = Date()
    ) throws -> SessionInsights {
        try parse(text, prompt: request.prompt, model: model ?? request.model.rawValue,
                  inputTokens: inputTokens, outputTokens: outputTokens, now: now)
    }

    /// Any provider's answer: JSON matching `InsightsPrompt.schema` (code
    /// fences or text around the JSON object are tolerated).
    public static func parse(
        _ text: String,
        prompt: InsightsPrompt,
        model: String,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        now: Date = Date()
    ) throws -> SessionInsights {
        let raw: Raw
        do {
            raw = try JSONDecoder().decode(Raw.self, from: Data(jsonObjectText(text).utf8))
        } catch {
            throw AIServiceError.invalidOutput("unexpected format")
        }
        let request = prompt
        func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

        var turns: [SpeakerTurn] = []
        for turn in raw.speaker_turns.sorted(by: { $0.paragraph < $1.paragraph }) {
            let index = turn.paragraph - 1
            let speaker = clean(turn.speaker)
            guard request.paragraphStarts.indices.contains(index), !speaker.isEmpty else { continue }
            if turns.last?.speaker == speaker { continue }
            turns.append(SpeakerTurn(start: request.paragraphStarts[index], speaker: speaker))
        }

        var photoNotes: [PhotoNote] = []
        for note in raw.photo_notes ?? [] {
            let index = note.photo - 1
            let text = clean(note.description)
            guard request.photoIDs.indices.contains(index), !text.isEmpty else { continue }
            guard !photoNotes.contains(where: { $0.photoID == request.photoIDs[index] }) else { continue }
            photoNotes.append(PhotoNote(photoID: request.photoIDs[index], text: text))
        }

        var chapters: [Chapter] = []
        for section in (raw.chapters ?? []).sorted(by: { $0.paragraph < $1.paragraph }) {
            let index = section.paragraph - 1
            let title = clean(section.title)
            guard request.paragraphStarts.indices.contains(index), !title.isEmpty else { continue }
            guard !chapters.contains(where: { $0.start == request.paragraphStarts[index] }) else { continue }
            chapters.append(Chapter(start: request.paragraphStarts[index], title: title))
        }

        return SessionInsights(
            title: clean(raw.title),
            summary: clean(raw.summary),
            keyPoints: raw.key_points.map(clean).filter { !$0.isEmpty },
            actionItems: raw.action_items.map(clean).filter { !$0.isEmpty },
            speakers: raw.speakers
                .map { SpeakerProfile(label: clean($0.label), description: clean($0.description)) }
                .filter { !$0.label.isEmpty },
            speakerTurns: turns,
            model: model,
            generatedAt: now,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            photoNotes: photoNotes.isEmpty ? nil : photoNotes,
            chapters: chapters.isEmpty ? nil : chapters
        )
    }

    /// The outermost `{...}` in the text (drops ```json fences and chatter).
    static func jsonObjectText(_ text: String) -> String {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return text }
        return String(text[start...end])
    }
}
