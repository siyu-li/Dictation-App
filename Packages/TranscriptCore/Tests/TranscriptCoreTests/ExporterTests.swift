import XCTest
@testable import TranscriptCore

final class TranscriptExporterTests: XCTestCase {
    private func sampleSession() -> TranscriptSession {
        var session = TranscriptSession(title: "Team meeting", localeIdentifier: "en-US", startedAt: at(120))
        session.insert(speech("So the main thing", 125, 127))
        session.insert(speech("is the launch date.", 127.5, 129))
        session.insert(.speakerChange(SpeakerChange(at: at(300))))
        session.insert(speech("I think we should wait.", 301, 303))
        session.insert(.photo(PhotoAttachment(takenAt: at(600), fileName: "slide.jpg", source: .camera)))
        session.insert(.gap(AudioGap(start: at(1925), end: at(1960), reason: "Phone call")))
        session.endedAt = at(120 + 6300)
        return session
    }

    func testPlainText() {
        let text = TranscriptExporter.plainText(for: sampleSession(), options: ExportOptions(timeZone: utc))
        XCTAssertEqual(text, """
        Team meeting
        Wed 4 Nov 2026 · 14:02–15:47 · 1 h 45 min · English (US)

        [14:02] So the main thing is the launch date.

        — New speaker —
        [14:05] I think we should wait.

        [14:10] 📷 Photo

        [14:32] ⚠︎ No audio 14:32:05–14:32:40 (Phone call)

        """)
    }

    func testPlainTextElapsedWithoutHeader() {
        let options = ExportOptions(timestampStyle: .elapsed, includeHeader: false, timeZone: utc)
        let text = TranscriptExporter.plainText(for: sampleSession(), options: options)
        XCTAssertTrue(text.hasPrefix("[00:05] So the main thing is the launch date.\n"), text)
        XCTAssertTrue(text.contains("[03:01] I think we should wait."), text)
    }

    func testPlainTextWithoutTimestamps() {
        let options = ExportOptions(includeTimestamps: false, includeHeader: false, timeZone: utc)
        let text = TranscriptExporter.plainText(for: sampleSession(), options: options)
        XCTAssertTrue(text.hasPrefix("So the main thing is the launch date.\n"), text)
    }

    func testMarkdown() {
        let md = TranscriptExporter.markdown(for: sampleSession(), options: ExportOptions(timeZone: utc))
        XCTAssertTrue(md.hasPrefix("# Team meeting\n\n*Wed 4 Nov 2026 · 14:02–15:47 · 1 h 45 min · English (US)*\n"), md)
        XCTAssertTrue(md.contains("**14:02** So the main thing is the launch date."), md)
        XCTAssertTrue(md.contains("**— New speaker —**"), md)
        XCTAssertTrue(md.contains("![Photo at 14:10:00](photos/slide.jpg)"), md)
        XCTAssertTrue(md.contains("> ⚠︎ No audio 14:32:05–14:32:40 (Phone call)"), md)
    }

    func testUntitledInProgressSession() {
        var session = TranscriptSession(localeIdentifier: "zh-CN", startedAt: t0)
        session.insert(speech("你好", 1, 2))
        let text = TranscriptExporter.plainText(for: session, options: ExportOptions(timeZone: utc), now: at(90))
        XCTAssertTrue(text.hasPrefix("Transcript\nWed 4 Nov 2026 · 14:00–now · 1 min · 中文（普通话）\n"), text)
    }

    func testRecoveredNote() {
        var session = sampleSession()
        session.wasRecovered = true
        XCTAssertTrue(TranscriptExporter.plainText(for: session, options: ExportOptions(timeZone: utc))
            .contains("Recording ended unexpectedly"))
    }
}
