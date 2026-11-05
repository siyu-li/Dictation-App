import Foundation

/// A person the AI identified in the transcript.
public struct SpeakerProfile: Codable, Equatable, Sendable {
    /// A name if the transcript states one, otherwise a role ("Presenter").
    public var label: String
    public var description: String

    public init(label: String, description: String) {
        self.label = label
        self.description = description
    }
}

/// From `start` on, `speaker` is talking (until the next turn).
public struct SpeakerTurn: Codable, Equatable, Sendable {
    public var start: Date
    public var speaker: String

    public init(start: Date, speaker: String) {
        self.start = start
        self.speaker = speaker
    }
}

/// The AI's one-line description of a photo (e.g. a slide's title and point).
public struct PhotoNote: Codable, Equatable, Sendable {
    public var photoID: UUID
    public var text: String

    public init(photoID: UUID, text: String) {
        self.photoID = photoID
        self.text = text
    }
}

/// AI-generated title, summary and speaker guesses for a session.
public struct SessionInsights: Codable, Equatable, Sendable {
    public var title: String
    public var summary: String
    public var keyPoints: [String]
    public var actionItems: [String]
    public var speakers: [SpeakerProfile]
    /// Sorted by `start`. Anchored to time (not paragraph numbers) so they
    /// survive changing the paragraph settings.
    public var speakerTurns: [SpeakerTurn]
    /// Model that produced the result.
    public var model: String
    public var generatedAt: Date
    public var inputTokens: Int?
    public var outputTokens: Int?
    /// Descriptions of the photos that were sent (optional: older results have none).
    public var photoNotes: [PhotoNote]?

    public init(
        title: String,
        summary: String,
        keyPoints: [String],
        actionItems: [String],
        speakers: [SpeakerProfile],
        speakerTurns: [SpeakerTurn],
        model: String,
        generatedAt: Date,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        photoNotes: [PhotoNote]? = nil
    ) {
        self.title = title
        self.summary = summary
        self.keyPoints = keyPoints
        self.actionItems = actionItems
        self.speakers = speakers
        self.speakerTurns = speakerTurns.sorted { $0.start < $1.start }
        self.model = model
        self.generatedAt = generatedAt
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.photoNotes = photoNotes
    }

    /// The AI's description of a photo, if it has one.
    public func note(forPhoto id: UUID) -> String? {
        photoNotes?.first { $0.photoID == id }?.text
    }

    /// The guessed speaker at a moment, if any.
    public func speaker(at date: Date) -> String? {
        speakerTurns.last { $0.start <= date }?.speaker
    }
}
