import Foundation

/// Builds the Claude Messages API request that turns a transcript into
/// `SessionInsights`. The app sends it over HTTPS (there is no Swift SDK).
public struct InsightsRequest: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2026-10-21"
    /// Beta header for `fallbacks: "default"` (server-side refusal fallback).
    public static let fallbackBeta = "server-side-fallback-2026-07-01"

    public let model: ClaudeModel
    /// JSON request body.
    public let body: Data
    /// Start time of each numbered paragraph (index 0 = paragraph 1), to map
    /// the model's paragraph numbers back to times.
    public let paragraphStarts: [Date]
    /// The transcript as sent, for estimates and debugging.
    public let transcriptText: String

    /// HTTP headers for the request (the API key is added by the caller).
    public var headers: [String: String] {
        var headers = [
            "content-type": "application/json",
            "anthropic-version": Self.apiVersion,
        ]
        if model.supportsServerFallback { headers["anthropic-beta"] = Self.fallbackBeta }
        return headers
    }

    public var estimatedInputTokens: Int {
        TokenEstimate.tokens(for: transcriptText) + TokenEstimate.tokens(for: Self.systemPrompt) + 600
    }

    /// Upper-end cost estimate in USD, assuming up to ~8k output tokens
    /// (thinking included).
    public var estimatedMaxCost: Double {
        model.cost(inputTokens: estimatedInputTokens, outputTokens: 8_000)
    }

    public enum BuildError: Error, Equatable, LocalizedError {
        case emptyTranscript

        public var errorDescription: String? {
            "This recording has no transcribed speech yet."
        }
    }

    public init(
        session: TranscriptSession,
        model: ClaudeModel = .default,
        format: FormatOptions = .init(),
        timeZone: TimeZone = .current
    ) throws {
        let (text, starts) = Self.numberedTranscript(for: session, format: format, timeZone: timeZone)
        guard !starts.isEmpty else { throw BuildError.emptyTranscript }
        self.model = model
        self.paragraphStarts = starts
        self.transcriptText = text

        var json: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 64_000,
            "stream": true,
            "system": Self.systemPrompt,
            "messages": [
                ["role": "user", "content": Self.userPrompt(transcript: text, session: session, timeZone: timeZone)],
            ],
            "output_config": [
                "effort": "medium",
                "format": ["type": "json_schema", "schema": Self.schema],
            ],
        ]
        if model.supportsServerFallback { json["fallbacks"] = "default" }
        self.body = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    // MARK: - Transcript

    /// The transcript with numbered paragraphs:
    /// `[P3 14:05] text`, plus marker lines for speaker changes, photos and gaps.
    static func numberedTranscript(
        for session: TranscriptSession,
        format: FormatOptions,
        timeZone: TimeZone
    ) -> (String, [Date]) {
        let time = TimestampFormatter(timeZone: timeZone)
        var lines: [String] = []
        var starts: [Date] = []
        for block in TranscriptFormatter.blocks(for: session.items, options: format) {
            switch block {
            case .paragraph(let p):
                starts.append(p.start)
                lines.append("[P\(starts.count) \(time.clock(p.start))] \(p.text)")
            case .speakerChange(let change):
                lines.append(change.label.map { "— New speaker: \($0) —" } ?? "— New speaker —")
            case .photo(let photo):
                lines.append("[Photo taken \(time.clock(photo.takenAt))]")
            case .gap(let gap):
                let end = gap.end.map { "–\(time.clock($0))" } ?? ""
                lines.append("[No audio \(time.clock(gap.start))\(end)]")
            }
        }
        return (lines.joined(separator: "\n"), starts)
    }

    // MARK: - Prompts

    static let systemPrompt = """
    You turn transcripts of in-person conversations (meetings, talks, lectures, interviews) into a \
    short, useful write-up. The transcripts come from automatic speech recognition on an iPhone placed \
    in the room, so they contain recognition mistakes, missing punctuation, and no reliable speaker \
    labels. Infer the intended words from context, and don't invent facts that aren't supported by the \
    transcript.
    """

    static func userPrompt(transcript: String, session: TranscriptSession, timeZone: TimeZone) -> String {
        let time = TimestampFormatter(timeZone: timeZone)
        return """
        Recording from \(time.day(session.startedAt)), language setting: \
        \(TranscriptLanguage.displayName(for: session.localeIdentifier)).

        Each paragraph starts with [P<number> <time>]. A line "— New speaker —" means the person \
        recording tapped a button because someone else started talking (a strong hint, but they may \
        have missed changes). "[Photo taken ...]" marks a photo of a slide or whiteboard. \
        "[No audio ...]" marks a gap in the recording.

        <transcript>
        \(transcript)
        </transcript>

        Fill in every field:
        - title: specific and short (at most 8 words).
        - summary: what the conversation was about and what came out of it, in one to three short \
        paragraphs.
        - key_points: the most important points, decisions and facts, one sentence each.
        - action_items: tasks, follow-ups and deadlines, with who owns them when that's said. Empty if none.
        - speakers: the distinct people you can tell apart. Use a person's name when the transcript \
        states it (someone is introduced or addressed by name); otherwise a role such as "Presenter", \
        "Host" or "Audience member 1". description: a few words on their role.
        - speaker_turns: where each speaker starts talking: the paragraph number where their turn \
        begins and their label exactly as in speakers. Only list paragraphs where the speaker changes; \
        the first entry should be paragraph 1. If you can't tell people apart, give one speaker with \
        one turn at paragraph 1.

        Write the title, summary, key points and action items in the main language of the transcript \
        (if it mixes languages, the one used most).
        """
    }

    // MARK: - Output schema

    static var schema: [String: Any] {
        func stringArray() -> [String: Any] { ["type": "array", "items": ["type": "string"]] }
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["title", "summary", "key_points", "action_items", "speakers", "speaker_turns"],
            "properties": [
                "title": ["type": "string"],
                "summary": ["type": "string"],
                "key_points": stringArray(),
                "action_items": stringArray(),
                "speakers": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["label", "description"],
                        "properties": [
                            "label": ["type": "string"],
                            "description": ["type": "string"],
                        ],
                    ],
                ],
                "speaker_turns": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["paragraph", "speaker"],
                        "properties": [
                            "paragraph": ["type": "integer"],
                            "speaker": ["type": "string"],
                        ],
                    ],
                ],
            ],
        ]
    }
}
