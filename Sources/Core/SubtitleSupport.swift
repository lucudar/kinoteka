import Foundation

// MARK: - OpenSubtitles file hash

/// OpenSubtitles "moviehash": the file size plus the sums of the first and the last 64 KB
/// read as little-endian 64-bit words. Lets the service find subtitles synced to this exact file.
enum OpenSubtitlesHash {
    static let chunkSize = 65_536

    static func compute(fileSize: Int64, head: Data, tail: Data) -> String? {
        guard fileSize >= Int64(chunkSize), head.count >= chunkSize, tail.count >= chunkSize else { return nil }
        var hash = UInt64(bitPattern: fileSize)
        hash = hash &+ sum(Data(head.prefix(chunkSize)))
        hash = hash &+ sum(Data(tail.suffix(chunkSize)))
        return String(format: "%016llx", hash)
    }

    private static func sum(_ data: Data) -> UInt64 {
        let bytes = [UInt8](data)
        var total: UInt64 = 0
        var index = 0
        while index + 8 <= bytes.count {
            var word: UInt64 = 0
            for k in 0..<8 { word |= UInt64(bytes[index + k]) << UInt64(8 * k) }
            total = total &+ word
            index += 8
        }
        return total
    }
}

// MARK: - Language of audio and subtitle tracks

enum TrackLanguage {
    enum Guess: Equatable { case russian, foreign, unknown }

    private static let russianTokens: Set<String> = [
        "ru", "rus", "russian", "mvo", "dvo", "avo", "lostfilm", "newstudio", "amedia", "jaskier",
        "hdrezka", "rezka", "baibako", "coldfilm", "alexfilm", "ideafilm", "novamedia", "tvshows",
        "kubik", "kubikvkube", "pozitiv", "hdrezkastudio", "syncmovies"
    ]
    private static let ukrainianTokens: Set<String> = ["ukr", "ukrainian", "ua", "укр", "украинский", "українська"]
    private static let ukrainianLetters = CharacterSet(charactersIn: "іїєґІЇЄҐ")

    /// Names VLC gives to unlabeled tracks: "Track 1", "Дорожка 2", "Audio 1".
    private static let genericPattern = "^(track|дорожка|audio|аудио|subtitle|субтитры|stream)?[ _#-]*\\d*$"

    static func guess(_ name: String) -> Guess {
        let lower = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = Set(lower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        if !tokens.isDisjoint(with: ukrainianTokens) || lower.rangeOfCharacter(from: ukrainianLetters) != nil {
            return .foreign
        }
        if lower.range(of: genericPattern, options: .regularExpression) != nil { return .unknown }
        if lower.range(of: "[а-яё]", options: .regularExpression) != nil { return .russian }
        if !tokens.isDisjoint(with: russianTokens) { return .russian }
        return .foreign
    }

    static func looksRussian(_ name: String) -> Bool { guess(name) == .russian }

    /// Whether subtitles are worth searching for automatically: nothing Russian among
    /// the subtitles, and the audio is known to be foreign (labeled, none Russian).
    static func needsSubtitles(audio: [String], subtitles: [String]) -> Bool {
        if subtitles.contains(where: looksRussian) { return false }
        let guesses = audio.map(guess)
        guard !guesses.isEmpty, !guesses.contains(.russian) else { return false }
        return guesses.contains(.foreign)
    }
}

// MARK: - Found subtitles

struct SubtitleCandidate: Identifiable, Hashable {
    let fileId: Int
    let language: String
    let release: String
    let fileName: String
    let downloads: Int
    let hearingImpaired: Bool
    let machineTranslated: Bool
    let hashMatch: Bool
    let season: Int?
    let episode: Int?

    var id: Int { fileId }
}

enum SubtitleRanking {
    /// Words of a release name that tell versions apart: resolution, source, group.
    static func tokens(_ text: String) -> Set<String> {
        let ignored: Set<String> = ["the", "and", "rus", "eng", "sub", "subs", "srt", "mkv", "mp4", "avi", "x264", "x265", "h264", "h265", "hevc", "aac", "ac3"]
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !ignored.contains($0) && Int($0) == nil }
        return Set(words)
    }

    static func score(_ candidate: SubtitleCandidate, release: Set<String>) -> Double {
        var value = 0.0
        if candidate.hashMatch { value += 1_000 }
        let overlap = tokens(candidate.release + " " + candidate.fileName).intersection(release).count
        value += Double(min(overlap, 6)) * 40
        value += log10(Double(max(candidate.downloads, 0)) + 1) * 10
        if candidate.hearingImpaired { value -= 15 }
        if candidate.machineTranslated { value -= 300 }
        return value
    }

    /// Preferred language first, then the version closest to the playing file.
    static func sorted(_ list: [SubtitleCandidate], languages: [String], releaseName: String?,
                       season: Int? = nil, episode: Int? = nil) -> [SubtitleCandidate] {
        let release = tokens(releaseName ?? "")
        let filtered = list.filter { candidate in
            if let episode, let found = candidate.episode, found != episode { return false }
            if let season, let found = candidate.season, found != season { return false }
            return true
        }
        func rank(_ language: String) -> Int {
            languages.firstIndex(where: { language.lowercased().hasPrefix($0.lowercased()) }) ?? languages.count
        }
        return filtered.sorted { a, b in
            let ra = rank(a.language), rb = rank(b.language)
            if ra != rb { return ra < rb }
            let sa = score(a, release: release), sb = score(b, release: release)
            if sa != sb { return sa > sb }
            return a.fileId < b.fileId
        }
    }
}

// MARK: - HTTP ranges

enum HTTPRange {
    /// Total size from "Content-Range: bytes 0-99/1234".
    static func total(fromContentRange header: String?) -> Int64? {
        guard let header, let slash = header.lastIndex(of: "/") else { return nil }
        return Int64(header[header.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    /// Start offset from "Content-Range: bytes 100-199/1234".
    static func start(fromContentRange header: String?) -> Int64? {
        guard let header else { return nil }
        let body = header.replacingOccurrences(of: "bytes", with: "").trimmingCharacters(in: .whitespaces)
        guard let dash = body.firstIndex(of: "-") else { return nil }
        return Int64(body[..<dash])
    }
}
