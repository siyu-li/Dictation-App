import XCTest
@testable import TranscriptCore

final class TextJoinerTests: XCTestCase {
    func testEnglishGetsSpaces() {
        XCTAssertEqual(TextJoiner.join(["Hello there.", "How are you?"]), "Hello there. How are you?")
    }

    func testChineseHasNoSpaces() {
        XCTAssertEqual(TextJoiner.join(["我们今天开会。", "先讨论预算"]), "我们今天开会。先讨论预算")
    }

    func testMixedLanguageBoundaries() {
        XCTAssertEqual(TextJoiner.join(["我们用", "Swift", "写代码"]), "我们用Swift写代码")
    }

    func testTrimsAndSkipsEmptyParts() {
        XCTAssertEqual(TextJoiner.join(["  one ", "", "   ", "two"]), "one two")
    }

    func testNoSpaceBeforePunctuation() {
        XCTAssertEqual(TextJoiner.join(["Well", ", okay", "."]), "Well, okay.")
    }
}

final class TimestampFormatterTests: XCTestCase {
    func testClock() {
        let f = TimestampFormatter(timeZone: utc)
        XCTAssertEqual(f.clock(at(125)), "14:02")
        XCTAssertEqual(f.clock(at(125), includeSeconds: true), "14:02:05")
    }

    func testClockRespectsTimeZone() {
        let f = TimestampFormatter(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        XCTAssertEqual(f.clock(t0), "22:00")
    }

    func testDay() {
        XCTAssertEqual(TimestampFormatter(timeZone: utc).day(t0), "Wed 4 Nov 2026")
    }

    func testElapsed() {
        XCTAssertEqual(TimestampFormatter.elapsed(0), "00:00")
        XCTAssertEqual(TimestampFormatter.elapsed(725.9), "12:05")
        XCTAssertEqual(TimestampFormatter.elapsed(4325), "1:12:05")
        XCTAssertEqual(TimestampFormatter.elapsed(-3), "00:00")
    }

    func testDuration() {
        XCTAssertEqual(TimestampFormatter.duration(45), "45 s")
        XCTAssertEqual(TimestampFormatter.duration(12 * 60 + 30), "12 min")
        XCTAssertEqual(TimestampFormatter.duration(3600), "1 h")
        XCTAssertEqual(TimestampFormatter.duration(6300), "1 h 45 min")
    }
}
