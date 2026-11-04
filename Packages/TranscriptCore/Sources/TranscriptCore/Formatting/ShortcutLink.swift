import Foundation

/// Builds `shortcuts://` URLs that run one of the user's Shortcuts.
public enum ShortcutLink {
    /// `shortcuts://run-shortcut?name=<name>&input=text&text=<inputText>`,
    /// or `nil` when the name is empty.
    public static func runShortcutURL(name: String, inputText: String? = nil) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var query = "name=" + encode(trimmed)
        if let inputText {
            query += "&input=text&text=" + encode(inputText)
        }
        return URL(string: "shortcuts://run-shortcut?" + query)
    }

    /// RFC 3986 unreserved characters only (ASCII), so `&`, `=`, `+`, spaces
    /// and non-ASCII text are always percent-encoded.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}
