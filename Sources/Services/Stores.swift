import SwiftUI

// MARK: - Library (favorites, watched, history, sources, progress)

@MainActor
final class LibraryStore: ObservableObject {
    private(set) var data = LibraryData()
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("library.json")
        if let raw = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(LibraryData.self, from: raw) {
            data = decoded
        }
    }

    private func mutate(notify: Bool = true, _ change: (inout LibraryData) -> Void) {
        if notify { objectWillChange.send() }
        change(&data)
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    func persist() {
        if let raw = try? JSONEncoder().encode(data) {
            try? raw.write(to: fileURL, options: .atomic)
        }
    }

    // Favorites
    func isFavorite(_ item: MediaItem) -> Bool {
        data.favorites.contains { $0.id == item.id }
    }

    func toggleFavorite(_ item: MediaItem) {
        mutate { d in
            if let index = d.favorites.firstIndex(where: { $0.id == item.id }) {
                d.favorites.remove(at: index)
            } else {
                d.favorites.insert(item, at: 0)
            }
        }
    }

    func favorites(_ kind: MediaKind) -> [MediaItem] {
        data.favorites.filter { $0.kind == kind }
    }

    // Watched
    func isWatched(_ id: Int) -> Bool {
        data.watched.contains { $0.id == id }
    }

    func toggleWatched(_ item: MediaItem) {
        mutate { d in
            if let index = d.watched.firstIndex(where: { $0.id == item.id }) {
                d.watched.remove(at: index)
            } else {
                d.watched.insert(item, at: 0)
            }
        }
    }

    func markWatched(_ item: MediaItem) {
        guard !isWatched(item.id) else { return }
        mutate { d in d.watched.insert(item, at: 0) }
    }

    func watched(_ kind: MediaKind) -> [MediaItem] {
        data.watched.filter { $0.kind == kind }
    }

    // History of opened titles
    func addHistory(_ item: MediaItem) {
        if data.history.first == item { return }
        mutate { d in
            d.history.removeAll { $0.id == item.id }
            d.history.insert(item, at: 0)
            if d.history.count > 100 { d.history.removeLast(d.history.count - 100) }
        }
    }

    func clearHistory() {
        mutate { d in d.history.removeAll() }
    }

    // Sources (user supplied links per title)
    func sources(for key: String) -> [SavedSource] {
        data.sources[key] ?? []
    }

    func addSource(_ source: SavedSource, for key: String) {
        mutate { d in
            var list = d.sources[key] ?? []
            list.removeAll { $0.link == source.link }
            list.insert(source, at: 0)
            d.sources[key] = list
        }
    }

    func removeSource(_ id: UUID, for key: String) {
        mutate { d in
            var list = d.sources[key] ?? []
            list.removeAll { $0.id == id }
            d.sources[key] = list.isEmpty ? nil : list
        }
    }

    func removeSources(at offsets: IndexSet, for key: String) {
        mutate { d in
            var list = d.sources[key] ?? []
            list.remove(atOffsets: offsets)
            d.sources[key] = list.isEmpty ? nil : list
        }
    }

    // Playback positions (not published: updated often while playing)
    func resumePosition(for streamKey: String) -> Int32 {
        data.resume[streamKey] ?? 0
    }

    func setResume(_ ms: Int32, for streamKey: String) {
        mutate(notify: false) { d in
            if ms <= 0 {
                d.resume.removeValue(forKey: streamKey)
            } else {
                d.resume[streamKey] = ms
            }
        }
    }

    // Continue watching
    func continueEntry(for key: String) -> ContinueEntry? {
        data.continueWatching.first { $0.itemKey == key }
    }

    func updateContinue(_ entry: ContinueEntry) {
        mutate { d in
            d.continueWatching.removeAll { $0.itemKey == entry.itemKey }
            d.continueWatching.insert(entry, at: 0)
            if d.continueWatching.count > 30 { d.continueWatching.removeLast(d.continueWatching.count - 30) }
        }
    }

    func removeContinue(_ key: String) {
        mutate { d in d.continueWatching.removeAll { $0.itemKey == key } }
    }

    // TV channels
    func isFavoriteChannel(_ channel: Channel) -> Bool {
        data.favoriteChannels.contains { $0.url == channel.url }
    }

    func toggleFavoriteChannel(_ channel: Channel) {
        mutate { d in
            if let index = d.favoriteChannels.firstIndex(where: { $0.url == channel.url }) {
                d.favoriteChannels.remove(at: index)
            } else {
                d.favoriteChannels.append(channel)
            }
        }
    }

    func removeFavoriteChannels(at offsets: IndexSet) {
        mutate { d in d.favoriteChannels.remove(atOffsets: offsets) }
    }

    // Search queries
    func addQuery(_ query: String) {
        let q = query.trimmed
        guard q.count >= 2 else { return }
        mutate { d in
            d.recentQueries.removeAll { $0.lowercased() == q.lowercased() }
            d.recentQueries.insert(q, at: 0)
            if d.recentQueries.count > 15 { d.recentQueries.removeLast(d.recentQueries.count - 15) }
        }
    }

    func removeQuery(_ query: String) {
        mutate { d in d.recentQueries.removeAll { $0 == query } }
    }

    func clearQueries() {
        mutate { d in d.recentQueries.removeAll() }
    }
}

// MARK: - TV channels from a user M3U playlist

@MainActor
final class ChannelsStore: ObservableObject {
    static let localMarker = "local:playlist.m3u"

    @Published private(set) var channels: [Channel] = []
    @Published private(set) var groups: [String] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private(set) var loadedSource: String?

    private var localFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("playlist.m3u")
    }

    private var cacheFile: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("playlist-cache.m3u")
    }

    private var currentSource: String {
        (UserDefaults.standard.string(forKey: SettingsKeys.playlistURL) ?? "").trimmed
    }

    private func apply(_ list: [Channel], source: String) {
        channels = list
        var seen = Set<String>()
        groups = list.compactMap { $0.group }.filter { !$0.isEmpty && seen.insert($0).inserted }
        loadedSource = source
    }

    func clear() {
        channels = []
        groups = []
        error = nil
        loadedSource = nil
    }

    func loadIfNeeded() async {
        let source = currentSource
        if source.isEmpty {
            clear()
            return
        }
        if loadedSource == source && !channels.isEmpty { return }
        await load(source)
    }

    func reload() async {
        let source = currentSource
        guard !source.isEmpty else { return }
        await load(source)
    }

    private func load(_ source: String) async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        if source == ChannelsStore.localMarker {
            guard let raw = try? Data(contentsOf: localFile) else {
                error = "Файл плейлиста не найден. Выберите его заново."
                return
            }
            finish(raw, source: source, cache: false)
            return
        }
        guard let url = URL(string: source), url.scheme != nil else {
            error = "Некорректная ссылка на плейлист."
            return
        }
        do {
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            let (raw, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw APIError.http(http.statusCode)
            }
            finish(raw, source: source, cache: true)
        } catch {
            if let cached = try? Data(contentsOf: cacheFile) {
                finish(cached, source: source, cache: false)
                if channels.isEmpty { self.error = error.localizedDescription }
            } else {
                self.error = "Не удалось загрузить плейлист: \(error.localizedDescription)"
            }
        }
    }

    private func finish(_ raw: Data, source: String, cache: Bool) {
        let text = String(decoding: raw, as: UTF8.self)
        let list = M3UParser.parse(text)
        if list.isEmpty {
            error = "В плейлисте не найдено каналов."
            return
        }
        if cache { try? raw.write(to: cacheFile, options: .atomic) }
        apply(list, source: source)
    }

    /// Imports a playlist file picked in the Files app.
    func importFile(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let raw = try? Data(contentsOf: url) else {
            error = "Не удалось прочитать файл."
            return false
        }
        let list = M3UParser.parse(String(decoding: raw, as: UTF8.self))
        guard !list.isEmpty else {
            error = "В файле не найдено каналов."
            return false
        }
        try? raw.write(to: localFile, options: .atomic)
        error = nil
        apply(list, source: ChannelsStore.localMarker)
        return true
    }
}

// MARK: - Player presentation

struct PlayRequest: Identifiable {
    let id = UUID()
    var title: String
    var link: String
    var itemKey: String? = nil
    var item: MediaItem? = nil
    var preferredFileId: Int? = nil
    var season: Int? = nil
    var episode: Int? = nil
    var isLive: Bool = false
    var userAgent: String? = nil
    var referrer: String? = nil
    /// Start from this position (ms) instead of the saved one: the same film in another release.
    var startTime: Int32? = nil
    /// Release-level voice choice to apply to a matching VLC audio track after startup.
    var preferredAudio: String? = nil
}

extension PlayRequest {
    /// "Продолжить": the same file (or the same episode) of the release watched before.
    init(continuing entry: ContinueEntry, item: MediaItem? = nil) {
        self.init(title: entry.title, link: entry.link, itemKey: entry.itemKey, item: item ?? entry.item,
                  preferredFileId: entry.fileId, season: entry.season, episode: entry.episode)
    }
}

@MainActor
final class PlayerCoordinator: ObservableObject {
    @Published var request: PlayRequest?

    func play(_ request: PlayRequest, delay: Double = 0) {
        guard delay > 0 else {
            self.request = request
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self?.request = request
        }
    }
}
