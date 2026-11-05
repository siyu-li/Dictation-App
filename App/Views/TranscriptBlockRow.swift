import SwiftUI
import TranscriptCore

/// One block of a formatted transcript: a paragraph, a speaker marker, a
/// photo, or a gap in the audio. Used by the live view and the detail view.
struct TranscriptBlockRow: View {
    let block: TranscriptBlock
    let session: TranscriptSession
    let style: TimestampStyle
    let photoURL: (PhotoAttachment) -> URL
    var onPhotoTap: ((PhotoAttachment) -> Void)?

    var body: some View {
        switch block {
        case .paragraph(let paragraph):
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(timestampLabel(paragraph.start, in: session, style: style))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let speaker = guessedSpeaker(for: paragraph) {
                        Text(speaker)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
                Text(paragraph.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)

        case .speakerChange(let change):
            HStack(spacing: 8) {
                line
                Label(change.label ?? "New speaker", systemImage: "person.wave.2.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                    .fixedSize()
                line
            }
            .padding(.top, 6)
            .accessibilityElement(children: .combine)

        case .photo(let photo):
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    onPhotoTap?(photo)
                } label: {
                    PhotoThumbnail(url: photoURL(photo))
                        .frame(maxWidth: .infinity, maxHeight: 260)
                }
                .buttonStyle(.plain)
                .disabled(onPhotoTap == nil)
                .accessibilityLabel("Photo taken at \(TimestampFormatter().clock(photo.takenAt))")
                .accessibilityHint(Text(verbatim: onPhotoTap == nil ? "" : "Opens the photo"))

                Label(
                    timestampLabel(photo.takenAt, in: session, style: style)
                        + (photo.source == .photoLibrary ? " · from Photos" : ""),
                    systemImage: "camera"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

                if let note = session.insights?.note(forPhoto: photo.id) {
                    Text(note)
                        .font(.subheadline)
                        .textSelection(.enabled)
                }

                if let slideText = photo.recognizedText, !slideText.isEmpty {
                    DisclosureGroup {
                        Text(slideText)
                            .font(.footnote)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    } label: {
                        Label("Slide text", systemImage: "text.viewfinder")
                            .font(.footnote)
                    }
                }
            }

        case .bookmark(let bookmark):
            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                    .foregroundStyle(.orange)
                Text("Bookmark")
                    .font(.subheadline.weight(.semibold))
                if let note = bookmark.note {
                    Text(note)
                        .font(.subheadline)
                }
                Spacer(minLength: 0)
                Text(timestampLabel(bookmark.at, in: session, style: style))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .combine)

        case .gap(let gap):
            Label(gapDescription(gap), systemImage: "mic.slash")
                .font(.footnote)
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// The AI-guessed speaker whose turn starts within this paragraph, if any.
    private func guessedSpeaker(for paragraph: Paragraph) -> String? {
        session.insights?.speakerTurns.last { $0.start >= paragraph.start && $0.start <= paragraph.end }?.speaker
    }

    private var line: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(height: 1)
    }

    private func gapDescription(_ gap: AudioGap) -> String {
        let time = TimestampFormatter()
        let start = time.clock(gap.start, includeSeconds: true)
        guard let end = gap.end else { return "No audio from \(start) · \(gap.reason)" }
        let length = TimestampFormatter.duration(end.timeIntervalSince(gap.start))
        return "No audio \(start)–\(time.clock(end, includeSeconds: true)) (\(length)) · \(gap.reason)"
    }
}

/// All blocks of a transcript as rows. Equatable on what affects the
/// formatting, so long transcripts are only re-formatted when they change.
struct TranscriptBlocksList: View, Equatable {
    let session: TranscriptSession
    let options: FormatOptions
    let style: TimestampStyle
    let photoURL: (PhotoAttachment) -> URL
    var onPhotoTap: ((PhotoAttachment) -> Void)?

    static func == (lhs: TranscriptBlocksList, rhs: TranscriptBlocksList) -> Bool {
        lhs.session.id == rhs.session.id
            && lhs.session.items.count == rhs.session.items.count
            && lhs.session.items.last == rhs.session.items.last
            && lhs.session.insights == rhs.session.insights
            && lhs.options == rhs.options
            && lhs.style == rhs.style
            && (lhs.onPhotoTap == nil) == (rhs.onPhotoTap == nil)
            && recognizedPhotoCount(lhs.session) == recognizedPhotoCount(rhs.session)
    }

    /// Slide text arrives after a photo was added, without changing the item count.
    private static func recognizedPhotoCount(_ session: TranscriptSession) -> Int {
        var count = 0
        for item in session.items {
            if case .photo(let photo) = item, photo.recognizedText != nil { count += 1 }
        }
        return count
    }

    /// Scroll target of the chapter heading with this index (chapters sorted by start).
    static func chapterAnchor(_ index: Int) -> String {
        "chapter-\(index)"
    }

    private enum RowKind {
        case chapter(Chapter)
        case block(TranscriptBlock)
    }

    private struct Row: Identifiable {
        let id: String
        let kind: RowKind
    }

    /// Blocks with a chapter heading before the first paragraph at or after
    /// each chapter's start.
    private static func rows(blocks: [TranscriptBlock], chapters: [Chapter]) -> [Row] {
        let sorted = chapters.sorted { $0.start < $1.start }
        var next = 0
        var rows: [Row] = []
        rows.reserveCapacity(blocks.count + sorted.count)
        for block in blocks {
            if case .paragraph(let paragraph) = block {
                while next < sorted.count, sorted[next].start <= paragraph.start {
                    rows.append(Row(id: chapterAnchor(next), kind: .chapter(sorted[next])))
                    next += 1
                }
            }
            rows.append(Row(id: block.id.uuidString, kind: .block(block)))
        }
        return rows
    }

    var body: some View {
        let blocks = TranscriptFormatter.blocks(for: session.items, options: options)
        ForEach(Self.rows(blocks: blocks, chapters: session.insights?.chapters ?? [])) { row in
            switch row.kind {
            case .chapter(let chapter):
                ChapterHeading(title: chapter.title)
            case .block(let block):
                TranscriptBlockRow(
                    block: block,
                    session: session,
                    style: style,
                    photoURL: photoURL,
                    onPhotoTap: onPhotoTap
                )
            }
        }
    }
}

/// A chapter title inside the transcript.
private struct ChapterHeading: View {
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor)
                .frame(width: 4, height: 22)
            Text(title)
                .font(.title3.weight(.semibold))
        }
        .padding(.top, 10)
        .accessibilityAddTraits(.isHeader)
    }
}
