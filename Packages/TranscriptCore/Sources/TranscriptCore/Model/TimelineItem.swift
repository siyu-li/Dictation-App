import Foundation

/// A piece of finalized recognized speech with its wall-clock time range.
public struct SpeechSegment: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var start: Date
    public var end: Date

    public init(id: UUID = UUID(), text: String, start: Date, end: Date) {
        self.id = id
        self.text = text
        self.start = start
        self.end = max(start, end)
    }
}

/// A marker the user drops when a different person starts talking.
public struct SpeakerChange: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var at: Date
    /// Optional name, e.g. set later by the user or by AI speaker guessing.
    public var label: String?

    public init(id: UUID = UUID(), at: Date, label: String? = nil) {
        self.id = id
        self.at = at
        self.label = label
    }
}

public enum PhotoSource: String, Codable, Sendable {
    /// Taken with the camera button inside the app.
    case camera
    /// Imported from the Photos library (e.g. taken with the system Camera app).
    case photoLibrary
}

/// A photo placed in the transcript at the moment it was taken.
public struct PhotoAttachment: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var takenAt: Date
    /// File name inside the session's `photos` directory.
    public var fileName: String
    public var source: PhotoSource
    /// `PHAsset.localIdentifier` for library imports, used to avoid importing twice.
    public var libraryIdentifier: String?

    public init(
        id: UUID = UUID(),
        takenAt: Date,
        fileName: String,
        source: PhotoSource,
        libraryIdentifier: String? = nil
    ) {
        self.id = id
        self.takenAt = takenAt
        self.fileName = fileName
        self.source = source
        self.libraryIdentifier = libraryIdentifier
    }
}

/// A stretch of time with no audio, e.g. while another app took the microphone.
public struct AudioGap: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var start: Date
    /// `nil` while the gap is still open.
    public var end: Date?
    public var reason: String

    public init(id: UUID = UUID(), start: Date, end: Date? = nil, reason: String) {
        self.id = id
        self.start = start
        self.end = end
        self.reason = reason
    }
}

/// One entry on a session's timeline.
public enum TimelineItem: Equatable, Sendable, Identifiable {
    case speech(SpeechSegment)
    case speakerChange(SpeakerChange)
    case photo(PhotoAttachment)
    case gap(AudioGap)

    public var id: UUID {
        switch self {
        case .speech(let s): s.id
        case .speakerChange(let c): c.id
        case .photo(let p): p.id
        case .gap(let g): g.id
        }
    }

    /// The moment this item happens; the timeline is ordered by this value.
    public var time: Date {
        switch self {
        case .speech(let s): s.start
        case .speakerChange(let c): c.at
        case .photo(let p): p.takenAt
        case .gap(let g): g.start
        }
    }

    /// The last moment this item covers.
    public var endTime: Date {
        switch self {
        case .speech(let s): s.end
        case .gap(let g): g.end ?? g.start
        default: time
        }
    }
}

extension TimelineItem: Codable {
    private enum CodingKeys: String, CodingKey { case type, value }
    private enum Kind: String, Codable { case speech, speakerChange, photo, gap }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .speech: self = .speech(try container.decode(SpeechSegment.self, forKey: .value))
        case .speakerChange: self = .speakerChange(try container.decode(SpeakerChange.self, forKey: .value))
        case .photo: self = .photo(try container.decode(PhotoAttachment.self, forKey: .value))
        case .gap: self = .gap(try container.decode(AudioGap.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .speech(let s):
            try container.encode(Kind.speech, forKey: .type)
            try container.encode(s, forKey: .value)
        case .speakerChange(let c):
            try container.encode(Kind.speakerChange, forKey: .type)
            try container.encode(c, forKey: .value)
        case .photo(let p):
            try container.encode(Kind.photo, forKey: .type)
            try container.encode(p, forKey: .value)
        case .gap(let g):
            try container.encode(Kind.gap, forKey: .type)
            try container.encode(g, forKey: .value)
        }
    }
}
