import Foundation

/// Claude models offered in Settings, with list prices (USD per million tokens)
/// used for the cost estimate shown before generating.
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

/// List prices (USD per million tokens) by model id, including models the
/// server-side fallback may answer with, for showing what a request cost.
public enum ClaudePricing {
    public static func rates(forModelID id: String) -> (input: Double, output: Double)? {
        if let model = ClaudeModel(rawValue: id) {
            return (model.inputPricePerMillion, model.outputPricePerMillion)
        }
        switch id {
        case "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6": return (5, 25)
        case "claude-sonnet-5": return (2, 10)
        case "claude-sonnet-4-6": return (3, 15)
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
