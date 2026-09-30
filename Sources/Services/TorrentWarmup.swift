import Foundation

/// Makes "Смотреть" start faster: while a film page is open, the release it will play is already
/// added to the torrent engine, so the metadata and the peers are ready by the time of the tap.
/// Also frees the torrents that are no longer needed when another one starts playing.
@MainActor
final class TorrentWarmup {
    static let shared = TorrentWarmup()

    /// Torrent added only in advance: nothing has played it.
    private var warmHash: String?
    private var warmLink: String?
    /// Torrent of the page that is open now (prepared or played before).
    private var pageHash: String?
    /// Torrent of the last playback. It stays connected for a while after the player closes,
    /// so reopening the film or the next episode starts without reconnecting.
    private(set) var playingHash: String?
    private var generation = 0

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKeys.prepareTorrent)
    }

    /// Adds the torrent of `link` to the engine without saving it.
    func prepare(link: String, title: String, poster: String?) async {
        guard isEnabled, LinkInspector.kind(of: link) == .torrent else { return }
        let raw = LinkInspector.stripMarker(link)
        generation += 1
        let current = generation
        if raw == warmLink, let hash = warmHash {
            pageHash = hash
            _ = try? await TorrServer.shared.get(hash: hash)
            return
        }
        do {
            try await TorrServer.shared.ensureRunning()
            let status = try await TorrServer.shared.add(link: raw, title: title, poster: poster, saveToDB: false)
            guard let hash = status.hash?.lowercased(), !hash.isEmpty else { return }
            guard current == generation, !Task.isCancelled else {
                // Another page asked for its torrent meanwhile.
                if hash != warmHash, hash != playingHash, hash != pageHash {
                    await TorrServer.shared.drop(hash: hash)
                }
                return
            }
            let previous = warmHash
            pageHash = hash
            if hash == playingHash {
                warmHash = nil
                warmLink = nil
            } else {
                warmHash = hash
                warmLink = raw
            }
            if let previous = previous, previous != hash, previous != playingHash {
                await TorrServer.shared.drop(hash: previous)
            }
        } catch {
            // Preparing is only a speed-up: playback will try again and show the error.
        }
    }

    /// Keeps the torrent of the open page from being closed by the engine.
    func keepAlive() async {
        guard let hash = pageHash else { return }
        _ = try? await TorrServer.shared.get(hash: hash)
    }

    /// Playback of `hash` started: the torrent played before and the one prepared for
    /// another release are disconnected, so the new one gets all the bandwidth.
    func playbackStarted(hash: String) {
        let hash = hash.lowercased()
        var unused = Set<String>()
        if let previous = playingHash, previous != hash { unused.insert(previous) }
        if let warm = warmHash, warm != hash { unused.insert(warm) }
        playingHash = hash
        pageHash = hash
        warmHash = nil
        warmLink = nil
        for old in unused {
            Task { await TorrServer.shared.drop(hash: old) }
        }
    }
}
