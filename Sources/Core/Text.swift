import Foundation

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    var capitalizedFirst: String {
        guard let first = first else { return self }
        return String(first).uppercased() + String(dropFirst())
    }

    /// nil when the string is empty after trimming.
    var nonEmpty: String? {
        let value = trimmed
        return value.isEmpty ? nil : value
    }
}

/// Cached, thread-safe regular expressions with a tiny helper API.
enum Rx {
    nonisolated(unsafe) private static var cache: [String: NSRegularExpression] = [:] // guarded by `lock`
    private static let lock = NSLock()

    static func regex(_ pattern: String, caseSensitive: Bool = false) -> NSRegularExpression? {
        let key = (caseSensitive ? "s|" : "i|") + pattern
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        guard let created = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        cache[key] = created
        return created
    }

    static func matches(_ pattern: String, in text: String, caseSensitive: Bool = false) -> Bool {
        guard let regex = regex(pattern, caseSensitive: caseSensitive) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Capture groups of the first match; groups that did not participate are "".
    static func groups(_ pattern: String, in text: String, caseSensitive: Bool = false) -> [String]? {
        guard let regex = regex(pattern, caseSensitive: caseSensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return captures(of: match, in: text)
    }

    /// Capture groups of every match.
    static func allGroups(_ pattern: String, in text: String, caseSensitive: Bool = false) -> [[String]] {
        guard let regex = regex(pattern, caseSensitive: caseSensitive) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { captures(of: $0, in: text) }
    }

    private static func captures(of match: NSTextCheckingResult, in text: String) -> [String] {
        var result: [String] = []
        guard match.numberOfRanges > 1 else { return result }
        for index in 1..<match.numberOfRanges {
            let range = match.range(at: index)
            if range.location != NSNotFound, let bounds = Range(range, in: text) {
                result.append(String(text[bounds]))
            } else {
                result.append("")
            }
        }
        return result
    }
}

enum TextMatch {
    /// Lowercased letters and digits separated by single spaces; "ё" becomes "е".
    static func normalized(_ text: String) -> String {
        let lowered = text.lowercased().replacingOccurrences(of: "ё", with: "е")
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingSpace && !scalars.isEmpty { scalars.append(" ") }
                scalars.append(scalar)
                pendingSpace = false
            } else {
                pendingSpace = true
            }
        }
        return String(scalars)
    }

    /// True when `phrase` occurs in `text` as whole words (both normalized).
    static func containsPhrase(_ text: String, _ phrase: String) -> Bool {
        let needle = normalized(phrase)
        guard !needle.isEmpty else { return false }
        return (" " + normalized(text) + " ").contains(" " + needle + " ")
    }
}

/// Matches a release-level voice choice to VLC's audio-track names.
enum AudioTrackMatcher {
    static func best(in tracks: [String], preferred: String) -> Int? {
        let wanted = TextMatch.normalized(preferred)
        guard !wanted.isEmpty else { return nil }
        let aliases = aliasWords(for: wanted)
        return tracks.enumerated().max { lhs, rhs in
            score(lhs.element, wanted: wanted, aliases: aliases) < score(rhs.element, wanted: wanted, aliases: aliases)
        }.flatMap { score($0.element, wanted: wanted, aliases: aliases) > 0 ? $0.offset : nil }
    }

    private static func score(_ track: String, wanted: String, aliases: [String]) -> Int {
        let normalized = TextMatch.normalized(track)
        if normalized == wanted { return 100 }
        if normalized.contains(wanted) { return 80 }
        for alias in aliases where TextMatch.containsPhrase(normalized, alias) {
            return 60
        }
        return 0
    }

    private static func aliasWords(for wanted: String) -> [String] {
        switch wanted {
        case TextMatch.normalized(VoiceKind.dub.title):
            return ["дуб", "дублированный", "dub"]
        case TextMatch.normalized(VoiceKind.multi.title):
            return ["многоголосый", "многоголосный", "mvo", "multi voice"]
        case TextMatch.normalized(VoiceKind.two.title):
            return ["двухголосый", "двухголосный", "dvo", "two voice"]
        case TextMatch.normalized(VoiceKind.single.title):
            return ["одноголосый", "одноголосный", "vo", "single voice"]
        case TextMatch.normalized(VoiceKind.author.title):
            return ["авторский", "avo", "author"]
        case TextMatch.normalized(VoiceKind.amateur.title):
            return ["любительский", "amateur"]
        default:
            return []
        }
    }
}
