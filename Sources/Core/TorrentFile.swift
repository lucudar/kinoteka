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
