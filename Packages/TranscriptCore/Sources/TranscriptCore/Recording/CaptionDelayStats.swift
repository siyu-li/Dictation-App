import Foundation

/// How far the recognizer's text trails the speech it's about, summarized
/// for the diagnostics log so caption lag can be checked on a real phone.
///
/// A delay is the time between the end of the audio a result covers and the
/// moment the result arrived. Live (volatile) text is what the caption shows;
/// final text is what the transcript keeps.
public struct CaptionDelayStats: Sendable, Equatable {
    public struct Series: Sendable, Equatable {
        public private(set) var count = 0
        public private(set) var total: TimeInterval = 0
        public private(set) var longest: TimeInterval = 0

        public var average: TimeInterval { count > 0 ? total / Double(count) : 0 }

        mutating func add(_ delay: TimeInterval) {
            count += 1
            total += delay
            longest = max(longest, delay)
        }
    }

    public private(set) var live = Series()
    public private(set) var final = Series()
    private var periodStart: Date

    /// Delays outside this range come from a bad time anchor, not from the
    /// recognizer, and are ignored.
    static let plausible: ClosedRange<TimeInterval> = -1...120

    public init(now: Date = Date()) {
        periodStart = now
    }

    public mutating func record(delay: TimeInterval, isFinal: Bool) {
        guard delay.isFinite, Self.plausible.contains(delay) else { return }
        let clamped = max(0, delay)
        if isFinal { final.add(clamped) } else { live.add(clamped) }
    }

    /// A one-line summary of the results since the last report, once
    /// `interval` has passed (or always, if `force`). Starts a new period.
    public mutating func report(now: Date = Date(), every interval: TimeInterval, force: Bool = false) -> String? {
        let elapsed = now.timeIntervalSince(periodStart)
        guard force || elapsed >= interval else { return nil }
        defer {
            live = Series()
            final = Series()
            periodStart = now
        }
        guard live.count + final.count > 0 else { return nil }
        var parts: [String] = []
        if live.count > 0 { parts.append("live text \(Self.seconds(live.average)) avg, longest \(Self.seconds(live.longest))") }
        if final.count > 0 { parts.append("final text \(Self.seconds(final.average)) avg, longest \(Self.seconds(final.longest))") }
        return "Caption delay over \(Int(elapsed.rounded())) s: " + parts.joined(separator: "; ")
            + " (\(live.count + final.count) results)"
    }

    private static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.2f s", value)
    }
}
