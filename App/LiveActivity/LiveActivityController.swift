import ActivityKit
import Foundation
import TranscriptCore

/// Shows the recording on the Lock Screen (Live Activity) and keeps it
/// current while the phone is locked.
///
/// Cheap by design: the elapsed time ticks by itself, a check runs every 5 s
/// only while an activity exists, the activity is updated only when something
/// visible changed, and the caption at most every 15 s.
@MainActor
final class LiveActivityController {
    private typealias State = RecordingActivityAttributes.ContentState

    private static let checkInterval: Duration = .seconds(5)
    private static let captionInterval: TimeInterval = 15

    private let recorder: RecordingCoordinator
    private let log: DiagnosticsLog
    private var activity: Activity<RecordingActivityAttributes>?
    private var lastState: State?
    private var lastCaptionUpdate = Date.distantPast
    private var checkTask: Task<Void, Never>?

    init(recorder: RecordingCoordinator, log: DiagnosticsLog) {
        self.recorder = recorder
        self.log = log

        // Lock Screen buttons (the intents run in this process).
        LiveActivityActions.markSpeaker = { [weak self] in
            guard let self else { return }
            self.recorder.markSpeakerChange()
            self.update()
        }
        LiveActivityActions.addBookmark = { [weak self] in
            guard let self else { return }
            self.recorder.markBookmark()
            self.update()
        }

        // An activity left over from a crash would show a recording that isn't running.
        for leftover in Activity<RecordingActivityAttributes>.activities {
            Task { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Starts the Live Activity for the recording that just started.
    func start() {
        guard activity == nil, recorder.isRecording, let session = recorder.session else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log.log("Live Activities are turned off for this app", category: "live-activity")
            return
        }
        let attributes = RecordingActivityAttributes(
            startedAt: session.startedAt,
            language: TranscriptLanguage.displayName(for: session.localeIdentifier)
        )
        let state = currentState(caption: currentCaption())
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            lastState = state
            lastCaptionUpdate = Date()
            startChecking()
            log.log("Live Activity started", category: "live-activity")
        } catch {
            log.log("Live Activity couldn't start: \(error)", category: "live-activity")
        }
    }

    /// Removes the Live Activity right away (stop, cancel, or the recording ended).
    func end() {
        checkTask?.cancel()
        checkTask = nil
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        log.log("Live Activity ended", category: "live-activity")
    }

    // MARK: - Updates

    private func startChecking() {
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.checkInterval)
                guard !Task.isCancelled, let self else { return }
                self.check()
            }
        }
    }

    private func check() {
        guard recorder.isActive else {
            // The recording ended some other way (e.g. the engine gave up).
            end()
            return
        }
        update()
    }

    /// Pushes a new state if anything visible changed. The caption only
    /// refreshes every `captionInterval` seconds.
    private func update() {
        guard let activity else { return }
        let captionDue = Date().timeIntervalSince(lastCaptionUpdate) >= Self.captionInterval
        let caption = captionDue ? currentCaption() : (lastState?.caption ?? "")
        let state = currentState(caption: caption)
        guard state != lastState else { return }
        if state.caption != lastState?.caption { lastCaptionUpdate = Date() }
        lastState = state
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    private func currentState(caption: String) -> State {
        let isPaused: Bool
        if case .interrupted = recorder.state { isPaused = true } else { isPaused = false }
        let session = recorder.session
        return State(
            isPaused: isPaused,
            statusText: isPaused ? "Paused" : "Recording",
            caption: caption,
            photoCount: session?.photos.count ?? 0,
            bookmarkCount: session?.bookmarks.count ?? 0
        )
    }

    private func currentCaption() -> String {
        recorder.captionTail(maxCharacters: 120)
    }
}
