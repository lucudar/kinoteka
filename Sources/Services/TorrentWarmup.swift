import Foundation

/// Makes "Смотреть" start faster: while a film page is open, the release it will play is already
/// added to the torrent engine, so the metadata and the peers are ready by the time of the tap,
/// and the start and the end of the file are downloaded (the player reads the header there and
/// the index at the end before the first frame). Also frees the torrents that are no longer
/// needed when another one starts playing.
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
    /// Reading the start and the end of the file the page will play.
    private var readTask: Task<Void, Never>?
    private var readHash: String?
    /// "hash:file" being read or already read.
    private var readKey: String?

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKeys.prepareTorrent)
    }

    /// Adds the torrent of `link` to the engine without saving it and reads the start of
    /// the `target` file. Not while the player is open: it needs all the bandwidth.
    func prepare(link: String, title: String, poster: String?, target: WarmupTarget? = nil) async {
        guard isEnabled, LinkInspector.kind(of: link) == .torrent, !TorrServer.shared.isPlayerActive else { return }
        let raw = LinkInspector.stripMarker(link)
        generation += 1
        let current = generation
        do {
            // A page opened on another network retunes the engine before its torrent is added.
            try await TorrServer.shared.ensureRunning(retune: true)
        } catch {
            // Preparing is only a speed-up: playback will try again and show the error.
            return
        }
        guard current == generation, !Task.isCancelled else { return }
        if raw == warmLink, let hash = warmHash, let status = try? await TorrServer.shared.get(hash: hash) {
            guard current == generation else { return }
            pageHash = hash
            readAhead(hash: hash, files: status.files, target: target)
            return
        }
        do {
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
            readAhead(hash: hash, files: status.files, target: target)
        } catch {
            // Preparing is only a speed-up: playback will try again and show the error.
        }
    }

    /// Downloads the start and the end of the file the page will play (sizes by the network:
    /// nothing in Low Data Mode).
    private func readAhead(hash: String, files: [TorrentFile], target: WarmupTarget?) {
        guard let target = target else { return }
        let profile = TorrServer.shared.activeProfile ?? TorrServer.shared.desiredProfile
        let head = profile.warmupHead
        let tail = profile.warmupTail
        guard head > 0 else { return }
        if !files.isEmpty, let file = target.file(in: files), readKey == "\(hash):\(file.id)" { return }
        if readHash != hash { readKey = nil }
        readTask?.cancel()
        readHash = hash
        readTask = Task {
            var list = files
            if list.isEmpty {
                list = (try? await TorrServer.shared.waitForFiles(hash: hash, timeout: 60) { _ in }) ?? []
            }
            guard !Task.isCancelled, let file = target.file(in: list) else { return }
            let key = "\(hash):\(file.id)"
            guard key != readKey else { return }
            readKey = key
            let started = Date()
            let tailLength = file.length > head + tail ? tail : 0
            async let start = TorrServer.shared.readAhead(hash: hash, file: file, offset: 0, length: min(head, file.length))
            async let end = TorrServer.shared.readAhead(hash: hash, file: file, offset: file.length - tailLength, length: tailLength)
            let (startBytes, endBytes) = await (start, end)
            if Task.isCancelled {
                if readKey == key { readKey = nil }
                return
            }
            let seconds = Date().timeIntervalSince(started)
            AppDiagnostics.shared.log("torrent", "Заранее загружено: начало \(startBytes >> 20) МБ, конец \(endBytes >> 20) МБ за \(String(format: "%.1f", seconds)) с")
        }
    }

    /// Keeps the torrent of the open page from being closed by the engine.
    func keepAlive() async {
        guard let hash = pageHash else { return }
        _ = try? await TorrServer.shared.get(hash: hash)
    }

    /// Memory is low: the torrent prepared only in advance is closed. Playback adds it again when needed.
    func releaseUnused() {
        guard let hash = warmHash, hash != playingHash else { return }
        warmHash = nil
        warmLink = nil
        if pageHash == hash { pageHash = nil }
        generation += 1
        cancelReading()
        AppDiagnostics.shared.log("torrent", "Нехватка памяти: заранее подготовленная раздача закрыта")
        Task { await TorrServer.shared.drop(hash: hash) }
    }

    /// Playback of `hash` started: the torrent played before and the one prepared for
    /// another release are disconnected, so the new one gets all the bandwidth.
    func playbackStarted(hash: String) {
        let hash = hash.lowercased()
        var unused = Set<String>()
        if let previous = playingHash, previous != hash { unused.insert(previous) }
        if let warm = warmHash, warm != hash { unused.insert(warm) }
        // Reading ahead the same torrent ends by itself in a moment; another one is stopped.
        if readHash != hash { cancelReading() }
        playingHash = hash
        pageHash = hash
        warmHash = nil
        warmLink = nil
        for old in unused {
            Task { await TorrServer.shared.drop(hash: old) }
        }
    }

    /// The engine is about to be retuned and closes all its torrents: their reading stops now.
    func engineWillReset() {
        warmHash = nil
        warmLink = nil
        pageHash = nil
        playingHash = nil
        cancelReading()
    }

    private func cancelReading() {
        readTask?.cancel()
        readTask = nil
        readHash = nil
        readKey = nil
    }
}
