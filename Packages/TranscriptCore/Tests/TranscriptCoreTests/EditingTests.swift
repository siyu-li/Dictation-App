import XCTest
@testable import TranscriptCore

final class TranscriptEditingTests: XCTestCase {
    private func session() -> TranscriptSession {
        var s = TranscriptSession(localeIdentifier: "en-US", startedAt: t0)
        s.insert(speech("Hello every one.", 1, 2))
        s.insert(speech("Welcome to the talk.", 2.5, 4))
        s.insert(speech("Second paragraph.", 10, 12))
        s.endedAt = at(20)
        return s
    }

    private func paragraphs(_ s: TranscriptSession) -> [Paragraph] {
        TranscriptFormatter.blocks(for: s.items).compactMap { if case .paragraph(let p) = $0 { p } else { nil } }
    }

    func testEditParagraphMergesItsSegmentsAndKeepsIdentity() throws {
        var s = session()
        let first = try XCTUnwrap(paragraphs(s).first)
        XCTAssertEqual(first.segmentIDs.count, 2)
        XCTAssertTrue(s.replaceParagraph(segmentIDs: first.segmentIDs, with: "  Hello everyone. Welcome to the talk. "))
        let edited = try XCTUnwrap(paragraphs(s).first)
        XCTAssertEqual(edited.id, first.id, "the paragraph keeps its identity")
        XCTAssertEqual(edited.text, "Hello everyone. Welcome to the talk.")
        XCTAssertEqual(edited.start, at(1))
        XCTAssertEqual(edited.end, at(4))
        XCTAssertEqual(paragraphs(s).count, 2)
        XCTAssertEqual(s.speechSegments.count, 2)
    }

    func testEmptyTextDeletesParagraph() throws {
        var s = session()
        let first = try XCTUnwrap(paragraphs(s).first)
        XCTAssertTrue(s.replaceParagraph(segmentIDs: first.segmentIDs, with: "   "))
        XCTAssertEqual(paragraphs(s).map(\.text), ["Second paragraph."])
        XCTAssertFalse(s.replaceParagraph(segmentIDs: [UUID()], with: "x"), "unknown paragraph")
    }

    func testAddEditDeleteBookmark() throws {
        var s = session()
        let second = paragraphs(s)[1]
        let bookmark = s.addBookmark(before: second.start)
        // The bookmark sits between the two paragraphs.
        let kinds = TranscriptFormatter.blocks(for: s.items).map { block -> String in
            if case .bookmark = block { return "bookmark" }
            if case .paragraph(let p) = block { return p.text }
            return "other"
        }
        XCTAssertEqual(kinds, ["Hello every one. Welcome to the talk.", "bookmark", "Second paragraph."])

        XCTAssertTrue(s.setBookmarkNote("  Key point ", id: bookmark.id))
        XCTAssertEqual(s.bookmarks.first?.note, "Key point")
        XCTAssertTrue(s.setBookmarkNote("", id: bookmark.id))
        XCTAssertNil(s.bookmarks.first?.note)
        XCTAssertTrue(s.removeItem(id: bookmark.id))
        XCTAssertTrue(s.bookmarks.isEmpty)
        XCTAssertFalse(s.removeItem(id: bookmark.id))
    }

    func testAddRenameDeleteSpeaker() throws {
        var s = session()
        let second = paragraphs(s)[1]
        let change = s.addSpeakerChange(before: second.start, label: "Dana")
        let blocks = TranscriptFormatter.blocks(for: s.items)
        guard case .speakerChange(let marker) = blocks[1] else { return XCTFail("speaker marker before paragraph 2") }
        XCTAssertEqual(marker.label, "Dana")
        XCTAssertTrue(s.setSpeakerLabel("Prof. Li", id: change.id))
        XCTAssertTrue(s.setSpeakerLabel(" ", id: change.id))
        guard case .speakerChange(let renamed) = TranscriptFormatter.blocks(for: s.items)[1] else { return XCTFail() }
        XCTAssertNil(renamed.label)
        XCTAssertFalse(s.setSpeakerLabel("x", id: UUID()))
        XCTAssertFalse(s.setBookmarkNote("x", id: change.id), "not a bookmark")
        XCTAssertTrue(s.removeItem(id: change.id))
        XCTAssertEqual(paragraphs(s).count, 2)
    }

    func testEditsSurviveSaveAndExport() throws {
        var s = session()
        let first = try XCTUnwrap(paragraphs(s).first)
        s.replaceParagraph(segmentIDs: first.segmentIDs, with: "Fixed text.")
        s.addBookmark(before: paragraphs(s)[1].start, note: "Remember")
        let store = FileSessionStore(rootDirectory: try makeTempDirectory())
        try store.save(s)
        let loaded = try store.load(id: s.id)
        // Times round-trip through JSON with sub-microsecond float noise, so
        // compare content and order rather than exact equality.
        XCTAssertEqual(loaded.items.map(\.id), s.items.map(\.id))
        XCTAssertEqual(loaded.bookmarks.first?.note, "Remember")
        XCTAssertEqual(loaded.speechSegments.map(\.text), ["Fixed text.", "Second paragraph."])
        let text = TranscriptExporter.plainText(for: loaded, options: ExportOptions(includeHeader: false, timeZone: utc))
        XCTAssertEqual(text, "[14:00] Fixed text.\n\n[14:00] ★ Bookmark: Remember\n\n[14:00] Second paragraph.\n")
    }
}
