import Foundation

public struct FormatOptions: Sendable, Equatable {
    /// A silence at least this long between two phrases starts a new paragraph.
    public var pauseThreshold: TimeInterval
    /// A paragraph that already spans this long is closed at the next phrase,
    /// so long monologues don't become one wall of text.
    public var maxParagraphDuration: TimeInterval

    public init(pauseThreshold: TimeInterval = 2.0, maxParagraphDuration: TimeInterval = 90) {
        self.pauseThreshold = pauseThreshold
        self.maxParagraphDuration = maxParagraphDuration
    }
}

public struct Paragraph: Equatable, Sendable, Identifiable {
    /// The id of the paragraph's first speech segment (stable across re-formatting).
    public var id: UUID
    public var start: Date
    public var end: Date
    public var text: String
    public var segmentIDs: [UUID]
}

/// The readable shape of a transcript: paragraphs interleaved with markers.
public enum TranscriptBlock: Equatable, Sendable, Identifiable {
    case paragraph(Paragraph)
    case speakerChange(SpeakerChange)
    case photo(PhotoAttachment)
    case gap(AudioGap)

    public var id: UUID {
        switch self {
        case .paragraph(let p): p.id
        case .speakerChange(let c): c.id
        case .photo(let p): p.id
        case .gap(let g): g.id
        }
    }

    public var time: Date {
        switch self {
        case .paragraph(let p): p.start
        case .speakerChange(let c): c.at
        case .photo(let p): p.takenAt
        case .gap(let g): g.start
        }
    }
}

public enum TranscriptFormatter {
    /// Groups speech segments into paragraphs. Paragraphs break on long pauses,
    /// on the length limit, and around every non-speech item.
    public static func blocks(for items: [TimelineItem], options: FormatOptions = .init()) -> [TranscriptBlock] {
        // Stable sort by time; `items` is normally already sorted.
        let ordered = items.enumerated()
            .sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time }
            .map(\.element)

        var blocks: [TranscriptBlock] = []
        var current: (paragraph: Paragraph, texts: [String])?

        func flush() {
            guard var open = current else { return }
            open.paragraph.text = TextJoiner.join(open.texts)
            if !open.paragraph.text.isEmpty { blocks.append(.paragraph(open.paragraph)) }
            current = nil
        }

        for item in ordered {
            switch item {
            case .speech(let segment):
                if let open = current {
                    let pause = segment.start.timeIntervalSince(open.paragraph.end)
                    let length = open.paragraph.end.timeIntervalSince(open.paragraph.start)
                    if pause >= options.pauseThreshold || length >= options.maxParagraphDuration {
                        flush()
                    }
                }
                if current == nil {
                    current = (
                        Paragraph(id: segment.id, start: segment.start, end: segment.end, text: "", segmentIDs: []),
                        []
                    )
                }
                current!.paragraph.end = max(current!.paragraph.end, segment.end)
                current!.paragraph.segmentIDs.append(segment.id)
                current!.texts.append(segment.text)
            case .speakerChange(let change):
                flush()
                blocks.append(.speakerChange(change))
            case .photo(let photo):
                flush()
                blocks.append(.photo(photo))
            case .gap(let gap):
                flush()
                blocks.append(.gap(gap))
            }
        }
        flush()
        return blocks
    }
}
