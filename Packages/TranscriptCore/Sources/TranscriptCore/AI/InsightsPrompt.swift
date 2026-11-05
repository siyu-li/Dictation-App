import Foundation

/// Language for the AI-written title, summary, key points and chapters.
public enum SummaryLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case automatic
    case english
    case chinese
    case bilingual

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: "Same as the recording"
        case .english: "English"
        case .chinese: "中文"
        case .bilingual: "English + 中文"
        }
    }

    var instruction: String {
        switch self {
        case .automatic:
            "Write the title, summary, key points, action items, chapter titles and photo notes in the main language of the transcript (if it mixes languages, the one used most)."
        case .english:
            "Write the title, summary, key points, action items, chapter titles and photo notes in English, even if the recording is in another language."
        case .chinese:
            "Write the title, summary, key points, action items, chapter titles and photo notes in Simplified Chinese (简体中文), even if the recording is in another language."
        case .bilingual:
            "Write the title, summary, key points, action items, chapter titles and photo notes in both English and Simplified Chinese (简体中文): the title as \"English title / 中文标题\", the summary as the English paragraphs followed by the Chinese paragraphs, and every list item, chapter title and photo note as \"English — 中文\"."
        }
    }
}

/// A session photo prepared for sending to the AI (already downscaled and
/// JPEG-encoded by the app).
public struct InsightsPhoto: Sendable, Equatable {
    public var id: UUID
    public var takenAt: Date
    public var jpegData: Data
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(id: UUID, takenAt: Date, jpegData: Data, pixelWidth: Int, pixelHeight: Int) {
        self.id = id
        self.takenAt = takenAt
        self.jpegData = jpegData
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// Image tokens, counted in 28×28-pixel patches (Claude's rule; other
    /// providers are in the same range).
    public var visualTokens: Int {
        let columns = (max(1, pixelWidth) + 27) / 28
        let rows = (max(1, pixelHeight) + 27) / 28
        return min(columns * rows, 4_784)
    }
}

/// The provider-neutral request: a numbered transcript with markers, the
/// attached photos, the instructions and the JSON output schema. Each
/// provider's request type turns this into its own wire format.
public struct InsightsPrompt: Sendable {
    /// Longest edge the app downscales photos to before sending: slide text
    /// stays legible at a moderate token cost.
    public static let recommendedPhotoMaxPixels = 1_568
    /// At most this many photos are sent (evenly spread if there are more).
    public static let maxPhotos = 40
    /// Slide text recognized on the phone is shortened to this in the transcript.
    public static let maxSlideTextCharacters = 400

    public enum BuildError: Error, Equatable, LocalizedError {
        case emptyTranscript

        public var errorDescription: String? {
            "This recording has no transcribed speech yet."
        }
    }

    public let systemText: String
    /// Instructions with the transcript; sent after the photos.
    public let userText: String
    /// Attached photos in order (index 0 = "Photo 1").
    public let photos: [InsightsPhoto]
    /// The label sent before each photo, e.g. `Photo 1 (taken 14:10):`.
    public let photoLabels: [String]
    /// Start time of each numbered paragraph (index 0 = paragraph 1).
    public let paragraphStarts: [Date]
    /// The numbered transcript as sent.
    public let transcriptText: String

    public var photoIDs: [UUID] { photos.map(\.id) }
    public var photoTokens: Int { photos.reduce(0) { $0 + $1.visualTokens } }

    public var estimatedInputTokens: Int {
        TokenEstimate.tokens(for: userText) + TokenEstimate.tokens(for: systemText) + 300 + photoTokens
    }

    /// - Parameter photos: session photos to attach (prepared by the app);
    ///   photos not in the session are ignored, and at most `maxPhotos` are
    ///   sent, spread evenly over the session.
    public init(
        session: TranscriptSession,
        format: FormatOptions = .init(),
        timeZone: TimeZone = .current,
        photos: [InsightsPhoto] = [],
        language: SummaryLanguage = .automatic
    ) throws {
        let sessionPhotoIDs = Set(session.photos.map(\.id))
        let attached = Self.spread(
            photos.filter { sessionPhotoIDs.contains($0.id) }.sorted { $0.takenAt < $1.takenAt },
            limit: Self.maxPhotos
        )
        var photoNumbers: [UUID: Int] = [:]
        for (index, photo) in attached.enumerated() { photoNumbers[photo.id] = index + 1 }

        let (text, starts) = Self.numberedTranscript(for: session, format: format, timeZone: timeZone, photoNumbers: photoNumbers)
        guard !starts.isEmpty else { throw BuildError.emptyTranscript }

        let time = TimestampFormatter(timeZone: timeZone)
        self.photos = attached
        self.photoLabels = attached.enumerated().map { "Photo \($0.offset + 1) (taken \(time.clock($0.element.takenAt))):" }
        self.paragraphStarts = starts
        self.transcriptText = text
        self.systemText = Self.systemPrompt
        self.userText = Self.userPrompt(
            transcript: text,
            session: session,
            timeZone: timeZone,
            photoCount: attached.count,
            hasBookmarks: !session.bookmarks.isEmpty,
            hasSlideText: session.photos.contains { !($0.recognizedText ?? "").isEmpty },
            language: language
        )
    }

    /// Picks at most `limit` items spread evenly (keeps first and last).
    public static func spread<T>(_ items: [T], limit: Int) -> [T] {
        guard items.count > limit, limit > 0 else { return items }
        if limit == 1 { return [items[0]] }
        return (0..<limit).map { items[$0 * (items.count - 1) / (limit - 1)] }
    }

    // MARK: - Transcript

    /// The transcript with numbered paragraphs (`[P3 14:05] text`) and
    /// marker lines for speaker changes, photos, bookmarks and gaps.
    static func numberedTranscript(
        for session: TranscriptSession,
        format: FormatOptions,
        timeZone: TimeZone,
        photoNumbers: [UUID: Int] = [:]
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
                let name = photoNumbers[photo.id].map { "Photo \($0)" } ?? "Photo"
                var line = "[\(name) taken \(time.clock(photo.takenAt))"
                if let slideText = slideText(photo.recognizedText) {
                    line += ". Slide text: \"\(slideText)\""
                }
                lines.append(line + "]")
            case .gap(let gap):
                let end = gap.end.map { "–\(time.clock($0))" } ?? ""
                lines.append("[No audio \(time.clock(gap.start))\(end)]")
            case .bookmark(let bookmark):
                let note = bookmark.note.map { ": \($0)" } ?? ""
                lines.append("[★ Bookmarked at \(time.clock(bookmark.at))\(note)]")
            }
        }
        return (lines.joined(separator: "\n"), starts)
    }

    /// Slide text on one line, shortened.
    private static func slideText(_ text: String?) -> String? {
        guard let text else { return nil }
        let oneLine = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: "\"", with: "'")
        guard !oneLine.isEmpty else { return nil }
        return oneLine.count > maxSlideTextCharacters ? String(oneLine.prefix(maxSlideTextCharacters)) + "…" : oneLine
    }

    // MARK: - Instructions

    static let systemPrompt = """
    You turn transcripts of in-person conversations (meetings, talks, lectures, interviews) into a \
    short, useful write-up. The transcripts come from automatic speech recognition on an iPhone placed \
    in the room, so they contain recognition mistakes, missing punctuation, and no reliable speaker \
    labels. Infer the intended words from context, and don't invent facts that aren't supported by the \
    transcript.
    """

    static func userPrompt(
        transcript: String,
        session: TranscriptSession,
        timeZone: TimeZone,
        photoCount: Int = 0,
        hasBookmarks: Bool = false,
        hasSlideText: Bool = false,
        language: SummaryLanguage = .automatic
    ) -> String {
        let time = TimestampFormatter(timeZone: timeZone)
        var guides: [String] = []
        if photoCount > 0 {
            guides.append("""
            The \(photoCount) photo(s) above were taken during the recording, mostly of slides or a \
            whiteboard. "[Photo N taken ...]" in the transcript marks when Photo N was taken. Use what \
            the photos show (titles, numbers, diagrams, terms) in the summary, key points and action \
            items, and use them to correct words the speech recognition got wrong.
            """)
        }
        if hasSlideText {
            guides.append("""
            "Slide text" after a photo marker is text read from that photo on the phone; it may contain \
            recognition errors.
            """)
        }
        if hasBookmarks {
            guides.append("""
            "[★ Bookmarked ...]" marks a moment the listener flagged as important. Make sure the summary \
            and key points cover what was said around each bookmark.
            """)
        }
        let guideText = guides.isEmpty ? "" : "\n\n" + guides.joined(separator: "\n\n")
        return """
        Recording from \(time.day(session.startedAt)), language setting: \
        \(TranscriptLanguage.displayName(for: session.localeIdentifier)).

        Each paragraph starts with [P<number> <time>]. A line "— New speaker —" means the person \
        recording tapped a button because someone else started talking (a strong hint, but they may \
        have missed changes). "[No audio ...]" marks a gap in the recording.\(guideText)

        <transcript>
        \(transcript)
        </transcript>

        Fill in every field:
        - title: specific and short (at most 8 words).
        - summary: what the conversation was about and what came out of it, in one to three short \
        paragraphs.
        - key_points: the most important points, decisions and facts, one sentence each.
        - action_items: tasks, follow-ups and deadlines, with who owns them when that's said. Empty if none.
        - chapters: split the recording into sections by topic (1 for a short recording, up to 12 for a \
        long one): for each, the paragraph number where it starts and a short title. The first chapter \
        starts at paragraph 1.
        - speakers: the distinct people you can tell apart. Use a person's name when the transcript \
        states it (someone is introduced or addressed by name); otherwise a role such as "Presenter", \
        "Host" or "Audience member 1". description: a few words on their role.
        - speaker_turns: where each speaker starts talking: the paragraph number where their turn \
        begins and their label exactly as in speakers. Only list paragraphs where the speaker changes; \
        the first entry should be paragraph 1. If you can't tell people apart, give one speaker with \
        one turn at paragraph 1.
        - photo_notes: for each attached photo, its number and one short line saying what it shows \
        (e.g. the slide title and its main point). Empty if no photos are attached.

        \(language.instruction)
        """
    }

    // MARK: - Output schema

    /// JSON schema of the answer (also valid for OpenAI-style strict
    /// structured outputs: every object lists all its properties as required
    /// and allows no others).
    public static var schema: [String: Any] {
        func stringArray() -> [String: Any] { ["type": "array", "items": ["type": "string"]] }
        func objectArray(_ properties: [String: [String: Any]]) -> [String: Any] {
            [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": properties.keys.sorted(),
                    "properties": properties,
                ],
            ]
        }
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["title", "summary", "key_points", "action_items", "chapters", "speakers", "speaker_turns", "photo_notes"],
            "properties": [
                "title": ["type": "string"],
                "summary": ["type": "string"],
                "key_points": stringArray(),
                "action_items": stringArray(),
                "chapters": objectArray(["paragraph": ["type": "integer"], "title": ["type": "string"]]),
                "speakers": objectArray(["label": ["type": "string"], "description": ["type": "string"]]),
                "speaker_turns": objectArray(["paragraph": ["type": "integer"], "speaker": ["type": "string"]]),
                "photo_notes": objectArray(["photo": ["type": "integer"], "description": ["type": "string"]]),
            ],
        ]
    }
}
