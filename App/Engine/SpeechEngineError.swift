import AVFoundation
import Foundation

/// Problems the speech engine reports to the user (via `RecordingCoordinator.lastError`).
enum SpeechEngineError: LocalizedError {
    case alreadyRunning
    case microphonePermissionDenied
    case microphoneUnavailable
    case languageNotSupported(String)
    case modelDownloadFailed(String)
    case audioFormatUnavailable
    case audioEngineFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "A recording is already running."
        case .microphonePermissionDenied:
            "Dictation needs microphone access. Turn it on in Settings → Privacy & Security → Microphone → Dictation."
        case .microphoneUnavailable:
            "The microphone isn't available right now. It may be in use by a call or another app."
        case .languageNotSupported(let language):
            "Transcription in \(language) isn't supported on this iPhone."
        case .modelDownloadFailed(let detail):
            "Couldn't prepare the speech model for this language. Check your internet connection and try again. (\(detail))"
        case .audioFormatUnavailable:
            "Couldn't set up audio for speech recognition."
        case .audioEngineFailed(let detail):
            "Couldn't start recording: \(detail)"
        }
    }

    /// True for errors caused by the microphone rather than by the speech model.
    var isMicrophoneProblem: Bool {
        switch self {
        case .microphonePermissionDenied, .microphoneUnavailable, .audioEngineFailed: true
        default: false
        }
    }
}

/// The parts of an `AVAudioSession.interruptionNotification` the engine needs,
/// extracted on the posting thread so they can cross into the engine actor.
struct InterruptionInfo: Sendable {
    let began: Bool
    let shouldResume: Bool
    let reason: String

    init?(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return nil }
        began = type == .began
        let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
        if let reasonValue = info[AVAudioSessionInterruptionReasonKey] as? UInt,
           AVAudioSession.InterruptionReason(rawValue: reasonValue) == .builtInMicMuted {
            reason = "The microphone was muted"
        } else {
            reason = "Phone call, Siri, or another app used the microphone"
        }
    }
}

enum EngineDescribe {
    /// Domain and code included, so AVAudioSession error codes show up in the log.
    static func error(_ error: Error) -> String {
        if let engineError = error as? SpeechEngineError {
            return engineError.errorDescription ?? String(describing: engineError)
        }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
    }

    static func format(_ format: AVAudioFormat) -> String {
        let sample: String
        switch format.commonFormat {
        case .pcmFormatInt16: sample = "Int16"
        case .pcmFormatInt32: sample = "Int32"
        case .pcmFormatFloat32: sample = "Float32"
        case .pcmFormatFloat64: sample = "Float64"
        default: sample = "format \(format.commonFormat.rawValue)"
        }
        return "\(Int(format.sampleRate)) Hz, \(format.channelCount) ch, \(sample)\(format.isInterleaved ? ", interleaved" : "")"
    }
}
