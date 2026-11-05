import AVFoundation
import CoreMedia
import Foundation
import Speech
import TranscriptCore

/// One continuous microphone capture feeding one SpeechAnalyzer: an
/// AVAudioEngine input tap, conversion to the analyzer's format, and the
/// optional audio file for this run.
///
/// Threading: `process(_:)` runs on the audio tap thread; everything else is
/// called from the engine actor. All mutable state is guarded by `lock`, which
/// is why this class is `@unchecked Sendable`.
final class CaptureRun: @unchecked Sendable {
    let id: Int
    let audioEngine = AVAudioEngine()
    let analyzerFormat: AVAudioFormat
    let createdAt = Date()

    private let lock = NSLock()
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let events: AsyncStream<TranscriptionEvent>.Continuation
    private let log: DiagnosticsLog
    private let levelMeter: AudioLevelMeter?
    private let converter = BufferConverter()
    private var audioFile: AudioFileWriter?
    private var audioFileStarted = false
    private var firstAudioDate: Date?
    private var lastAudio: Date?
    private var inputFinished = false
    private var captureStarted = false
    private var conversionFailures = 0
    /// Set when audio stopped arriving for a while and then came back. The
    /// analyzer's timeline only counts audio it received, so feeding it more
    /// would shift every later timestamp; the run stops taking audio and the
    /// engine starts a new run (with a fresh time anchor) instead.
    private var discontinuityDetected = false
    private var onDiscontinuity: (@Sendable (Date) -> Void)?

    /// Longer than this between two buffers counts as a pause in the audio.
    /// Buffers normally arrive every ~0.1 s.
    private static let maxBufferGap: TimeInterval = 1.5

    init(
        id: Int,
        analyzerFormat: AVAudioFormat,
        input: AsyncStream<AnalyzerInput>.Continuation,
        events: AsyncStream<TranscriptionEvent>.Continuation,
        audioFile: AudioFileWriter?,
        log: DiagnosticsLog,
        levelMeter: AudioLevelMeter? = nil
    ) {
        self.id = id
        self.analyzerFormat = analyzerFormat
        self.input = input
        self.events = events
        self.audioFile = audioFile
        self.log = log
        self.levelMeter = levelMeter
    }

    // MARK: - Engine actor side

    /// Installs the tap and starts the audio engine.
    func startCapture() throws {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw SpeechEngineError.microphoneUnavailable
        }
        log.log(
            "Run \(id): mic \(EngineDescribe.format(inputFormat)) → analyzer \(EngineDescribe.format(analyzerFormat))",
            category: "engine"
        )
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        lock.withLock { captureStarted = true }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            throw SpeechEngineError.audioEngineFailed(EngineDescribe.error(error))
        }
    }

    /// Stops the microphone and ends the analyzer's input. Safe to call twice.
    func stopCapture() {
        let started = lock.withLock { captureStarted }
        if started {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        lock.withLock {
            captureStarted = false
            if !inputFinished {
                inputFinished = true
                input.finish()
            }
        }
    }

    /// Called (once, from the audio thread) with the time of the last good
    /// buffer when the audio paused and resumed.
    func setDiscontinuityHandler(_ handler: @escaping @Sendable (Date) -> Void) {
        lock.withLock { onDiscontinuity = handler }
    }

    var hasReceivedAudio: Bool {
        lock.withLock { firstAudioDate != nil }
    }

    /// When the last audio buffer arrived, if any.
    var lastAudioDate: Date? {
        lock.withLock { lastAudio }
    }

    func secondsWithoutAudio(now: Date = Date()) -> TimeInterval {
        now.timeIntervalSince(lock.withLock { lastAudio } ?? createdAt)
    }

    /// Maps a result's audio range (seconds since this run's first buffer) to
    /// wall-clock time.
    func wallClockInterval(for range: CMTimeRange) -> (start: Date, end: Date) {
        let anchor = lock.withLock { firstAudioDate } ?? createdAt
        let startSeconds = range.start.seconds
        guard range.start.isValid, range.start.isNumeric, startSeconds.isFinite else {
            let now = Date()
            return (now, now)
        }
        let start = anchor.addingTimeInterval(max(0, startSeconds))
        let durationSeconds = range.duration.seconds
        guard range.duration.isValid, range.duration.isNumeric, durationSeconds.isFinite, durationSeconds > 0 else {
            return (start, start)
        }
        return (start, start.addingTimeInterval(durationSeconds))
    }

    /// Closes the audio file. Returns its name if it holds audio; an empty file
    /// (no audio ever arrived) is deleted and `nil` is returned.
    func finishAudioFile() -> String? {
        lock.withLock {
            guard let file = audioFile else { return nil }
            audioFile = nil
            file.close()
            if audioFileStarted { return file.fileName }
            file.delete()
            return nil
        }
    }

    // MARK: - Audio tap thread

    private func process(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !inputFinished, !discontinuityDetected, buffer.frameLength > 0 else { return }

        let now = Date()
        if let last = lastAudio, now.timeIntervalSince(last) > Self.maxBufferGap {
            discontinuityDetected = true
            log.log("Run \(id): audio paused for \(String(format: "%.1f", now.timeIntervalSince(last))) s; this run stops taking audio", category: "engine")
            onDiscontinuity?(last)
            return
        }
        levelMeter?.measure(buffer)

        let converted: AVAudioPCMBuffer
        do {
            converted = try converter.convert(buffer, to: analyzerFormat)
        } catch {
            conversionFailures += 1
            if conversionFailures == 1 || conversionFailures % 200 == 0 {
                log.log("Run \(id): audio conversion failed (\(conversionFailures)x): \(error)", category: "engine")
            }
            return
        }
        input.yield(AnalyzerInput(buffer: converted))
        // Only audio the analyzer actually received counts, so a converter
        // that keeps failing looks like a stall (and gets recovered).
        if firstAudioDate == nil {
            // The first buffer started recording one buffer-length ago.
            let duration = Double(buffer.frameLength) / buffer.format.sampleRate
            firstAudioDate = now.addingTimeInterval(-duration)
        }
        lastAudio = now

        if let file = audioFile {
            do {
                try file.write(converted)
                if !audioFileStarted {
                    audioFileStarted = true
                    events.yield(.audioFileStarted(fileName: file.fileName, at: firstAudioDate ?? now))
                }
            } catch {
                log.log("Run \(id): writing audio failed, no more audio saved for this run: \(EngineDescribe.error(error))", category: "engine")
                events.yield(.status("Stopped saving audio for this part of the recording: \(error.localizedDescription)"))
                file.close()
                if audioFileStarted {
                    events.yield(.audioFileFinished(fileName: file.fileName, at: now))
                } else {
                    file.delete()
                }
                audioFile = nil
            }
        }
    }
}

/// Converts PCM buffers between formats (sample rate, channels, sample type).
/// Not thread-safe; each owner uses it from one thread at a time.
final class BufferConverter {
    enum ConversionError: Error {
        case cannotCreateConverter
        case cannotCreateBuffer
        case failed(NSError?)
    }

    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        if inputFormat == format {
            // The tap may reuse its buffer; hand out a copy.
            guard let copy = Self.copy(buffer) else { throw ConversionError.cannotCreateBuffer }
            return copy
        }
        if converter == nil || converter?.inputFormat != inputFormat || converter?.outputFormat != format {
            converter = AVAudioConverter(from: inputFormat, to: format)
            // Skip priming so output timestamps don't drift from the input.
            converter?.primeMethod = .none
        }
        guard let converter else { throw ConversionError.cannotCreateConverter }

        let ratio = format.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw ConversionError.cannotCreateBuffer
        }
        var nsError: NSError?
        // A reference box instead of a captured `var`, in case the SDK marks
        // the input block @Sendable.
        let consumed = ConsumedFlag()
        let status = converter.convert(to: output, error: &nsError) { _, inputStatus in
            if consumed.value {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed.value = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else { throw ConversionError.failed(nsError) }
        return output
    }

    /// Set once the converter has taken the single input buffer.
    private final class ConsumedFlag: @unchecked Sendable {
        var value = false
    }

    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let fromData = from.mData, let toData = to.mData else { continue }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }
}

/// Writes one run's audio as mono AAC (.m4a), about 15 MB per hour.
/// Not thread-safe; `CaptureRun` calls it with its lock held.
final class AudioFileWriter {
    let fileName: String
    let url: URL
    private var file: AVAudioFile?
    private let converter = BufferConverter()

    init(directory: URL, fileName: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileName = fileName
        self.url = directory.appendingPathComponent(fileName)
        var lastError: Error?
        for settings in Self.settingsCandidates() {
            do {
                file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                break
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: url)
            }
        }
        if file == nil {
            throw lastError ?? CocoaError(.fileWriteUnknown)
        }
    }

    /// 16 kHz mono AAC at 32 kbps (~14 MB/hour); if the encoder rejects that,
    /// 22.05 kHz mono at medium quality.
    private static func settingsCandidates() -> [[String: Any]] {
        [
            [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
            ],
            [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 22_050,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ],
        ]
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let file else { return }
        let converted = try converter.convert(buffer, to: file.processingFormat)
        try file.write(from: converted)
    }

    /// Releasing the AVAudioFile finalizes the .m4a.
    func close() {
        file = nil
    }

    func delete() {
        file = nil
        try? FileManager.default.removeItem(at: url)
    }
}
