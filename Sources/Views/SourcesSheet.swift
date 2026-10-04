import SwiftUI
import UIKit

/// "Раздачи" of a film or series: torrents found automatically (like in Zona),
/// the sources watched before and a manual link.
struct SourcesSheet: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject private var network = NetworkMonitor.shared
    @AppStorage(SettingsKeys.preferredQuality) private var preferredRaw = ReleaseQuality.fullHD.rawValue
    @AppStorage(SettingsKeys.smartQuality) private var smartQuality = true
    @AppStorage(SettingsKeys.searchServer) private var server = TorrentSearchService.defaultServer

    let item: MediaItem
    var episode: KPEpisode? = nil
    var seasonNumbers: [Int] = []
    /// Quality picked on the film page: the list opens filtered by it.
    var initialQuality: ReleaseQuality? = nil
    /// Voice picked on the film page: the list opens filtered by it.
    var initialVoice: ReleaseVoiceOption? = nil

    private enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    @State private var state: LoadState = .loading
    @State private var releases: [TorrentRelease] = []
    @State private var found = 0
    /// The search mirror that answered.
    @State private var answeredServer: String?
    @State private var season: Int?
    @State private var quality: ReleaseQuality?
    @State private var voice: ReleaseVoiceOption?
    @State private var order: ReleaseSort = .seeders
    @State private var searchText = ""
    @State private var customQuery: String?
    @State private var loadToken = 0
    @State private var didStart = false

    private var isSeries: Bool { item.kind == .series }
    private var preferred: ReleaseQuality {
        PlaybackPolicy.effectiveQuality(ReleaseQuality(rawValue: preferredRaw) ?? .fullHD,
                                        connection: network.connection,
                                        smart: smartQuality)
    }

    private var sources: [SavedSource] {
        let all = library.sources(for: item.key)
        guard let episode = episode else { return all }
        return all.filter { $0.covers(season: episode.seasonNumber) }
    }

    private var query: TorrentSearchQuery {
        TorrentSearchQuery(title: item.title, originalTitle: item.originalTitle, year: item.year,
                           isSeries: isSeries, custom: customQuery)
    }

    private var seasonOptions: [Int] {
        guard isSeries else { return [] }
        if !seasonNumbers.isEmpty { return Array(Set(seasonNumbers)).sorted() }
        return Array(Set(releases.flatMap { $0.seasons })).sorted()
    }

    private var qualityOptions: [ReleaseQuality] {
        let candidates = ReleaseRanking.matching(availableReleases, voice: voice)
        let present = Set(candidates.map { $0.quality })
        return ReleaseQuality.choices.filter { present.contains($0) }
    }

    private var voiceOptions: [ReleaseVoiceOption] {
        var candidates = ReleaseRanking.matching(availableReleases, season: season)
        if let quality = quality { candidates = candidates.filter { $0.quality == quality } }
        return ReleaseRanking.voiceOptions(candidates)
    }

    private var availableReleases: [TorrentRelease] {
        library.allowedReleases(releases)
    }

    private var filtered: [TorrentRelease] {
        var list = availableReleases
        if let season = season {
            list = list.filter { $0.seasons.isEmpty || $0.seasons.contains(season) }
        }
        if let quality = quality {
            list = list.filter { $0.quality == quality }
        }
        list = ReleaseRanking.matching(list, voice: voice)
        return ReleaseRanking.sorted(list, by: order)
    }

    private var serverHost: String {
        if let answered = answeredServer.flatMap(SearchMirrors.host) { return answered }
        let base = TorrentSearchQuery.normalizedServer(server) ?? TorrentSearchService.defaultServer
        return URL(string: base)?.host ?? base
    }

    var body: some View {
        let list = filtered
        let best = PlaybackLearning.shared.best(list, preferred: preferred, season: season, voice: voice)
        let saved = Set(library.sources(for: item.key).map { $0.link })
        NavigationStack {
            List {
                if let episode = episode {
                    Section {
                        Label("\(episode.seasonNumber) сезон, \(episode.episodeNumber) серия — выберите раздачу",
                              systemImage: "play.rectangle")
                            .font(.subheadline)
                    }
                }
                if customQuery == nil && !sources.isEmpty {
                    savedSection
                }
                if !availableReleases.isEmpty && (seasonOptions.count > 1 || qualityOptions.count > 1 || !voiceOptions.isEmpty) {
                    filtersSection
                }
                results(list: list, best: best, saved: saved)
                Section {
                    NavigationLink {
                        ManualSourceView { source in
                            library.addSource(source, for: item.key)
                            play(source)
                        }
                    } label: {
                        Label("Добавить свою ссылку", systemImage: "link.badge.plus")
                    }
                } footer: {
                    Text(footerText)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Раздачи")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Свой запрос: название, год, студия")
            .onSubmit(of: .search) { submitSearch() }
            .onChange(of: searchText) { _, text in
                if text.trimmed.isEmpty && customQuery != nil {
                    customQuery = nil
                    startSearch()
                }
            }
            .onChange(of: voice) { _, _ in
                if let current = quality, !qualityOptions.contains(current) { quality = nil }
            }
            .onChange(of: quality) { _, _ in
                if let current = voice, !voiceOptions.contains(current) { voice = nil }
            }
            .refreshable { await load(force: true) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Сортировка", selection: $order) {
                            ForEach(ReleaseSort.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down.circle")
                    }
                }
            }
            .task {
                if !didStart {
                    didStart = true
                    season = episode?.seasonNumber
                    quality = initialQuality
                    voice = initialVoice
                }
                // Also restarts a search that was cancelled while "Своя ссылка" was open.
                if state == .loading {
                    await load()
                }
            }
        }
    }

    // MARK: Sections

    private var savedSection: some View {
        Section {
            ForEach(sources) { source in
                Button {
                    play(source)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.title)
                                .font(.subheadline)
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text(source.info ?? LinkInspector.kindText(source.link))
                                .font(.caption)
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "play.fill")
                            .foregroundStyle(Theme.accent)
                    }
                    .contentShape(Rectangle())
                }
                .swipeActions {
                    Button(role: .destructive) {
                        library.removeSource(source.id, for: item.key)
                    } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                }
            }
        } header: {
            Text("Вы смотрели")
        }
    }

    private var filtersSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                if seasonOptions.count > 1 {
                    chipRow {
                        Chip(title: "Все сезоны", selected: season == nil) { season = nil }
                        ForEach(seasonOptions, id: \.self) { number in
                            Chip(title: "\(number) сезон", selected: season == number) { season = number }
                        }
                    }
                }
                if qualityOptions.count > 1 {
                    chipRow {
                        Chip(title: "Любое качество", selected: quality == nil) { quality = nil }
                        ForEach(qualityOptions) { option in
                            Chip(title: option.title, selected: quality == option) { quality = option }
                        }
                    }
                }
                if !voiceOptions.isEmpty {
                    chipRow {
                        Chip(title: "Любая озвучка", selected: voice == nil) { voice = nil }
                        ForEach(voiceOptions) { option in
                            Chip(title: option.title, selected: voice == option) { voice = option }
                        }
                    }
                }
            }
            .padding(.vertical, 6)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    private func chipRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                content()
            }
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private func results(list: [TorrentRelease], best: TorrentRelease?, saved: Set<String>) -> some View {
        switch state {
        case .loading:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(loadingText)
                        .foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }
        case .failed(let message):
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.title)
                        .foregroundStyle(Theme.secondary)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                    Button("Повторить") { startSearch() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        case .loaded:
            if releases.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.title)
                            .foregroundStyle(Theme.secondary)
                        Text("Раздачи не найдены")
                            .font(.headline)
                        Text(emptyHint)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
            } else if list.isEmpty {
                Section {
                    if availableReleases.isEmpty && !releases.isEmpty {
                        Text("Все найденные раздачи скрыты.")
                            .foregroundStyle(Theme.secondary)
                        Button("Вернуть скрытые раздачи") {
                            library.clearBlockedReleases()
                        }
                    } else {
                        Text("Нет раздач с выбранными фильтрами.")
                            .foregroundStyle(Theme.secondary)
                        Button("Сбросить фильтры") {
                            season = nil
                            quality = nil
                            voice = nil
                        }
                    }
                }
            } else {
                if let best = best {
                    Section {
                        releaseButton(best, highlighted: true, saved: saved)
                    } header: {
                        Label("Лучший вариант", systemImage: "star.fill")
                    }
                }
                Section {
                    ForEach(list) { release in
                        releaseButton(release, highlighted: false, saved: saved)
                    }
                } header: {
                    Text("Все раздачи · \(list.count)")
                }
            }
        }
    }

    private func releaseButton(_ release: TorrentRelease, highlighted: Bool, saved: Set<String>) -> some View {
        Button {
            play(release)
        } label: {
            ReleaseRow(release: release, highlighted: highlighted,
                       watched: saved.contains(LinkInspector.markTorrent(release.link)))
        }
        .contextMenu {
            Button {
                play(release)
            } label: {
                Label("Смотреть", systemImage: "play.fill")
            }
            if let page = release.detailsURL.flatMap({ URL(string: $0) }) {
                Button {
                    openURL(page)
                } label: {
                    Label("Страница раздачи", systemImage: "safari")
                }
            }
            Button {
                UIPasteboard.general.string = release.link
            } label: {
                Label("Скопировать ссылку", systemImage: "doc.on.doc")
            }
            Button(role: .destructive) {
                library.blockRelease(release)
                if let source = library.sources(for: item.key).first(where: {
                    LinkInspector.markTorrent($0.link) == LinkInspector.markTorrent(release.link)
                }) {
                    library.removeSource(source.id, for: item.key)
                }
            } label: {
                Label("Не предлагать эту раздачу", systemImage: "hand.thumbsdown")
            }
        }
    }

    private var loadingText: String {
        if let text = customQuery { return "Ищем «\(text)»…" }
        return "Ищем раздачи…"
    }

    private var emptyHint: String {
        if found > 0 {
            return "Сервер нашёл \(found), но ни одна раздача не совпала с названием и годом. Попробуйте свой запрос в строке поиска."
        }
        return "Попробуйте другой запрос в строке поиска (например, оригинальное название) или добавьте свою ссылку."
    }

    private var footerText: String {
        var text = "Раздачи ищутся на \(serverHost) по названию и году. Потяните список вниз, чтобы обновить."
        if state == .loaded && !releases.isEmpty {
            let hidden = releases.count - availableReleases.count
            text = "Найдено: \(releases.count)." + (hidden > 0 ? " Скрыто: \(hidden)." : "") + " " + text
        }
        return text + " Подходят и свои magnet-ссылки, .torrent и прямые ссылки на видео."
    }

    // MARK: Search

    private func submitSearch() {
        let text = searchText.trimmed
        guard !text.isEmpty, text != customQuery else { return }
        customQuery = text
        quality = nil
        if episode == nil { season = nil }
        startSearch()
    }

    private func startSearch() {
        releases = []
        found = 0
        state = .loading
        Task { await load() }
    }

    private func load(force: Bool = false) async {
        loadToken += 1
        let token = loadToken
        let request = query
        do {
            let result = try await TorrentSearchService.shared.search(request, force: force)
            guard token == loadToken else { return }
            releases = result.releases
            found = result.found
            answeredServer = result.server
            state = .loaded
            if let current = quality, !result.releases.contains(where: { $0.quality == current }) {
                quality = nil
            }
            if let current = voice,
               !ReleaseRanking.voiceOptions(result.releases, season: season).contains(current) {
                voice = nil
            }
        } catch is CancellationError {
            return
        } catch {
            guard token == loadToken else { return }
            if releases.isEmpty {
                state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Playback

    private func play(_ release: TorrentRelease) {
        let source = SavedSource(release: release)
        library.addSource(source, for: item.key)
        play(source, release: release)
    }

    private func play(_ source: SavedSource, release: TorrentRelease? = nil) {
        var request = PlayRequest(title: item.title, link: source.link, itemKey: item.key, item: item,
                                  preferredAudio: voice?.title ?? PlaybackLearning.shared.preferredAudio(for: item.key),
                                  requestedQuality: release?.quality ?? quality,
                                  requestedVoice: voice)
        if let episode = episode {
            request.season = episode.seasonNumber
            request.episode = episode.episodeNumber
            request.title = SeriesTitle.make(item.title, episode.seasonNumber, episode.episodeNumber)
        }
        dismiss()
        coordinator.play(request, delay: 0.6)
    }
}

// MARK: - Release row

struct ReleaseRow: View {
    let release: TorrentRelease
    var highlighted = false
    var watched = false

    private struct Tag: Identifiable {
        let text: String
        let color: Color
        var id: String { text }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()

    private var tags: [Tag] {
        var list: [Tag] = []
        if release.quality != .unknown {
            list.append(Tag(text: release.quality.title, color: release.quality == .uhd ? .purple : Theme.accent))
        }
        if release.isHDR { list.append(Tag(text: "HDR", color: .orange)) }
        if let seasons = release.seasonsText { list.append(Tag(text: seasons, color: Color(white: 0.35))) }
        if release.isCamRip { list.append(Tag(text: "Экранка", color: .red)) }
        return list
    }

    private var details: String {
        var parts: [String] = []
        if !release.voices.isEmpty { parts.append(release.voices.prefix(3).joined(separator: ", ")) }
        if !release.sizeText.isEmpty { parts.append(release.sizeText) }
        if !release.trackerText.isEmpty { parts.append(release.trackerText) }
        if let date = release.published { parts.append(ReleaseRow.dateFormatter.string(from: date)) }
        return parts.joined(separator: " · ")
    }

    private var seedColor: Color {
        if release.seeders >= 20 { return .green }
        if release.seeders >= 3 { return .yellow }
        return .red
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                let tags = self.tags
                if !tags.isEmpty || watched {
                    HStack(spacing: 4) {
                        ForEach(tags) { tag in
                            Text(tag.text)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(tag.color))
                        }
                        if watched {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.caption)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
                Text(release.title)
                    .font(highlighted ? Font.subheadline.weight(.semibold) : Font.subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(highlighted ? 4 : 3)
                    .multilineTextAlignment(.leading)
                if !details.isEmpty {
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                }
                if !release.audioTracks.isEmpty {
                    Label(release.audioTracks.joined(separator: ", "), systemImage: "speaker.wave.2")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.up")
                    Text("\(release.seeders)")
                }
                .foregroundStyle(seedColor)
                HStack(spacing: 2) {
                    Image(systemName: "arrow.down")
                    Text("\(release.peers)")
                }
                .foregroundStyle(Theme.secondary)
            }
            .font(.caption.monospacedDigit().weight(.semibold))
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

// MARK: - Manual link

struct ManualSourceView: View {
    let onPlay: (SavedSource) -> Void

    @State private var link = ""
    @State private var name = ""

    var body: some View {
        Form {
            Section {
                TextField("magnet:… или https://…", text: $link, axis: .vertical)
                    .lineLimit(1...4)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in
                        if let first = strings.first { link = first.trimmed }
                    }
                }
                TextField("Название (необязательно)", text: $name)
            } header: {
                Text("Ссылка")
            } footer: {
                Text("Подходят magnet-ссылки, ссылки на .torrent, info-hash и прямые ссылки на видео (mp4, mkv, m3u8 и др.). Источник запоминается для этого фильма или сериала.")
            }
            Section {
                Button {
                    save()
                } label: {
                    Label("Сохранить и смотреть", systemImage: "play.fill")
                }
                .disabled(!LinkInspector.isSupported(link))
            }
        }
        .navigationTitle("Своя ссылка")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func save() {
        let value = link.trimmed
        guard LinkInspector.isSupported(value) else { return }
        let title = name.trimmed.isEmpty ? SourceNaming.defaultName(for: value) : name.trimmed
        onPlay(SavedSource(title: title, link: value))
    }
}
