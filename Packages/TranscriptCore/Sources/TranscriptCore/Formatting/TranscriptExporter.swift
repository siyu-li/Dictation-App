import Foundation

public struct ExportOptions: Sendable, Equatable {
    public var timestampStyle: TimestampStyle
    public var includeTimestamps: Bool
    public var clockIncludesSeconds: Bool
    public var includeHeader: Bool
    public var timeZone: TimeZone
    public var format: FormatOptions

    public init(
        timestampStyle: TimestampStyle = .clock,
        includeTimestamps: Bool = true,
        clockIncludesSeconds: Bool = false,
        includeHeader: Bool = true,
        timeZone: TimeZone = .current,
        format: FormatOptions = .init()
    ) {
        self.timestampStyle = timestampStyle
        self.includeTimestamps = includeTimestamps
        self.clockIncludesSeconds = clockIncludesSeconds
        self.includeHeader = includeHeader
        self.timeZone = timeZone
        self.format = format
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
        let blocks = TranscriptFormatter.blocks(for: session.items, options: options.format)
        for (index, block) in blocks.enumerated() {
            switch block {
            case .paragraph(let p):
                out.append(stamp(p.start, session: session, options: options) + p.text)
            case .speakerChange(let change):
                out.append("— \(change.label ?? "New speaker") —")
            case .photo(let photo):
                out.append(stamp(photo.takenAt, session: session, options: options) + "📷 Photo")
            case .gap(let gap):
                out.append(stamp(gap.start, session: session, options: options) + gapText(gap, options: options))
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
        let time = TimestampFormatter(timeZone: options.timeZone)
        for block in TranscriptFormatter.blocks(for: session.items, options: options.format) {
            switch block {
            case .paragraph(let p):
                let label = label(p.start, session: session, options: options)
                out.append(label.map { "**\($0)** " + p.text } ?? p.text)
            case .speakerChange(let change):
                out.append("**— \(change.label ?? "New speaker") —**")
            case .photo(let photo):
                out.append("![Photo at \(time.clock(photo.takenAt, includeSeconds: true))](\(photoPath(photo)))")
            case .gap(let gap):
                out.append("> " + gapText(gap, options: options))
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Helpers

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
