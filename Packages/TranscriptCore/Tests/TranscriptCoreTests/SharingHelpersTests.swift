import XCTest
@testable import TranscriptCore

final class ExportFileNameTests: XCTestCase {
    func testTitledSession() {
        let session = TranscriptSession(title: "Team meeting", localeIdentifier: "en-US", startedAt: at(120))
        XCTAssertEqual(TranscriptExporter.suggestedFileName(for: session, timeZone: utc), "2026-11-04 1402 Team meeting")
    }

    func testUntitledSessionUsesDefaultTitle() {
        let session = TranscriptSession(localeIdentifier: "en-US", startedAt: t0)
        XCTAssertEqual(TranscriptExporter.suggestedFileName(for: session, timeZone: utc), "2026-11-04 1400 Transcript")
    }

    func testUsesTimeZone() {
        let session = TranscriptSession(localeIdentifier: "zh-CN", startedAt: t0)
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        XCTAssertEqual(TranscriptExporter.suggestedFileName(for: session, timeZone: shanghai), "2026-11-04 2200 Transcript")
    }

    func testInvalidCharactersBecomeSpaces() {
        let session = TranscriptSession(title: "Q&A: plan/budget?  \"final\"", localeIdentifier: "en-US", startedAt: t0)
        XCTAssertEqual(TranscriptExporter.suggestedFileName(for: session, timeZone: utc), "2026-11-04 1400 Q&A plan budget final")
    }

    func testChineseTitleIsKept() {
        let session = TranscriptSession(title: "产品评审会", localeIdentifier: "zh-CN", startedAt: t0)
        XCTAssertEqual(TranscriptExporter.suggestedFileName(for: session, timeZone: utc), "2026-11-04 1400 产品评审会")
    }

    func testSanitizeTrimsDotsNewlinesAndControlCharacters() {
        XCTAssertEqual(TranscriptExporter.sanitizedFileName("..hidden\nname\u{0007}.."), "hidden name")
    }

    func testSanitizeEmptyFallsBack() {
        XCTAssertEqual(TranscriptExporter.sanitizedFileName(" /:. "), "Transcript")
        XCTAssertEqual(TranscriptExporter.sanitizedFileName("", fallback: "Export"), "Export")
    }

    func testLongNamesAreTruncatedWithoutTrailingSpace() {
        let name = TranscriptExporter.sanitizedFileName(String(repeating: "word ", count: 40), maxLength: 22)
        XCTAssertEqual(name, "word word word word wo")
        XCTAssertLessThanOrEqual(name.count, 22)
        let cut = TranscriptExporter.sanitizedFileName("abcd efgh", maxLength: 5)
        XCTAssertEqual(cut, "abcd")
    }
}

final class ShortcutLinkTests: XCTestCase {
    func testNotesShortcutURL() {
        let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        let url = ShortcutLink.runShortcutURL(name: "Dictation to Notes", inputText: id.uuidString)
        XCTAssertEqual(
            url?.absoluteString,
            "shortcuts://run-shortcut?name=Dictation%20to%20Notes&input=text&text=6F9619FF-8B86-D011-B42D-00C04FC964FF"
        )
    }

    func testEncodesReservedAndNonASCIICharacters() {
        let url = ShortcutLink.runShortcutURL(name: " 笔记 & more+1=2 ")
        XCTAssertEqual(url?.absoluteString, "shortcuts://run-shortcut?name=%E7%AC%94%E8%AE%B0%20%26%20more%2B1%3D2")
    }

    func testEmptyNameGivesNil() {
        XCTAssertNil(ShortcutLink.runShortcutURL(name: "   "))
    }
}

final class SessionLookupTests: XCTestCase {
    private func finished(_ start: TimeInterval) -> TranscriptSession {
        TranscriptSession(localeIdentifier: "en-US", startedAt: at(start), endedAt: at(start + 60))
    }

    func testFindsById() {
        let a = finished(0), b = finished(100)
        XCTAssertEqual(SessionLookup.find(a.id.uuidString, in: [b, a]), .found(a))
    }

    func testIdIgnoresWhitespaceAndCase() {
        let a = finished(0)
        XCTAssertEqual(SessionLookup.find("  \(a.id.uuidString.lowercased())\n", in: [a]), .found(a))
    }

    func testFindsUnfinishedSessionById() {
        let open = TranscriptSession(localeIdentifier: "en-US", startedAt: t0)
        XCTAssertEqual(SessionLookup.find(open.id.uuidString, in: [open]), .found(open))
    }

    func testUnknownIdIsNotFound() {
        let id = UUID()
        XCTAssertEqual(SessionLookup.find(id.uuidString, in: [finished(0)]), .notFound(id))
    }

    func testEmptyOrInvalidIdGivesMostRecentFinished() {
        let older = finished(0), newer = finished(500)
        let recording = TranscriptSession(localeIdentifier: "en-US", startedAt: at(1000))
        let sessions = [older, recording, newer]
        XCTAssertEqual(SessionLookup.find(nil, in: sessions), .found(newer))
        XCTAssertEqual(SessionLookup.find("", in: sessions), .found(newer))
        XCTAssertEqual(SessionLookup.find("hello", in: sessions), .found(newer))
    }

    func testNoFinishedSessions() {
        let recording = TranscriptSession(localeIdentifier: "en-US", startedAt: t0)
        XCTAssertEqual(SessionLookup.find(nil, in: [recording]), .noFinishedSessions)
        XCTAssertEqual(SessionLookup.find(nil, in: []), .noFinishedSessions)
    }
}
