import Foundation

/// Which files of a torrent to download for a movie, an episode, a season or a whole series.
enum DownloadSelection {
    static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "smi"]
    static let audioExtensions: Set<String> = ["mka", "ac3", "eac3", "dts", "aac", "mp3", "flac", "ogg", "opus", "m4a", "wav"]

    static func files(_ all: [TorrentFile], isSeries: Bool, season: Int?, episode: Int?) -> [TorrentFile] {
        let playable = TorrentFile.playable(all)
        guard !playable.isEmpty else { return [] }
        if playable.count == 1 { return playable }
        guard isSeries else {
            if let main = TorrentFile.dominant(playable) { return [main] }
            return playable
        }
        if let episode {
            return EpisodeMatcher.find(in: playable, season: season, episode: episode).map { [$0] } ?? []
        }
        if let season {
            let numbered = playable.map { ($0, EpisodeMatcher.numbers(of: $0)?.season) }
            let inSeason = numbered.filter { $0.1 == season }.map(\.0)
            if !inSeason.isEmpty { return inSeason }
            let seasons = Set(numbered.compactMap(\.1))
            return seasons.isEmpty ? playable : []
        }
        return playable
    }

    /// Files stored next to a video with the same base name ("Movie.srt", "Movie.rus.ass").
    static func companions(for file: TorrentFile, in all: [TorrentFile], extensions: Set<String>) -> [TorrentFile] {
        let base = (file.name as NSString).deletingPathExtension.lowercased()
        guard base.count >= 3 else { return [] }
        return all.filter { $0.id != file.id && extensions.contains($0.ext) && $0.name.lowercased().hasPrefix(base) }
    }

    static func subtitles(for file: TorrentFile, in all: [TorrentFile]) -> [TorrentFile] {
        Array(companions(for: file, in: all, extensions: subtitleExtensions).prefix(8))
    }
}
