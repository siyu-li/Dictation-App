import Foundation

public struct TranscriptionConfiguration: Sendable, Equatable {
    /// BCP-47 identifier, e.g. `en-US` or `zh-CN`.
    public var localeIdentifier: String
    /// Where to write audio files, or `nil` to not save audio (the default).
    public var audioDirectory: URL?

    public init(localeIdentifier: String, audioDirectory: URL? = nil) {
        self.localeIdentifier = localeIdentifier
        self.audioDirectory = audioDirectory
    }
}

/// What a transcription engine reports while it runs. All times are wall-clock.
public enum TranscriptionEvent: Sendable, Equatable {
    /// In-progress text for the current phrase; replaces the previous volatile text.
    case volatile(String)
    /// Finalized text for a phrase. Clears the volatile text.
    case final(text: String, start: Date, end: Date)
    /// Audio capture stopped because something else took the microphone
    /// (phone call, Siri, another app recording). The engine tries to resume
    /// by itself and sends `resumed` when it does.
    case interrupted(at: Date, reason: String)
    case resumed(at: Date)
    /// An audio file (inside `TranscriptionConfiguration.audioDirectory`) was opened.
    case audioFileStarted(fileName: String, at: Date)
    case audioFileFinished(fileName: String, at: Date)
    /// Informational message for the diagnostics log.
    case status(String)
    /// The engine stopped for good. The stream finishes right after this.
    case failed(String)
}

/// Captures microphone audio and turns it into `TranscriptionEvent`s.
///
/// Contract:
/// - `start` returns once capture is running, or throws (no microphone
///   permission, language not supported, model download failed, ...).
/// - The returned stream delivers events in order until the engine stops.
/// - After `interrupted`, the engine resumes on its own when it can (when the
///   interruption ends or the app returns to the foreground) and sends `resumed`.
/// - `stop()` stops capture, delivers the remaining `final` results, finishes
///   the stream, and only then returns.
/// - If the engine dies, it sends `failed` and finishes the stream.
public protocol TranscriptionEngine: Sendable {
    func start(_ configuration: TranscriptionConfiguration) async throws -> AsyncStream<TranscriptionEvent>
    func stop() async
}
