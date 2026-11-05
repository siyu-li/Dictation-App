import Foundation

public struct ExportOptions: Sendable, Equatable {
    public var timestampStyle: TimestampStyle
    public var includeTimestamps: Bool
    public var clockIncludesSeconds: Bool
    public var includeHeader: Bool
    public var timeZone: TimeZone
    public var format: FormatOptions
    /// Include the AI summary and guessed speaker names when the session has them.
    public var includeInsights: Bool

    public init(
        timestampStyle: TimestampStyle = .clock,
        includeTimestamps: Bool = true,
        clockIncludesSeconds: Bool = false,
        includeHeader: Bool = true,
        timeZone: TimeZone = .current,
        format: FormatOptions = .init(),
        includeInsights: Bool = true
    ) {
        self.timestampStyle = timestampStyle
        self.includeTimestamps = includeTimestamps
        self.clockIncludesSeconds = clockIncludesSeconds
        self.includeHeader = includeHeader
        self.timeZone = timeZone
        self.format = format
        self.includeInsights = includeInsights
    }
}

/// Turns a session into shareable text.
public enum TranscriptExporter {
    public static let defaultTitle = "Transcript"

    /// Title line used when the session has no title yet.
    public static func displayTitle(for session: TranscriptSession) -> String {
        if let title = session.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return defaultTitle
    }

    /// `Wed 4 Nov 2026 · 14:02–15:47 · 1 h 45 min · English (US)`
    public static func subtitle(for session: TranscriptSession, options: ExportOptions = .init(), now: Date = Date()) -> String {
        let time = TimestampFormatter(timeZone: options.timeZone)
        let end = session.endedAt.map { time.clock($0) } ?? "now"
        return [
            time.day(session.startedAt),
            "\(time.clock(session.startedAt))–\(end)",
            TimestampFormatter.duration(session.duration(now: now)),
            TranscriptLanguage.displayName(for: session.localeIdentifier),
        ].joined(separator: " · ")
    }

    /// Plain text, suited for Apple Notes and messages.
    public static func plainText(for session: TranscriptSession, options: ExportOptions = .init(), now: Date = Date()) -> String {
        var out: [String] = []
        if options.includeHeader {
            out.append(displayTitle(for: session))
            out.append(subtitle(for: session, options: options, now: now))
            if session.wasRecovered {
                out.append("(Recording ended unexpectedly; saved up to the last autosave.)")
            }
            out.append("")
        }
        let insights = options.includeInsights ? session.insights : nil
        if let insights {
            out.append("Summary")
            out.append(insights.summary)
            out.append("")
            for (title, items) in [("Key points", insights.keyPoints), ("Action items", insights.actionItems)] where !items.isEmpty {
                out.append(title)
                out.append(contentsOf: items.map { "• \($0)" })
                out.append("")
            }
            out.append("Transcript")
            out.append("")
        }
        var lastSpeaker: String?
        var chapters = ChapterCursor(insights?.chapters ?? [])
        let blocks = TranscriptFormatter.blocks(for: session.items, options: options.format)
        for (index, block) in blocks.enumerated() {
            for chapter in chapters.starting(before: block) {
                out.append("■ \(chapter.title)")
                out.append("")
            }
            switch block {
            case .paragraph(let p):
                let speaker = speakerPrefix(for: p, insights: insights, lastSpeaker: &lastSpeaker)
                out.append(stamp(p.start, session: session, options: options) + speaker + p.text)
            case .speakerChange(let change):
                out.append("— \(change.label ?? "New speaker") —")
            case .photo(let photo):
                let note = insights?.note(forPhoto: photo.id).map { " — \($0)" } ?? ""
                out.append(stamp(photo.takenAt, session: session, options: options) + "📷 Photo" + note)
            case .gap(let gap):
                out.append(stamp(gap.start, session: session, options: options) + gapText(gap, options: options))
            case .bookmark(let bookmark):
                out.append(stamp(bookmark.at, session: session, options: options) + "★ Bookmark" + (bookmark.note.map { ": \($0)" } ?? ""))
            }
            // Keep a speaker marker attached to the paragraph that follows it.
            let isLast = index == blocks.count - 1
            if case .speakerChange = block, !isLast { continue }
            if !isLast { out.append("") }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Markdown. `photoPath` maps a photo to the path written in the image link.
    public static func markdown(
        for session: TranscriptSession,
        options: ExportOptions = .init(),
        now: Date = Date(),
        photoPath: (PhotoAttachment) -> String = { "photos/\($0.fileName)" }
    ) -> String {
        var out: [String] = []
        if options.includeHeader {
            out.append("# \(displayTitle(for: session))")
            out.append("")
            out.append("*\(subtitle(for: session, options: options, now: now))*")
            if session.wasRecovered {
                out.append("")
                out.append("> Recording ended unexpectedly; saved up to the last autosave.")
            }
            out.append("")
        }
        let insights = options.includeInsights ? session.insights : nil
        if let insights {
            out.append("## Summary")
            out.append("")
            out.append(insights.summary)
            out.append("")
            if !insights.keyPoints.isEmpty {
                out.append("**Key points**")
                out.append("")
                out.append(contentsOf: insights.keyPoints.map { "- \($0)" })
                out.append("")
            }
            if !insights.actionItems.isEmpty {
                out.append("**Action items**")
                out.append("")
                out.append(contentsOf: insights.actionItems.map { "- [ ] \($0)" })
                out.append("")
            }
            out.append("## Transcript")
            out.append("")
        }
        var lastSpeaker: String?
        var chapters = ChapterCursor(insights?.chapters ?? [])
        let time = TimestampFormatter(timeZone: options.timeZone)
        for block in TranscriptFormatter.blocks(for: session.items, options: options.format) {
            for chapter in chapters.starting(before: block) {
                out.append("### \(chapter.title)")
                out.append("")
            }
            switch block {
            case .paragraph(let p):
                let label = label(p.start, session: session, options: options)
                let speaker = speakerPrefix(for: p, insights: insights, lastSpeaker: &lastSpeaker)
                let text = speaker.isEmpty ? p.text : "*\(speaker.dropLast(2))*: " + p.text
                out.append(label.map { "**\($0)** " + text } ?? text)
            case .speakerChange(let change):
                out.append("**— \(change.label ?? "New speaker") —**")
            case .photo(let photo):
                out.append("![Photo at \(time.clock(photo.takenAt, includeSeconds: true))](\(photoPath(photo)))")
                if let note = insights?.note(forPhoto: photo.id) {
                    out.append("")
                    out.append("*\(note)*")
                }
            case .gap(let gap):
                out.append("> " + gapText(gap, options: options))
            case .bookmark(let bookmark):
                out.append("**★ Bookmark \(time.clock(bookmark.at, includeSeconds: true))**" + (bookmark.note.map { " — \($0)" } ?? ""))
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// `"Dana: "` when the guessed speaker changes at this paragraph, else `""`.
    private static func speakerPrefix(for paragraph: Paragraph, insights: SessionInsights?, lastSpeaker: inout String?) -> String {
        guard let speaker = insights?.speaker(at: paragraph.start) else { return "" }
        defer { lastSpeaker = speaker }
        return speaker == lastSpeaker ? "" : "\(speaker): "
    }

    private static func label(_ date: Date, session: TranscriptSession, options: ExportOptions) -> String? {
        guard options.includeTimestamps else { return nil }
        switch options.timestampStyle {
        case .clock:
            return TimestampFormatter(timeZone: options.timeZone).clock(date, includeSeconds: options.clockIncludesSeconds)
        case .elapsed:
            return TimestampFormatter.elapsed(date.timeIntervalSince(session.startedAt))
        }
    }

    private static func stamp(_ date: Date, session: TranscriptSession, options: ExportOptions) -> String {
        label(date, session: session, options: options).map { "[\($0)] " } ?? ""
    }

    private static func gapText(_ gap: AudioGap, options: ExportOptions) -> String {
        let time = TimestampFormatter(timeZone: options.timeZone)
        let range = gap.end.map { "\(time.clock(gap.start, includeSeconds: true))–\(time.clock($0, includeSeconds: true))" }
            ?? "from \(time.clock(gap.start, includeSeconds: true))"
        return "⚠︎ No audio \(range) (\(gap.reason))"
    }
}

/// Hands out chapter headings in order as the transcript is written.
private struct ChapterCursor {
    private var remaining: ArraySlice<Chapter>

    init(_ chapters: [Chapter]) {
        remaining = ArraySlice(chapters.sorted { $0.start < $1.start })
    }

    /// Chapters that start at or before this paragraph (headings go only
    /// before paragraphs, so markers don't end up under the wrong heading).
    mutating func starting(before block: TranscriptBlock) -> [Chapter] {
        guard case .paragraph(let paragraph) = block else { return [] }
        var due: [Chapter] = []
        while let next = remaining.first, next.start <= paragraph.start {
            due.append(next)
            remaining = remaining.dropFirst()
        }
        // Several chapters due at once: only the latest heading is useful.
        return due.last.map { [$0] } ?? []
    }
}
