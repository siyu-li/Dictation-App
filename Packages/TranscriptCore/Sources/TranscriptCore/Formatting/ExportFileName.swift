import Foundation

extension TranscriptExporter {
    /// A file or folder name for exporting a session, e.g.
    /// `2026-11-04 1402 Team meeting`. Safe on iOS, macOS and Windows.
    public static func suggestedFileName(
        for session: TranscriptSession,
        timeZone: TimeZone = .current,
        maxLength: Int = 80
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: session.startedAt)
        let stamp = String(
            format: "%04d-%02d-%02d %02d%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0
        )
        return sanitizedFileName("\(stamp) \(displayTitle(for: session))", maxLength: maxLength)
    }

    /// Replaces characters that aren't allowed in file names with spaces,
    /// collapses whitespace, removes leading/trailing dots and spaces, and
    /// limits the length. Returns `fallback` if nothing is left.
    public static func sanitizedFileName(_ name: String, maxLength: Int = 80, fallback: String = defaultTitle) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
            .union(.controlCharacters)
            .union(.whitespacesAndNewlines)
        var result = ""
        var pendingSpace = false
        for scalar in name.unicodeScalars {
            if invalid.contains(scalar) {
                pendingSpace = true
            } else {
                if pendingSpace, !result.isEmpty { result.append(" ") }
                pendingSpace = false
                result.unicodeScalars.append(scalar)
            }
        }
        let trimSet = CharacterSet(charactersIn: ". ")
        result = result.trimmingCharacters(in: trimSet)
        if result.count > maxLength {
            result = String(result.prefix(max(1, maxLength))).trimmingCharacters(in: trimSet)
        }
        return result.isEmpty ? fallback : result
    }
}
