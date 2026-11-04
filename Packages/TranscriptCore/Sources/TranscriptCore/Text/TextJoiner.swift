import Foundation

/// Joins recognized phrases into readable text. English words need spaces
/// between them; Chinese (and other CJK text) does not.
public enum TextJoiner {
    public static func join<S: Sequence>(_ parts: S) -> String where S.Element == String {
        var result = ""
        for raw in parts {
            let part = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            if let last = result.unicodeScalars.last, let first = part.unicodeScalars.first,
               needsSpace(between: last, and: first) {
                result.append(" ")
            }
            result.append(part)
        }
        return result
    }

    static func needsSpace(between left: Unicode.Scalar, and right: Unicode.Scalar) -> Bool {
        if isCJK(left) || isCJK(right) { return false }
        if CharacterSet.whitespacesAndNewlines.contains(left) || CharacterSet.whitespacesAndNewlines.contains(right) {
            return false
        }
        if noSpaceBefore.contains(right) { return false }
        if noSpaceAfter.contains(left) { return false }
        return true
    }

    private static let noSpaceBefore: Set<Unicode.Scalar> = [
        ".", ",", "!", "?", ";", ":", ")", "]", "}", "%", "\u{201D}", "\u{2019}", "\u{2026}",
    ]
    private static let noSpaceAfter: Set<Unicode.Scalar> = ["(", "[", "{", "\u{201C}", "\u{2018}"]

    /// CJK ideographs, kana, CJK punctuation and full-width forms.
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F, // CJK symbols and punctuation
             0x3040...0x30FF, // Hiragana, Katakana
             0x3400...0x4DBF, // CJK Extension A
             0x4E00...0x9FFF, // CJK Unified Ideographs
             0xF900...0xFAFF, // CJK Compatibility Ideographs
             0xFF00...0xFFEF, // Half-width and full-width forms
             0x20000...0x2FA1F: // CJK Extensions B–F, compatibility supplement
            true
        default:
            false
        }
    }
}
