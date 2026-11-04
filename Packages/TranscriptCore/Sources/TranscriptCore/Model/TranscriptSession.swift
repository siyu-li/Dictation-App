import Foundation

/// Languages the app offers for live transcription. Apple's on-device engine
/// transcribes one language per session.
public enum TranscriptLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case englishUS = "en-US"
    case chineseMandarin = "zh-CN"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .englishUS: "English (US)"
        case .chineseMandarin: "中文（普通话）"
        }
    }

    /// Display name for any stored locale identifier, falling back to the identifier.
    public static func displayName(for identifier: String) -> String {
        TranscriptLanguage(rawValue: identifier)?.displayName ?? identifier
    }
}

/// A saved audio file for one continuous recording run (a new run starts after
/// every interruption).
public struct AudioRecording: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// File name inside the session's `audio` directory.
    public var fileName: String
    public var startedAt: Date
    public var endedAt: Date?

    public init(id: UUID = UUID(), fileName: String, startedAt: Date, endedAt: Date? = nil) {
        self.id = id
        self.fileName = fileName
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

/// One recording session: everything captured between Start and Stop.
public struct TranscriptSession: Equatable, Sendable, Identifiable {
    public static let currentFormatVersion = 1

    public var id: UUID
    public var formatVersion: Int
    public var title: String?
    public var localeIdentifier: String
    public var startedAt: Date
    /// `nil` while recording (or if the app was killed mid-recording and the
    /// session has not been recovered yet).
    public var endedAt: Date?
    /// Ordered by `TimelineItem.time`. Use `insert(_:)` to keep the order.
    public var items: [TimelineItem]
    public var audioRecordings: [AudioRecording]
    /// True if the app stopped unexpectedly during this session and it was
    /// closed on the next launch.
    public var wasRecovered: Bool
    /// AI title, summary and speaker guesses, once generated.
    public var insights: SessionInsights?

    public init(
        id: UUID = UUID(),
        title: String? = nil,
        localeIdentifier: String,
        startedAt: Date,
        endedAt: Date? = nil,
        items: [TimelineItem] = [],
        audioRecordings: [AudioRecording] = [],
        wasRecovered: Bool = false,
        insights: SessionInsights? = nil
    ) {
        self.id = id
        self.formatVersion = Self.currentFormatVersion
        self.title = title
        self.localeIdentifier = localeIdentifier
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.items = []
        self.audioRecordings = audioRecordings
        self.wasRecovered = wasRecovered
        self.insights = insights
        for item in items { insert(item) }
    }

    public var isFinished: Bool { endedAt != nil }

    public func duration(now: Date = Date()) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }

    public var speechSegments: [SpeechSegment] {
        items.compactMap { if case .speech(let s) = $0 { s } else { nil } }
    }

    public var photos: [PhotoAttachment] {
        items.compactMap { if case .photo(let p) = $0 { p } else { nil } }
    }

    /// All recognized text joined together, without timestamps.
    public var fullText: String {
        TextJoiner.join(speechSegments.map(\.text))
    }

    /// Inserts an item keeping the timeline sorted by time. Items with equal
    /// times keep their insertion order.
    public mutating func insert(_ item: TimelineItem) {
        let time = item.time
        var low = 0
        var high = items.count
        while low < high {
            let mid = (low + high) / 2
            if items[mid].time <= time { low = mid + 1 } else { high = mid }
        }
        items.insert(item, at: low)
    }

    /// Replaces the item with the same id (its time must not change ordering
    /// semantics; gaps only change their end).
    public mutating func replace(_ item: TimelineItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        if items[index].time == item.time {
            items[index] = item
        } else {
            items.remove(at: index)
            insert(item)
        }
    }

    /// Closes a session that was left open because the app was terminated
    /// while recording. Open gaps and audio files are closed at the last known
    /// moment of activity.
    public func recoveredIfUnfinished() -> TranscriptSession {
        guard endedAt == nil else { return self }
        var session = self
        let lastActivity = items.map(\.endTime).max() ?? startedAt
        session.endedAt = max(lastActivity, startedAt)
        for index in session.items.indices {
            if case .gap(var gap) = session.items[index], gap.end == nil {
                gap.end = session.endedAt
                session.items[index] = .gap(gap)
            }
        }
        for index in session.audioRecordings.indices where session.audioRecordings[index].endedAt == nil {
            session.audioRecordings[index].endedAt = session.endedAt
        }
        session.wasRecovered = true
        return session
    }
}

extension TranscriptSession: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, formatVersion, title, localeIdentifier, startedAt, endedAt, items, audioRecordings, wasRecovered, insights
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        title = try c.decodeIfPresent(String.self, forKey: .title)
        localeIdentifier = try c.decodeIfPresent(String.self, forKey: .localeIdentifier) ?? TranscriptLanguage.englishUS.rawValue
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        items = try c.decodeIfPresent([TimelineItem].self, forKey: .items) ?? []
        audioRecordings = try c.decodeIfPresent([AudioRecording].self, forKey: .audioRecordings) ?? []
        wasRecovered = try c.decodeIfPresent(Bool.self, forKey: .wasRecovered) ?? false
        insights = try c.decodeIfPresent(SessionInsights.self, forKey: .insights)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(localeIdentifier, forKey: .localeIdentifier)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(endedAt, forKey: .endedAt)
        try c.encode(items, forKey: .items)
        try c.encode(audioRecordings, forKey: .audioRecordings)
        try c.encode(wasRecovered, forKey: .wasRecovered)
        try c.encodeIfPresent(insights, forKey: .insights)
    }
}
