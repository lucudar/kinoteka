import Foundation

struct TorrentFile: Identifiable, Hashable {
    let id: Int
    let path: String
    let length: Int64

    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
    var ext: String { (path as NSString).pathExtension.lowercased() }
    var isVideo: Bool { TorrentFile.videoExtensions.contains(ext) }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: length, countStyle: .file) }

    static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "avi", "mov", "ts", "m2ts", "mts", "wmv", "flv", "webm",
        "mpg", "mpeg", "vob", "3gp", "ogv", "divx", "rmvb", "asf"
    ]
}

extension TorrentFile {
    /// Video files of a torrent in episode order, without samples.
    static func playable(_ all: [TorrentFile]) -> [TorrentFile] {
        let videos = EpisodeMatcher.sorted(all.filter { $0.isVideo })
        let main = videos.filter { !($0.name.lowercased().contains("sample") && $0.length < 300_000_000) }
        return main.isEmpty ? videos : main
    }

    /// For movies: the file that takes most of the torrent (main feature vs extras).
    static func dominant(_ list: [TorrentFile]) -> TorrentFile? {
        let total = list.reduce(Int64(0)) { $0 + $1.length }
        guard total > 0, let largest = list.max(by: { $0.length < $1.length }) else { return nil }
        return Double(largest.length) >= Double(total) * 0.7 ? largest : nil
    }
}
