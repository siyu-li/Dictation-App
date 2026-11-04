import Foundation

public enum TimestampStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Time of day, e.g. `14:02`.
    case clock
    /// Time since the session started, e.g. `1:12:05`.
    case elapsed

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .clock: "Time of day"
        case .elapsed: "Time since start"
        }
    }
}

/// Deterministic time formatting (fixed calendar, injected time zone) so exports
/// look the same everywhere and tests are stable.
public struct TimestampFormatter: Sendable {
    public var timeZone: TimeZone

    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// `14:02` or `14:02:05`.
    public func clock(_ date: Date, includeSeconds: Bool = false) -> String {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        let hm = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        return includeSeconds ? hm + String(format: ":%02d", c.second ?? 0) : hm
    }

    /// `Wed 4 Nov 2026`.
    public func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE d MMM yyyy"
        return formatter.string(from: date)
    }

    /// `12:05` below one hour, `1:12:05` from one hour.
    public static func elapsed(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    /// Human duration: `45 s`, `12 min`, `1 h 45 min`.
    public static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        if total < 60 { return "\(total) s" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours == 0 { return "\(minutes) min" }
        return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min"
    }
}
