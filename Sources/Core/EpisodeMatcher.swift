import Foundation

// MARK: - Episode matching in torrent file names

enum EpisodeMatcher {
    private static let pairedPatterns = [
        "s(\\d{1,2})[ ._-]*e(\\d{1,3})",
        "(?<!\\d)(\\d{1,2})x(\\d{1,3})(?!\\d)",
        "season[ ._-]*(\\d{1,2}).*?episode[ ._-]*(\\d{1,3})",
        "(\\d{1,2})[ ._-]*сезон.*?(\\d{1,3})[ ._-]*сери",
        "сезон[ ._-]*(\\d{1,2}).*?(\\d{1,3})[ ._-]*сери",
        "сезон[ ._-]*(\\d{1,2}).*?сери[яи]?[ ._-]*(\\d{1,3})"
    ]

    private static let singlePatterns = [
        "(?<![a-zа-я])(?:ep|e)[ ._-]?(\\d{1,3})(?!\\d)",
        "(\\d{1,3})[ ._-]*(?:серия|seriya|series)",
        "(?:серия|seriya|episode)[ ._-]*(\\d{1,3})",
        "^(\\d{1,3})(?!\\d)"
    ]

    private static let folderPatterns = [
        "season[ ._-]*(\\d{1,2})",
        "(?<![a-z])s(\\d{1,2})(?!\\d)",
        "(\\d{1,2})[ ._-]*сезон",
        "сезон[ ._-]*(\\d{1,2})"
    ]

    /// Season and episode numbers parsed from a file name.
    static func parse(_ path: String) -> (season: Int?, episode: Int)? {
        let name = (path as NSString).lastPathComponent
        for pattern in pairedPatterns {
            if let g = Rx.groups(pattern, in: name), g.count >= 2, let s = Int(g[0]), let e = Int(g[1]) {
                return (s, e)
            }
        }
        for pattern in singlePatterns {
            if let g = Rx.groups(pattern, in: name), let first = g.first, let e = Int(first) {
                return (nil, e)
            }
        }
        return nil
    }

    /// Season number mentioned in the folder part of the path ("Season 2", "S02", "2 сезон").
    static func folderSeason(_ path: String) -> Int? {
        let folder = (path as NSString).deletingLastPathComponent
        guard !folder.isEmpty else { return nil }
        for pattern in folderPatterns {
            if let g = Rx.groups(pattern, in: folder), let first = g.first, let s = Int(first) { return s }
        }
        return nil
    }

    /// Season (from the name or the folders) and episode of a file.
    static func numbers(of file: TorrentFile) -> (season: Int?, episode: Int)? {
        guard let parsed = parse(file.path) else { return nil }
        return (parsed.season ?? folderSeason(file.path), parsed.episode)
    }

    static func find(in files: [TorrentFile], season: Int?, episode: Int) -> TorrentFile? {
        let parsed = files.map { file -> (TorrentFile, Int?, Int?) in
            let p = numbers(of: file)
            return (file, p?.season, p?.episode)
        }
        if let season = season,
           let exact = parsed.first(where: { $0.1 == season && $0.2 == episode }) {
            return exact.0
        }
        let seasons = Set(parsed.compactMap { $0.1 })
        if seasons.count <= 1, let loose = parsed.first(where: { $0.2 == episode }) {
            return loose.0
        }
        return nil
    }

    static func sorted(_ files: [TorrentFile]) -> [TorrentFile] {
        files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// The file to play after `current`: the next episode number of the same season
    /// (the same folder first, so the dub and quality stay the same), then the first
    /// episode of the next season, and for files without numbers the next file of the folder.
    static func next(after current: TorrentFile, in files: [TorrentFile]) -> TorrentFile? {
        let others = sorted(files).filter { $0.id != current.id }
        let folder = current.folder
        let parent = (folder as NSString).deletingLastPathComponent

        guard let now = numbers(of: current) else {
            let siblings = sorted(files).filter { $0.folder == folder }
            guard let index = siblings.firstIndex(of: current), index + 1 < siblings.count else { return nil }
            return siblings[index + 1]
        }

        let numbered = others.compactMap { file -> (file: TorrentFile, season: Int?, episode: Int)? in
            guard let n = numbers(of: file) else { return nil }
            return (file, n.season, n.episode)
        }

        let later = numbered.filter { $0.season == now.season && $0.episode > now.episode }
        if let episode = later.map({ $0.episode }).min() {
            let options = later.filter { $0.episode == episode }.map { $0.file }
            return options.first { $0.folder == folder } ?? options.first
        }

        guard let season = now.season else { return nil }
        let following = numbered.filter { ($0.season ?? 0) > season }
        guard let nextSeason = following.compactMap({ $0.season }).min() else { return nil }
        let inSeason = following.filter { $0.season == nextSeason }
        guard let episode = inSeason.map({ $0.episode }).min() else { return nil }
        let options = inSeason.filter { $0.episode == episode }.map { $0.file }
        return options.first { ($0.folder as NSString).deletingLastPathComponent == parent } ?? options.first
    }
}
