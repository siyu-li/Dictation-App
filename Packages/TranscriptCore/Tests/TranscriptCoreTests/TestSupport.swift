import Foundation
@testable import TranscriptCore

/// 2026-11-04 14:00:00 UTC
let t0 = Date(timeIntervalSince1970: 1_793_800_800)
let utc = TimeZone(identifier: "UTC")!

func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

func speech(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TimelineItem {
    .speech(SpeechSegment(text: text, start: at(start), end: at(end)))
}

func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("TranscriptCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A controllable clock for the coordinator.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = t0) { current = start }
    func now() -> Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// An engine driven by the test.
final class MockEngine: TranscriptionEngine, @unchecked Sendable {
    struct StartFailure: Error, LocalizedError {
        var errorDescription: String? { "Microphone permission denied" }
    }

    private let lock = NSLock()
    private var continuation: AsyncStream<TranscriptionEvent>.Continuation?
    var startError: Error?
    private(set) var configurations: [TranscriptionConfiguration] = []
    /// Events delivered during `stop()` before the stream finishes, like the
    /// last final results of a real engine.
    var eventsOnStop: [TranscriptionEvent] = []
    private(set) var stopCount = 0

    func start(_ configuration: TranscriptionConfiguration) async throws -> AsyncStream<TranscriptionEvent> {
        if let startError { throw startError }
        let (stream, continuation) = AsyncStream.makeStream(of: TranscriptionEvent.self)
        lock.withLock {
            configurations.append(configuration)
            self.continuation = continuation
        }
        return stream
    }

    func send(_ event: TranscriptionEvent) {
        _ = lock.withLock { continuation }?.yield(event)
    }

    /// Simulates the engine dying.
    func finishStream() {
        lock.withLock { continuation }?.finish()
    }

    func stop() async {
        let continuation = lock.withLock { () -> AsyncStream<TranscriptionEvent>.Continuation? in
            stopCount += 1
            return self.continuation
        }
        for event in eventsOnStop { continuation?.yield(event) }
        continuation?.finish()
    }
}
