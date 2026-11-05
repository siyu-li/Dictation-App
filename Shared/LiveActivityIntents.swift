import AppIntents
import Foundation

/// What the Lock Screen buttons do. The intents below run in the app's
/// process (`LiveActivityIntent`); the app sets these hooks at launch. In the
/// widget extension they stay nil and are never called.
enum LiveActivityActions {
    @MainActor static var markSpeaker: (() -> Void)?
    @MainActor static var addBookmark: (() -> Void)?
}

/// Lock Screen button: a different person started talking.
struct MarkSpeakerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "New speaker"
    static let description = IntentDescription("Marks in the recording that a different person started talking.")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        LiveActivityActions.markSpeaker?()
        return .result()
    }
}

/// Lock Screen button: this moment is important.
struct AddBookmarkIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Bookmark"
    static let description = IntentDescription("Marks this moment of the recording as important.")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        LiveActivityActions.addBookmark?()
        return .result()
    }
}
