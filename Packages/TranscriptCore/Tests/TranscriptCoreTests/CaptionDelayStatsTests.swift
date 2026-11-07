import XCTest
@testable import TranscriptCore

final class CaptionDelayStatsTests: XCTestCase {
    func testSummarizesLiveAndFinalDelaysAndResets() throws {
        var stats = CaptionDelayStats(now: t0)
        stats.record(delay: 0.4, isFinal: false)
        stats.record(delay: 0.8, isFinal: false)
        stats.record(delay: 2.0, isFinal: true)
        XCTAssertNil(stats.report(now: at(30), every: 60), "not due yet")

        let line = try XCTUnwrap(stats.report(now: at(60), every: 60))
        XCTAssertEqual(line, "Caption delay over 60 s: live text 0.60 s avg, longest 0.80 s; final text 2.00 s avg, longest 2.00 s (3 results)")
        XCTAssertEqual(stats.live.count, 0, "a report starts a new period")
        XCTAssertNil(stats.report(now: at(200), every: 60), "nothing to report")
    }

    func testIgnoresImplausibleDelaysAndClampsSmallNegativeOnes() throws {
        var stats = CaptionDelayStats(now: t0)
        stats.record(delay: -0.2, isFinal: false)
        stats.record(delay: -5, isFinal: false)
        stats.record(delay: 500, isFinal: true)
        stats.record(delay: .nan, isFinal: true)
        XCTAssertEqual(stats.live.count, 1)
        XCTAssertEqual(stats.live.average, 0)
        XCTAssertEqual(stats.final.count, 0)
        let line = try XCTUnwrap(stats.report(now: at(5), every: 60, force: true))
        XCTAssertTrue(line.hasPrefix("Caption delay over 5 s: live text 0.00 s avg"), line)
        XCTAssertFalse(line.contains("final"))
    }
}
