import Foundation

/// Kinopoisk writes the type and the years into some names of a person's films:
/// "Во все тяжкие (сериал, 2008 – 2013)", "Breaking Bad (TV Series 2008–2013)", "Начало (2010)".
enum KinopoiskName {
    private static let markers: Set<String> = ["сериал", "series", "видео", "video", "тв", "tv"]

    static func split(_ name: String) -> (title: String, isSeries: Bool, year: Int?) {
        let text = name.trimmed
        guard text.hasSuffix(")"), let open = text.range(of: " (", options: .backwards) else {
            return (text, false, nil)
        }
        let inside = text[open.upperBound..<text.index(before: text.endIndex)].lowercased()
        let words = Set(inside.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
        let isSeries = words.contains("сериал") || words.contains("series")
        var year: Int?
        if let match = inside.range(of: "(18|19|20)[0-9]{2}", options: .regularExpression) {
            year = Int(inside[match])
        }
        guard year != nil || !words.isDisjoint(with: markers) else { return (text, false, nil) }
        let title = String(text[..<open.lowerBound]).trimmed
        return (title.isEmpty ? text : title, isSeries, year)
    }
}

enum Plural {
    /// Russian plural forms: 1 год, 2 года, 5 лет.
    static func ru(_ value: Int, _ one: String, _ few: String, _ many: String) -> String {
        let n = abs(value) % 100
        let last = n % 10
        let word: String
        if n >= 11 && n <= 14 {
            word = many
        } else if last == 1 {
            word = one
        } else if last >= 2 && last <= 4 {
            word = few
        } else {
            word = many
        }
        return "\(value) \(word)"
    }
}
