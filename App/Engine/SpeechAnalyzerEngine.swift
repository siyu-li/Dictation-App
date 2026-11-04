import Foundation
import TranscriptCore

/// Live transcription with Apple's on-device SpeechAnalyzer (iOS 26).
///
/// Placeholder: the real implementation (microphone capture, SpeechTranscriber,
/// interruption handling, optional audio file) replaces this file.
final class SpeechAnalyzerEngine: TranscriptionEngine, @unchecked Sendable {
    enum EngineError: LocalizedError {
        case notImplemented

        var errorDescription: String? {
            "The transcription engine isn't built yet."
        }
    }

    private let log: DiagnosticsLog

    init(log: DiagnosticsLog) {
        self.log = log
    }

    func start(_ configuration: TranscriptionConfiguration) async throws -> AsyncStream<TranscriptionEvent> {
        log.log("start() called on placeholder engine", category: "engine")
        throw EngineError.notImplemented
    }

    func stop() async {}
}
