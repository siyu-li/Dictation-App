import AVFoundation
import CoreMedia
import Foundation
import Speech
import TranscriptCore

/// Live transcription with Apple's on-device SpeechAnalyzer (iOS 26).
///
/// A session (start → stop) is made of one or more *runs*. A run is one
/// continuous microphone capture feeding one `SpeechAnalyzer`. A new run starts
/// after every interruption, audio route change, or recognition error, so a
/// long recording survives phone calls, Siri and the Camera app.
///
/// Everything that starts or ends runs goes through `serialized`, so two
/// notifications arriving together can never create two runs.
actor SpeechAnalyzerEngine: TranscriptionEngine {
    private struct Run {
        let id: Int
        let capture: CaptureRun
        let analyzer: SpeechAnalyzer
        let resultsTask: Task<Void, Never>
        let configurationObserver: NSObjectProtocol
        let startedAt: Date
    }

    /// `UIApplication.didBecomeActiveNotification`, by its raw name so this
    /// actor doesn't touch main-actor UIKit API.
    private static let appDidBecomeActive = Notification.Name("UIApplicationDidBecomeActiveNotification")

    /// No audio for this long while capturing counts as an interruption.
    private static let stallThreshold: TimeInterval = 6
    /// A resumed run must deliver audio within this time to count as resumed.
    private static let resumeAudioTimeout: TimeInterval = 3

    private let log: DiagnosticsLog
    /// Shared with the recording screen's level meter.
    private let levelMeter: AudioLevelMeter?

    private var events: AsyncStream<TranscriptionEvent>.Continuation?
    private var configuration: TranscriptionConfiguration?
    private var model: ResolvedModel?
    /// Bumped on every start and stop, so stale notifications are ignored.
    private var generation = 0
    private var isActive = false
    private var isStopping = false
    private var isInterrupted = false
    private var currentRun: Run?
    /// Unique across sessions (identifies runs in notifications and the log).
    private var runCounter = 0
    /// Numbers this session's audio files: run-1.m4a, run-2.m4a, ...
    private var sessionRunIndex = 0
    private var resumeAttempts = 0
    private var quickFailures = 0
    private var retryTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var transitionTail: Task<Void, Never>?
    /// True while `startBody` runs; `cancelStart()` only acts then.
    private var isStarting = false
    /// Every `start()` call takes a ticket; `cancelStart()` cancels all
    /// tickets issued so far, including starts still waiting in the queue.
    private var startTicketsIssued = 0
    private var startTicketsCancelledThrough = 0
    /// The model lookup/download of the start in progress, so it can be cancelled.
    private var pendingStartWork: Task<ResolvedModel, Error>?

    init(log: DiagnosticsLog, levelMeter: AudioLevelMeter? = nil) {
        self.log = log
        self.levelMeter = levelMeter
    }

    // MARK: - TranscriptionEngine

    func start(_ configuration: TranscriptionConfiguration) async throws -> AsyncStream<TranscriptionEvent> {
        // Starting runs in the serial queue too: notifications that arrive
        // while starting (a call ringing as the user taps Start) are handled
        // right after, in order, instead of racing the first run.
        startTicketsIssued += 1
        let ticket = startTicketsIssued
        let box = StartResultBox()
        await serialized { await self.startLocked(configuration, ticket: ticket, into: box) }
        return try box.result()
    }

    private func startLocked(_ configuration: TranscriptionConfiguration, ticket: Int, into box: StartResultBox) async {
        // Cancelled while it was still waiting behind an earlier operation.
        guard ticket > startTicketsCancelledThrough else {
            logEngine("Skipping a start that was cancelled before it began")
            box.set(.failure(CancellationError()))
            return
        }
        do {
            box.set(.success(try await startBody(configuration)))
        } catch {
            box.set(.failure(error))
        }
    }

    /// Not serialized: it must be able to interrupt a start in progress.
    func cancelStart() {
        startTicketsCancelledThrough = startTicketsIssued
        guard isStarting, isActive, !isStopping else { return }
        logEngine("Start cancelled")
        generation += 1 // the start fails at its next check and cleans up
        pendingStartWork?.cancel()
    }

    private func startBody(_ configuration: TranscriptionConfiguration) async throws -> AsyncStream<TranscriptionEvent> {
        guard !isActive else { throw SpeechEngineError.alreadyRunning }
        isStarting = true
        defer {
            isStarting = false
            pendingStartWork = nil
        }

        isActive = true
        isStopping = false
        isInterrupted = false
        generation += 1
        let gen = generation
        self.configuration = configuration
        sessionRunIndex = 0
        resumeAttempts = 0
        quickFailures = 0
        let (stream, continuation) = AsyncStream.makeStream(of: TranscriptionEvent.self, bufferingPolicy: .unbounded)
        events = continuation
        logEngine("Starting: locale=\(configuration.localeIdentifier) saveAudio=\(configuration.audioDirectory != nil) model=\(configuration.speechModel.rawValue)")

        do {
            try await Self.requestMicrophonePermission(log: log)
            try ensureCurrent(gen) // cancelled while the permission prompt was up
            try Self.activateAudioSession(log: log)
            let status: @Sendable (String) -> Void = { continuation.yield(.status($0)) }
            // The meeting model falls back to dictation when it isn't available.
            var resolved = try await resolveModel(
                configuration.localeIdentifier,
                allowSpeechTranscriber: configuration.speechModel == .meeting,
                status: status
            )
            try ensureCurrent(gen)
            model = resolved
            // Listen for interruptions before the first run starts so none are missed.
            addObservers(gen: gen)
            do {
                try await startRun()
            } catch {
                // SpeechTranscriber may be listed but not work on this device;
                // try the dictation model once unless the microphone is the problem.
                let microphoneProblem = (error as? SpeechEngineError)?.isMicrophoneProblem ?? false
                guard resolved.kind == .speech, !microphoneProblem, !(error is CancellationError) else { throw error }
                logEngine("SpeechTranscriber run failed (\(EngineDescribe.error(error))); trying DictationTranscriber")
                try ensureCurrent(gen)
                resolved = try await resolveModel(configuration.localeIdentifier, allowSpeechTranscriber: false, status: status)
                try ensureCurrent(gen)
                model = resolved
                try await startRun()
            }
            try ensureCurrent(gen)
            if let run = currentRun {
                let gotAudio = await Self.waitForAudio(run.capture, timeout: Self.resumeAudioTimeout)
                if !gotAudio { logEngine("Warning: no audio in the first \(Int(Self.resumeAudioTimeout)) s") }
            }
            try ensureCurrent(gen)
            startHealthChecks(gen: gen)
            continuation.yield(.status("Transcribing with \(resolved.kind.rawValue), locale \(resolved.locale.identifier)"))
            return stream
        } catch {
            logEngine("Start failed: \(EngineDescribe.error(error))")
            removeObservers()
            if let run = currentRun {
                currentRun = nil
                await finalizeRun(run)
            }
            Self.deactivateAudioSession(log: log)
            continuation.finish()
            events = nil
            isActive = false
            self.configuration = nil
            model = nil
            generation += 1
            throw error
        }
    }

    func stop() async {
        await serialized { await self.shutdownLocked(failure: nil) }
    }

    /// Looks up (and if needed downloads) the speech model as a cancellable task.
    private func resolveModel(
        _ localeIdentifier: String,
        allowSpeechTranscriber: Bool,
        status: @escaping @Sendable (String) -> Void
    ) async throws -> ResolvedModel {
        let log = self.log
        let work = Task {
            try await SpeechModelSetup.resolve(
                localeIdentifier: localeIdentifier,
                allowSpeechTranscriber: allowSpeechTranscriber,
                log: log,
                status: status
            )
        }
        pendingStartWork = work
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    // MARK: - Serialization

    /// Runs `operation` after every previously queued operation has finished.
    /// Never call this from inside a serialized operation (it would wait for itself).
    private func serialized(_ operation: @escaping @Sendable () async -> Void) async {
        let previous = transitionTail
        let task = Task {
            await previous?.value
            await operation()
        }
        transitionTail = task
        await task.value
    }

    private func isCurrent(_ gen: Int) -> Bool {
        gen == generation && isActive && !isStopping
    }

    private func ensureCurrent(_ gen: Int) throws {
        guard isCurrent(gen) else { throw CancellationError() }
    }

    // MARK: - Runs

    /// Starts a new run with the current model. Doesn't touch `isInterrupted`.
    private func startRun() async throws {
        guard isActive, !isStopping, let model, let configuration, let events else { throw CancellationError() }
        runCounter += 1
        sessionRunIndex += 1
        let runID = runCounter

        let module = SpeechModelSetup.makeModule(model, fastCaptions: configuration.fastCaptions)
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module.speechModule]) else {
            throw SpeechEngineError.audioFormatUnavailable
        }
        // Live captions: analysis runs at user-initiated priority, and the
        // model stays in memory for a while after a run ends, so the new run
        // after an interruption or a camera pause doesn't reload it.
        let analyzer = SpeechAnalyzer(
            modules: [module.speechModule],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        )
        // Load the model before the microphone starts. Otherwise the analyzer
        // does this when the first audio arrives, and the first captions lag
        // behind until it catches up.
        let prepareStarted = Date()
        do {
            try await analyzer.prepareToAnalyze(in: analyzerFormat)
            logEngine("Run \(runID): speech model ready in \(Int(Date().timeIntervalSince(prepareStarted) * 1000)) ms")
        } catch {
            // Not fatal: the analyzer then prepares itself on the first audio.
            logEngine("Run \(runID): preparing the speech model failed: \(EngineDescribe.error(error))")
        }
        guard isActive, !isStopping else { throw CancellationError() }

        var audioFile: AudioFileWriter?
        if let directory = configuration.audioDirectory {
            do {
                audioFile = try AudioFileWriter(directory: directory, fileName: "run-\(sessionRunIndex).m4a")
            } catch {
                logEngine("Run \(runID): can't create audio file: \(EngineDescribe.error(error))")
                events.yield(.status("Couldn't save audio for this part of the recording: \(error.localizedDescription)"))
            }
        }

        let (inputSequence, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        let capture = CaptureRun(
            id: runID,
            analyzerFormat: analyzerFormat,
            input: inputContinuation,
            events: events,
            audioFile: audioFile,
            log: log,
            levelMeter: levelMeter
        )

        do {
            try await analyzer.start(inputSequence: inputSequence)
        } catch {
            capture.stopCapture()
            _ = capture.finishAudioFile()
            throw error
        }

        let resultsLog = self.log
        let resultsTask = Task {
            do {
                try await Self.consumeResults(module: module, capture: capture, events: events, log: resultsLog)
                self.runResultsEnded(runID: runID, error: nil)
            } catch {
                self.runResultsEnded(runID: runID, error: error)
            }
        }

        capture.setDiscontinuityHandler { lastGoodAudio in
            Task { await self.enqueueDiscontinuity(runID: runID, lastGoodAudio: lastGoodAudio) }
        }
        do {
            try capture.startCapture()
            guard isActive, !isStopping else { throw CancellationError() }
        } catch {
            capture.stopCapture()
            // Bounded, so a stuck analyzer can't hang the serial queue (and stop()).
            let finished = await Self.waitAtMost(seconds: 5) {
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            if !finished { logEngine("Run \(runID): finalize after failed start timed out") }
            resultsTask.cancel()
            _ = capture.finishAudioFile()
            throw error
        }

        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: capture.audioEngine,
            queue: nil
        ) { _ in
            Task { await self.enqueueConfigurationChange(runID: runID) }
        }
        currentRun = Run(
            id: runID,
            capture: capture,
            analyzer: analyzer,
            resultsTask: resultsTask,
            configurationObserver: observer,
            startedAt: Date()
        )
        logEngine("Run \(runID) started (\(model.kind.rawValue), \(model.locale.identifier), fast captions \(configuration.fastCaptions && model.kind == .speech ? "on" : "off"))")
    }

    /// Stops a run's capture and waits until its last final results are
    /// delivered. The caller must already have cleared `currentRun`.
    private func finalizeRun(_ run: Run) async {
        NotificationCenter.default.removeObserver(run.configurationObserver)
        run.capture.stopCapture()

        let analyzer = run.analyzer
        let resultsTask = run.resultsTask
        let runID = run.id
        let log = self.log
        let finalize = Task {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                log.log("Run \(runID): finalize failed: \(EngineDescribe.error(error))", category: "engine")
            }
        }
        // Don't let a stuck analyzer block stop() forever: wait at most 20 s,
        // then move on even if the tasks ignore cancellation.
        let finished = await Self.waitAtMost(seconds: 20) {
            await finalize.value
            await resultsTask.value
        }
        if !finished {
            log.log("Run \(runID): finalizing took over 20 s; giving up on its last results", category: "engine")
            finalize.cancel()
            resultsTask.cancel()
        }

        if let fileName = run.capture.finishAudioFile() {
            events?.yield(.audioFileFinished(fileName: fileName, at: run.capture.lastAudioDate ?? Date()))
        }
        logEngine("Run \(run.id) finalized after \(Int(Date().timeIntervalSince(run.startedAt))) s")
    }

    /// How often each run writes its caption delay to the diagnostics log.
    private static let delayReportInterval: TimeInterval = 120

    private static func consumeResults(
        module: TranscriberModule,
        capture: CaptureRun,
        events: AsyncStream<TranscriptionEvent>.Continuation,
        log: DiagnosticsLog
    ) async throws {
        var delays = CaptionDelayStats()
        func handle(text: String, isFinal: Bool, range: CMTimeRange) {
            // Hand the text on first; measuring comes after.
            deliver(text: text, isFinal: isFinal, range: range, capture: capture, events: events)
            let now = Date()
            if let delay = capture.resultDelay(for: range, now: now) {
                delays.record(delay: delay, isFinal: isFinal)
            }
            if let line = delays.report(now: now, every: delayReportInterval) {
                log.log("Run \(capture.id): \(line)", category: "engine")
            }
        }
        defer {
            if let line = delays.report(every: delayReportInterval, force: true) {
                log.log("Run \(capture.id): \(line)", category: "engine")
            }
        }
        switch module {
        case .speech(let transcriber):
            for try await result in transcriber.results {
                handle(text: String(result.text.characters), isFinal: result.isFinal, range: result.range)
            }
        case .dictation(let transcriber):
            for try await result in transcriber.results {
                handle(text: String(result.text.characters), isFinal: result.isFinal, range: result.range)
            }
        }
    }

    private static func deliver(
        text: String,
        isFinal: Bool,
        range: CMTimeRange,
        capture: CaptureRun,
        events: AsyncStream<TranscriptionEvent>.Continuation
    ) {
        if isFinal {
            let interval = capture.wallClockInterval(for: range)
            events.yield(.final(text: text, start: interval.start, end: interval.end))
        } else {
            events.yield(.volatile(text))
        }
    }

    /// Called when a run's results stream ends. Expected when the run was
    /// finalized on purpose (it's no longer `currentRun`); otherwise the
    /// recognizer died and recovery is queued. Not serialized: `finalizeRun`
    /// waits for the results task, which ends by calling this.
    private func runResultsEnded(runID: Int, error: Error?) {
        guard let run = currentRun, run.id == runID else { return }
        logEngine("Run \(runID): recognition ended unexpectedly: \(error.map(EngineDescribe.error) ?? "no error")")
        let gen = generation
        Task { await self.serialized { await self.recoverFromRunFailureLocked(runID: runID, gen: gen) } }
    }

    // MARK: - Interruptions and recovery (serialized)

    private func enqueueInterruption(_ info: InterruptionInfo, gen: Int) async {
        await serialized { await self.interruptionLocked(info, gen: gen) }
    }

    private func enqueueMediaServicesReset(gen: Int) async {
        await serialized { await self.mediaServicesResetLocked(gen: gen) }
    }

    private func enqueueAppBecameActive(gen: Int) async {
        await serialized { await self.appBecameActiveLocked(gen: gen) }
    }

    private func enqueueDiscontinuity(runID: Int, lastGoodAudio: Date) async {
        await serialized { await self.discontinuityLocked(runID: runID, lastGoodAudio: lastGoodAudio) }
    }

    /// Audio paused and came back on the same run (e.g. the Camera app used
    /// the mic without an interruption). Mark the gap and start a fresh run so
    /// timestamps stay right.
    private func discontinuityLocked(runID: Int, lastGoodAudio: Date) async {
        guard isActive, !isStopping, let run = currentRun, run.id == runID else { return }
        logEngine("Run \(runID): audio paused and resumed; starting a new run")
        let gen = generation
        await interruptLocked(at: lastGoodAudio, reason: "The microphone paused (another app may have used it)")
        if await !attemptResumeLocked(trigger: "audio resumed after a pause") {
            scheduleRetries(gen: gen, initialDelay: 2)
        }
    }

    private func enqueueConfigurationChange(runID: Int) async {
        await serialized { await self.configurationChangeLocked(runID: runID) }
    }

    private func interruptionLocked(_ info: InterruptionInfo, gen: Int) async {
        guard isCurrent(gen) else { return }
        if info.began {
            logEngine("Interruption began: \(info.reason)")
            await interruptLocked(at: Date(), reason: info.reason)
            // Some interruptions never send "ended"; keep trying in the background.
            scheduleRetries(gen: gen, initialDelay: 10)
        } else {
            logEngine("Interruption ended (shouldResume: \(info.shouldResume))")
            guard isInterrupted else { return }
            if await !attemptResumeLocked(trigger: "interruption ended") {
                scheduleRetries(gen: gen, initialDelay: 2)
            }
        }
    }

    private func mediaServicesResetLocked(gen: Int) async {
        guard isCurrent(gen) else { return }
        logEngine("Media services were reset; rebuilding audio")
        await interruptLocked(at: Date(), reason: "The iPhone's audio system restarted")
        if await !attemptResumeLocked(trigger: "media services reset") {
            scheduleRetries(gen: gen, initialDelay: 2)
        }
    }

    private func appBecameActiveLocked(gen: Int) async {
        guard isCurrent(gen) else { return }
        if isInterrupted {
            if await !attemptResumeLocked(trigger: "app became active") {
                scheduleRetries(gen: gen, initialDelay: 3)
            }
        } else if let run = currentRun, run.capture.secondsWithoutAudio() > 2 {
            // Audio stopped while the app was in the background (e.g. the
            // Camera app took the microphone without an interruption).
            logEngine("App became active; run \(run.id) has had no audio for \(Int(run.capture.secondsWithoutAudio())) s")
            await interruptLocked(at: run.capture.lastAudioDate ?? run.startedAt, reason: "Another app used the microphone")
            if await !attemptResumeLocked(trigger: "app became active after audio stopped") {
                scheduleRetries(gen: gen, initialDelay: 3)
            }
        }
    }

    private func configurationChangeLocked(runID: Int) async {
        guard isActive, !isStopping, let run = currentRun, run.id == runID else { return }
        logEngine("Run \(runID): audio route or format changed; restarting capture")
        currentRun = nil
        await finalizeRun(run)
        do {
            try Self.activateAudioSession(log: log)
            try await startRun()
            events?.yield(.status("Audio input changed; capture restarted"))
        } catch {
            logEngine("Restart after audio change failed: \(EngineDescribe.error(error))")
            await interruptLocked(at: run.capture.lastAudioDate ?? Date(), reason: "The microphone changed or became unavailable")
            scheduleRetries(gen: generation, initialDelay: 2)
        }
    }

    private func recoverFromRunFailureLocked(runID: Int, gen: Int) async {
        guard isCurrent(gen), let run = currentRun, run.id == runID else { return }
        currentRun = nil
        await finalizeRun(run)
        let lifetime = Date().timeIntervalSince(run.startedAt)
        quickFailures = lifetime < 20 ? quickFailures + 1 : 1
        if quickFailures >= 3 {
            await shutdownLocked(failure: "Speech recognition keeps stopping, so recording ended. Everything up to now is saved.")
            return
        }
        await interruptLocked(at: run.capture.lastAudioDate ?? Date(), reason: "Speech recognition restarted")
        if await !attemptResumeLocked(trigger: "recognition error") {
            scheduleRetries(gen: gen, initialDelay: 2)
        }
    }

    private func healthCheckLocked(gen: Int) async {
        guard isCurrent(gen), !isInterrupted, let run = currentRun else { return }
        let silentFor = run.capture.secondsWithoutAudio()
        guard silentFor > Self.stallThreshold else { return }
        logEngine("Run \(run.id): no audio for \(Int(silentFor)) s (audio engine running: \(run.capture.audioEngine.isRunning))")
        await interruptLocked(
            at: run.capture.lastAudioDate ?? run.startedAt,
            reason: "The microphone stopped (another app may be using it)"
        )
        scheduleRetries(gen: gen, initialDelay: 5)
    }

    /// Closes the current run (delivering its last results) and then marks
    /// the session interrupted (one `interrupted` event per gap). Reporting
    /// after the run's last results lets the coordinator keep any text that
    /// was never finalized, without risking duplicates, and save right away.
    private func interruptLocked(at date: Date, reason: String) async {
        let shouldReport = !isInterrupted
        isInterrupted = true
        if let run = currentRun {
            currentRun = nil
            await finalizeRun(run)
        }
        if shouldReport {
            events?.yield(.interrupted(at: date, reason: reason))
        }
    }

    /// Tries to start a new run after an interruption. Counts as resumed only
    /// once audio actually arrives.
    @discardableResult
    private func attemptResumeLocked(trigger: String) async -> Bool {
        guard isActive, !isStopping, isInterrupted, currentRun == nil else { return false }
        resumeAttempts += 1
        let attempt = resumeAttempts
        logEngine("Resume attempt \(attempt) (\(trigger))")
        do {
            try Self.activateAudioSession(log: log)
            try await startRun()
        } catch {
            logEngine("Resume attempt \(attempt) failed: \(EngineDescribe.error(error))")
            return false
        }
        guard let run = currentRun else { return false }
        guard await Self.waitForAudio(run.capture, timeout: Self.resumeAudioTimeout) else {
            logEngine("Resume attempt \(attempt): no audio arrived; closing run \(run.id)")
            currentRun = nil
            await finalizeRun(run)
            return false
        }
        isInterrupted = false
        resumeAttempts = 0
        retryTask?.cancel()
        retryTask = nil
        events?.yield(.resumed(at: Date()))
        logEngine("Resumed after \(attempt) attempt(s)")
        return true
    }

    /// Retries resuming with growing delays (capped at 60 s) until resumed or
    /// stopped. Replaces any earlier retry schedule.
    private func scheduleRetries(gen: Int, initialDelay: TimeInterval) {
        retryTask?.cancel()
        retryTask = Task {
            var delay = initialDelay
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return }
                await self.serialized { await self.retryLocked(gen: gen) }
                if !self.needsResume(gen: gen) { return }
                delay = min(delay * 2, 60)
            }
        }
    }

    private func retryLocked(gen: Int) async {
        guard isCurrent(gen), isInterrupted else { return }
        await attemptResumeLocked(trigger: "timed retry")
    }

    private func needsResume(gen: Int) -> Bool {
        isCurrent(gen) && isInterrupted
    }

    private func startHealthChecks(gen: Int) {
        healthTask?.cancel()
        healthTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { return }
                await self.serialized { await self.healthCheckLocked(gen: gen) }
            }
        }
    }

    // MARK: - Shutdown

    /// Stops everything and finishes the event stream. With `failure`, sends
    /// `.failed` first.
    private func shutdownLocked(failure: String?) async {
        guard isActive, !isStopping else { return }
        isStopping = true
        logEngine(failure.map { "Shutting down after failure: \($0)" } ?? "Stopping")
        retryTask?.cancel()
        retryTask = nil
        healthTask?.cancel()
        healthTask = nil
        removeObservers()
        if let run = currentRun {
            currentRun = nil
            await finalizeRun(run)
        }
        Self.deactivateAudioSession(log: log)
        if let failure { events?.yield(.failed(failure)) }
        events?.finish()
        events = nil
        configuration = nil
        model = nil
        isInterrupted = false
        resumeAttempts = 0
        quickFailures = 0
        isActive = false
        isStopping = false
        generation += 1
        logEngine("Stopped")
    }

    // MARK: - Observers

    private func addObservers(gen: Int) {
        removeObservers()
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard let info = InterruptionInfo(notification) else { return }
            Task { await self.enqueueInterruption(info, gen: gen) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task { await self.enqueueMediaServicesReset(gen: gen) }
        })
        observers.append(center.addObserver(
            forName: Self.appDidBecomeActive,
            object: nil,
            queue: nil
        ) { _ in
            Task { await self.enqueueAppBecameActive(gen: gen) }
        })
    }

    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    // MARK: - Audio session and permission

    private static func requestMicrophonePermission(log: DiagnosticsLog) async throws {
        let granted = await AVAudioApplication.requestRecordPermission()
        log.log("Microphone permission granted: \(granted)", category: "engine")
        guard granted else { throw SpeechEngineError.microphonePermissionDenied }
    }

    /// Record and keep recording in the background. Mixing with others keeps
    /// other apps' audio playing and makes interruptions less likely.
    private static func activateAudioSession(log: DiagnosticsLog) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)
        let inputs = session.currentRoute.inputs.map(\.portName).joined(separator: ", ")
        log.log(
            "Audio session active: \(Int(session.sampleRate)) Hz, input available: \(session.isInputAvailable), inputs: \(inputs.isEmpty ? "none" : inputs)",
            category: "engine"
        )
        guard session.isInputAvailable else { throw SpeechEngineError.microphoneUnavailable }
    }

    private static func deactivateAudioSession(log: DiagnosticsLog) {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            log.log("Deactivating audio session failed: \(EngineDescribe.error(error))", category: "engine")
        }
    }

    private static func waitForAudio(_ capture: CaptureRun, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if capture.hasReceivedAudio { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return capture.hasReceivedAudio
    }

    private nonisolated func logEngine(_ message: String) {
        log.log(message, category: "engine")
    }
}

/// Hands the result of a serialized start back to `start(_:)`.
private final class StartResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<AsyncStream<TranscriptionEvent>, Error>?

    func set(_ result: Result<AsyncStream<TranscriptionEvent>, Error>) {
        lock.withLock { value = result }
    }

    func result() throws -> AsyncStream<TranscriptionEvent> {
        try (lock.withLock { value } ?? .failure(CancellationError())).get()
    }
}

/// Resumes a continuation exactly once.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Bool) {
        let continuation = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: value)
    }
}

extension SpeechAnalyzerEngine {
    /// Runs `work` and returns true if it finished within `seconds`, false
    /// otherwise. Unlike a task group, it doesn't wait for work that never
    /// finishes.
    static func waitAtMost(seconds: Double, _ work: @escaping @Sendable () async -> Void) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            let timer = Task {
                do {
                    try await Task.sleep(for: .seconds(seconds))
                } catch {
                    return // cancelled because the work finished
                }
                once.resume(false)
            }
            Task {
                await work()
                once.resume(true)
                timer.cancel()
            }
        }
    }
}
