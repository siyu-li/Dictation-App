import Foundation
import Observation
import TranscriptCore

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    /// Language for new recordings.
    var language: TranscriptLanguage {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }

    /// Also save the audio of new recordings (off by default to save storage).
    var saveAudio: Bool {
        didSet { defaults.set(saveAudio, forKey: Keys.saveAudio) }
    }

    /// Silence (seconds) that starts a new paragraph.
    var pauseThreshold: Double {
        didSet { defaults.set(pauseThreshold, forKey: Keys.pauseThreshold) }
    }

    var timestampStyle: TimestampStyle {
        didSet { defaults.set(timestampStyle.rawValue, forKey: Keys.timestampStyle) }
    }

    /// Name of the user's Shortcut that saves a transcript to Apple Notes.
    var notesShortcutName: String {
        didSet { defaults.set(notesShortcutName, forKey: Keys.notesShortcutName) }
    }

    /// Run the Notes shortcut automatically after stopping a recording.
    var sendToNotesAfterStop: Bool {
        didSet { defaults.set(sendToNotesAfterStop, forKey: Keys.sendToNotesAfterStop) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = TranscriptLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "") ?? .englishUS
        saveAudio = defaults.bool(forKey: Keys.saveAudio)
        let pause = defaults.double(forKey: Keys.pauseThreshold)
        pauseThreshold = pause > 0 ? pause : 2.0
        timestampStyle = TimestampStyle(rawValue: defaults.string(forKey: Keys.timestampStyle) ?? "") ?? .clock
        notesShortcutName = defaults.string(forKey: Keys.notesShortcutName) ?? "Dictation to Notes"
        sendToNotesAfterStop = defaults.bool(forKey: Keys.sendToNotesAfterStop)
    }

    var formatOptions: FormatOptions {
        FormatOptions(pauseThreshold: pauseThreshold)
    }

    var exportOptions: ExportOptions {
        ExportOptions(timestampStyle: timestampStyle, format: formatOptions)
    }

    private enum Keys {
        static let language = "settings.language"
        static let saveAudio = "settings.saveAudio"
        static let pauseThreshold = "settings.pauseThreshold"
        static let timestampStyle = "settings.timestampStyle"
        static let notesShortcutName = "settings.notesShortcutName"
        static let sendToNotesAfterStop = "settings.sendToNotesAfterStop"
    }
}
