import Foundation

/// Which AI service writes the summary. ChatGPT is the default.
public enum AIProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case chatGPT
    case claude
    case gemini
    case qwen

    public static let `default` = AIProvider.chatGPT

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .chatGPT: "ChatGPT (OpenAI)"
        case .claude: "Claude (Anthropic)"
        case .gemini: "Gemini (Google)"
        case .qwen: "Qwen (open-source, via OpenRouter)"
        }
    }

    public var shortName: String {
        switch self {
        case .chatGPT: "ChatGPT"
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .qwen: "Qwen"
        }
    }

    /// Model used unless the user enters another one in Settings.
    public var defaultModel: String {
        switch self {
        case .chatGPT: "gpt-6.1-sol"
        case .claude: ClaudeModel.default.rawValue
        case .gemini: "gemini-3.8-flash"
        case .qwen: "qwen/qwen3.5-397b-a17b"
        }
    }

    /// OpenAI-compatible chat completions endpoint (nil for Claude, which
    /// uses Anthropic's own Messages API).
    public var chatCompletionsURL: URL? {
        switch self {
        case .chatGPT: URL(string: "https://api.openai.com/v1/chat/completions")
        case .gemini: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        case .qwen: URL(string: "https://openrouter.ai/api/v1/chat/completions")
        case .claude: nil
        }
    }

    public var keyPlaceholder: String {
        switch self {
        case .chatGPT: "OpenAI API key (sk-…)"
        case .claude: "Claude API key (sk-ant-…)"
        case .gemini: "Gemini API key"
        case .qwen: "OpenRouter API key (sk-or-…)"
        }
    }

    /// Where to create a key.
    public var keyWebsite: String {
        switch self {
        case .chatGPT: "platform.openai.com/api-keys"
        case .claude: "platform.claude.com"
        case .gemini: "aistudio.google.com/apikey"
        case .qwen: "openrouter.ai/keys"
        }
    }
}

/// Claude models offered in Settings, with list prices (USD per million tokens).
public enum ClaudeModel: String, CaseIterable, Codable, Sendable, Identifiable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"

    public static let `default` = ClaudeModel.opus

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .opus: "Claude Opus 5.5 (best)"
        case .sonnet: "Claude Sonnet 5.5 (cheaper)"
        case .haiku: "Claude Haiku 5.5 (cheapest)"
        }
    }

    public var inputPricePerMillion: Double {
        switch self {
        case .opus: 4.00
        case .sonnet: 2.00
        case .haiku: 0.10
        }
    }

    public var outputPricePerMillion: Double {
        switch self {
        case .opus: 20.00
        case .sonnet: 10.00
        case .haiku: 0.50
        }
    }

    /// Server-side refusal fallback is available on Opus and Sonnet, not Haiku.
    public var supportsServerFallback: Bool { self != .haiku }

    public func cost(inputTokens: Int, outputTokens: Int) -> Double {
        Double(inputTokens) / 1_000_000 * inputPricePerMillion
            + Double(outputTokens) / 1_000_000 * outputPricePerMillion
    }
}

/// List prices (USD per million tokens) by model id, for showing what a
/// request cost. Unknown models show no cost.
public enum ModelPricing {
    public static func rates(forModelID id: String) -> (input: Double, output: Double)? {
        if let model = ClaudeModel(rawValue: id) {
            return (model.inputPricePerMillion, model.outputPricePerMillion)
        }
        switch id {
        // Claude models the server-side fallback may answer with.
        case "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6": return (5, 25)
        case "claude-sonnet-5": return (2, 10)
        case "claude-sonnet-4-6": return (3, 15)
        // OpenAI (developers.openai.com/api/docs/models, Nov 2026).
        case "gpt-6.1-sol": return (2, 10)
        case "gpt-6-astra": return (10, 50)
        case "gpt-6-luna": return (0.10, 0.50)
        // OpenRouter (openrouter.ai/api/v1/models, Nov 2026).
        case "qwen/qwen3.5-397b-a17b": return (0.50, 3.60)
        default: return nil
        }
    }

    public static func cost(modelID: String, inputTokens: Int, outputTokens: Int) -> Double? {
        guard let rates = rates(forModelID: modelID) else { return nil }
        return Double(inputTokens) / 1_000_000 * rates.input + Double(outputTokens) / 1_000_000 * rates.output
    }
}

public enum TokenEstimate {
    /// Rough token count: ~3.5 characters per token for Latin text (newer
    /// tokenizers use more tokens than the classic 4), ~1.2 tokens per CJK
    /// character.
    public static func tokens(for text: String) -> Int {
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if TextJoiner.isCJK(scalar) { cjk += 1 } else { other += 1 }
        }
        return (cjk * 6) / 5 + (other * 2) / 7
    }
}
