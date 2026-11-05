import Accelerate
import AVFoundation
import Foundation

/// The microphone's latest loudness, for the small level meter on the
/// recording screen. Written by the audio tap thread (a few times a second,
/// one cheap RMS per buffer), read by the UI at most 10 times a second while
/// the recording screen is visible.
final class AudioLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var level: Float = 0
    private var updatedAt: TimeInterval = 0

    /// 0…1, from roughly −50 dBFS (silent room) to 0 dBFS. Reads 0 when no
    /// audio arrived in the last half second (paused or interrupted).
    var currentLevel: Float {
        let now = ProcessInfo.processInfo.systemUptime
        return lock.withLock { now - updatedAt > 0.5 ? 0 : level }
    }

    /// Measures one buffer (channel 0). No allocations; float buffers only.
    func measure(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(buffer.frameLength))
        let decibels = 20 * log10(max(rms, 0.000_001))
        let normalized = min(max((decibels + 50) / 50, 0), 1)
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            level = normalized
            updatedAt = now
        }
    }
}
