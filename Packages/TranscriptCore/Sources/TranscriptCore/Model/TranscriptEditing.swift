import Foundation

/// Editing a recorded transcript: paragraph text, bookmarks and speaker
/// markers. All edits work on the session value; the app saves the result.
extension TranscriptSession {
    /// How far before a moment "add here" places a marker, so it sorts in
    /// front of the paragraph that starts at that moment.
    static let markerLead: TimeInterval = 0.001

    /// Replaces a paragraph's speech segments with one segment holding
    /// `text` (same start and end, same id as the paragraph's first segment,
    /// so the paragraph keeps its identity). Empty text deletes the paragraph.
    /// Returns false if none of the segments exist.
    @discardableResult
    public mutating func replaceParagraph(segmentIDs: [UUID], with text: String) -> Bool {
        let ids = Set(segmentIDs)
        let segments = speechSegments.filter { ids.contains($0.id) }
        guard let firstID = segmentIDs.first(where: { id in segments.contains { $0.id == id } }),
              let start = segments.map(\.start).min(),
              let end = segments.map(\.end).max() else { return false }
        items.removeAll { ids.contains($0.id) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            insert(.speech(SpeechSegment(id: firstID, text: trimmed, start: start, end: end)))
        }
        return true
    }

    /// Removes a bookmark, speaker marker or any other item by id.
    @discardableResult
    public mutating func removeItem(id: UUID) -> Bool {
        let before = items.count
        items.removeAll { $0.id == id }
        return items.count != before
    }

    /// Sets a bookmark's note (empty removes the note).
    @discardableResult
    public mutating func setBookmarkNote(_ note: String?, id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }),
              case .bookmark(var bookmark) = items[index] else { return false }
        bookmark.note = Self.cleaned(note)
        items[index] = .bookmark(bookmark)
        return true
    }

    /// Sets a speaker marker's name (empty shows "New speaker").
    @discardableResult
    public mutating func setSpeakerLabel(_ label: String?, id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }),
              case .speakerChange(var change) = items[index] else { return false }
        change.label = Self.cleaned(label)
        items[index] = .speakerChange(change)
        return true
    }

    /// Adds a bookmark just before `date` (e.g. a paragraph's start), so it
    /// appears above that paragraph.
    @discardableResult
    public mutating func addBookmark(before date: Date, note: String? = nil) -> Bookmark {
        let bookmark = Bookmark(at: date.addingTimeInterval(-Self.markerLead), note: Self.cleaned(note))
        insert(.bookmark(bookmark))
        return bookmark
    }

    /// Adds a "new speaker" marker just before `date`, so the paragraph that
    /// starts there begins a new speaker's turn.
    @discardableResult
    public mutating func addSpeakerChange(before date: Date, label: String? = nil) -> SpeakerChange {
        let change = SpeakerChange(at: date.addingTimeInterval(-Self.markerLead), label: Self.cleaned(label))
        insert(.speakerChange(change))
        return change
    }

    private static func cleaned(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
