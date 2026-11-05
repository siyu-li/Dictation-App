import ActivityKit
import Foundation

/// The Lock Screen Live Activity shown while recording. Compiled into both
/// the app (which starts and updates it) and the widget extension (which
/// draws it).
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var isPaused: Bool
        /// "Recording" or "Paused".
        var statusText: String
        /// The end of the live caption (updated at most every 15 s).
        var caption: String
        var photoCount: Int
        var bookmarkCount: Int
    }

    var startedAt: Date
    /// Display name of the recording language, e.g. "English (US)".
    var language: String
}
