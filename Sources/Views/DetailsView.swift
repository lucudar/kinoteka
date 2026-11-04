import SwiftUI

struct DetailsView: View {
    let item: MediaItem
    /// Starts the film once the page has loaded ("Смотреть" on the home screen).
    let autoplay: Bool
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @Environment(\.openURL) private var openURL
    @ObservedObject private var network = NetworkMonitor.shared
    @AppStorage(SettingsKeys.kpToken) private var token = ""
    @AppStorage(SettingsKeys.autoPlayBest) private var autoPlayBest = true
    @AppStorage(SettingsKeys.preferredQuality) private var preferredRaw = ReleaseQuality.fullHD.rawValue
    @AppStorage(SettingsKeys.preferredVoice) private var preferredVoiceRaw = "auto"
    @AppStorage(SettingsKeys.smartQuality) private var smartQuality = true

    @State private var film: KPFilm?
    @State private var staff: [KPStaff] = []
    @State private var seasons: [KPSeason] = []
    @State private var error: String?
    @State private var expanded = false
    @State private var selectedSeason = 1
    @State private var showSources = false
    @State private var pendingEpisode: KPEpisode?
    @State private var alertText: String?
    @State private var loadingTrailer = false
    @State private var searchingRelease = false
    /// The film info is known (or could not be loaded): the torrent search can start.
    @State private var filmResolved = false
    /// Releases found in advance for the page; nil until the first search ends.
    @State private var releases: [TorrentRelease]?
    @State private var releasesFailed = false
    /// Quality picked on the page for the next playback; nil means "Авто".
    @State private var chosenQuality: ReleaseQuality?
    /// Voice-over picked on the page for the next playback; nil means "Авто".
    @State private var chosenVoice: ReleaseVoiceOption?
    @State private var appliedDefaultVoice = false
    /// The season below was chosen automatically once (the one being watched).
    @State private var seasonPreselected = false
    /// The header has scrolled away: the title is shown in the navigation bar.
    @State private var titleInBar = false
    /// The page takes the colour of the poster.
    @State private var tint: Color?
    /// A landscape frame of the film for the trailer card.
    @State private var backdrop: URL?
    /// The automatic start ("Смотреть" on the home screen) has happened.
    @State private var autoplayDone = false

    init(item: MediaItem, autoplay: Bool = false) {
        self.item = item
        self.autoplay = autoplay
        _tint = State(initialValue: PosterTint.cached(item.poster))
    }

    private var current: MediaItem { film?.item ?? item }
    private var isSeries: Bool { film?.isSeries ?? (item.kind == .series) }
    private var sources: [SavedSource] { library.sources(for: item.key) }
    private var continueEntry: ContinueEntry? { library.continueEntry(for: item.key) }
    private var shareURL: URL {
        URL(string: film?.webUrl ?? "")
            ?? URL(string: "https://www.kinopoisk.ru/film/\(item.id)/")
            ?? URL(fileURLWithPath: "/")
    }
    private var preferredQuality: ReleaseQuality {
        let configured = ReleaseQuality(rawValue: preferredRaw) ?? .fullHD
        return PlaybackPolicy.effectiveQuality(configured, connection: network.connection, smart: smartQuality)
    }
    private var defaultVoice: ReleaseVoiceOption? { ReleaseVoiceOption.fromSetting(preferredVoiceRaw) }
    private var availableReleases: [TorrentRelease] {
        library.allowedReleases(releases ?? [])
    }

    private var searchQuery: TorrentSearchQuery? {
        filmResolved ? TorrentSearchQuery(item: current) : nil
    }

    private var watchedEpisodes: Set<String> { library.watchedEpisodes(for: item.key) }

    /// The episode "Смотреть" starts for a series: the first one not watched yet of the season
    /// chosen below (or of the next seasons when it is watched), otherwise its first episode.
    private var firstEpisode: KPEpisode? {
        let season = seasons.first(where: { $0.number == selectedSeason })
            ?? seasons.first(where: { $0.number > 0 })
            ?? seasons.first
        guard let season = season else { return nil }
        let watched = watchedEpisodes
        guard !watched.isEmpty else { return season.episodes.first }
        for candidate in seasons where candidate.number >= season.number {
            if let next = candidate.episodes.first(where: { !watched.contains($0.id) && !RuDate.isFuture($0.releaseDate) }) {
                return next
            }
        }
        return season.episodes.first
    }

    /// The season to show first: the one being continued, otherwise the first one with
    /// an episode not watched yet.
    private func initialSeason(in list: [KPSeason]) -> Int? {
        if let season = continueEntry?.season, list.contains(where: { $0.number == season }) { return season }
        let watched = watchedEpisodes
        guard !watched.isEmpty else { return nil }
        let regular = list.filter { $0.number > 0 }
        return (regular.isEmpty ? list : regular).first { season in
            season.episodes.contains { !watched.contains($0.id) && !RuDate.isFuture($0.releaseDate) }
        }?.number
    }

    /// Season of the main button: the one being continued, or the one chosen below.
    private var planSeason: Int? {
        guard isSeries else { return nil }
        if let entry = continueEntry { return entry.season }
        return firstEpisode?.seasonNumber
    }

    /// A release watched before that can play the season (any saved one for a film).
    private func savedSource(season: Int?) -> SavedSource? {
        guard let season = season else { return sources.first }
        return sources.first { $0.seasons?.contains(season) == true } ?? sources.first { $0.seasons == nil }
    }

    private func foundRelease(for link: String) -> TorrentRelease? {
        let marked = LinkInspector.markTorrent(link)
        return availableReleases.first { LinkInspector.markTorrent($0.link) == marked }
    }

    /// On a constrained/mobile connection, "Авто" may replace a previously
    /// watched 4K/1080p source with the network-safe quality.
    private func shouldReplaceSaved(link: String, season: Int?) -> Bool {
        guard smartQuality,
              network.connection == .cellular || network.isConstrained || network.isExpensive,
              let currentRelease = foundRelease(for: link),
              currentRelease.quality > preferredQuality,
              let replacement = plannedRelease(season: season) else { return false }
        return LinkInspector.markTorrent(replacement.link) != LinkInspector.markTorrent(link)
    }

    /// The found release for the season: the best one of the chosen quality, or of the preferred one.
    private func plannedRelease(season: Int?) -> TorrentRelease? {
        let list = availableReleases
        guard !list.isEmpty else { return nil }
        let matchingVoice = ReleaseRanking.matching(ReleaseRanking.matching(list, season: season), voice: chosenVoice)
        if let quality = chosenQuality {
            let exact = matchingVoice.filter { $0.quality == quality && !$0.isCamRip }
            return PlaybackLearning.shared.best(exact, preferred: quality, season: season, voice: chosenVoice)
        }
        return PlaybackLearning.shared.best(matchingVoice, preferred: preferredQuality, season: season, voice: chosenVoice)
    }

    private var qualityOptions: [ReleaseQuality] {
        let list = availableReleases
        guard !list.isEmpty else { return [] }
        return ReleaseRanking.qualities(ReleaseRanking.matching(list, voice: chosenVoice), season: planSeason)
    }

    private var voiceOptions: [ReleaseVoiceOption] {
        var list = availableReleases
        guard !list.isEmpty else { return [] }
        list = ReleaseRanking.matching(list, season: planSeason)
        if let quality = chosenQuality {
            list = list.filter { $0.quality == quality }
        }
        return ReleaseRanking.voiceOptions(list)
    }

    private enum Plan {
        case resume(ContinueEntry)
        case source(SavedSource)
        case release(TorrentRelease)
    }

    /// What the main button plays.
    private var plan: Plan? {
        let season = planSeason
        if let entry = continueEntry {
            if (chosenQuality != nil || chosenVoice != nil || shouldReplaceSaved(link: entry.link, season: season)),
               let release = plannedRelease(season: season),
               LinkInspector.markTorrent(release.link) != entry.link {
                return .release(release)
            }
            return .resume(entry)
        }
        if chosenQuality == nil, chosenVoice == nil, let source = savedSource(season: season),
           !shouldReplaceSaved(link: source.link, season: season) {
            return .source(source)
        }
        return plannedRelease(season: season).map { Plan.release($0) }
    }

    /// The torrent to prepare while the page is open, so the playback starts faster.
    private var warmupLink: String? {
        switch plan {
        case .resume(let entry): return entry.link
        case .source(let source): return source.link
        case .release(let release): return autoPlayBest ? LinkInspector.markTorrent(release.link) : nil
        case nil: return nil
        }
    }

    /// The file "Смотреть" will play, so its start is downloaded in advance.
    private var warmupTarget: WarmupTarget {
        if case .resume(let entry) = plan {
            return WarmupTarget(fileId: entry.fileId, season: entry.season, episode: entry.episode, isSeries: isSeries)
        }
        if isSeries, let episode = firstEpisode {
            return WarmupTarget(fileId: nil, season: episode.seasonNumber, episode: episode.episodeNumber, isSeries: true)
        }
        return WarmupTarget(fileId: nil, season: nil, episode: nil, isSeries: isSeries)
    }

    private struct WarmupKey: Hashable {
        var link: String?
        var target: WarmupTarget
    }

    private var warmupKey: WarmupKey { WarmupKey(link: warmupLink, target: warmupTarget) }

    /// The quality and the voice-over chosen are shown by their menus under the button.
    private var watchTitle: String {
        continueEntry != nil ? "Продолжить" : "Смотреть"
    }

    private var captionText: String? {
        switch plan {
        case .resume(let entry):
            var parts: [String] = []
            if let subtitle = entry.subtitle, !subtitle.isEmpty { parts.append(subtitle) }
            if let info = sources.first(where: { $0.link == entry.link })?.info { parts.append(info) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .source(let source):
            return episodePrefix + "Раздача: " + (source.info ?? source.title)
        case .release(let release):
            return episodePrefix + "Раздача: " + (release.summary.isEmpty ? release.title : release.summary)
        case nil:
            if searchingRelease { return nil }
            if releases == nil {
                return releasesFailed ? "Поиск раздач не ответил — «Смотреть» попробует ещё раз" : "Ищем раздачи…"
            }
            return "Раздачи не найдены автоматически — откройте «…» → «Все раздачи»"
        }
    }

    /// "2 сезон, 3 серия · " before the release of a series (what "Смотреть" starts).
    private var episodePrefix: String {
        guard isSeries, continueEntry == nil, let episode = firstEpisode else { return "" }
        return "\(episode.seasonNumber) сезон, \(episode.episodeNumber) серия · "
    }

    var body: some View {
        GeometryReader { proxy in
            let heroHeight = DetailsView.heroHeight(for: proxy.size.width)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    header(heroHeight: heroHeight)
                    actions
                    if let text = descriptionText {
                        descriptionBlock(text)
                    }
                    if isSeries && !seasons.isEmpty {
                        seasonsBlock
                    }
                    trailerCard
                    if !cast.isEmpty {
                        peopleBlock
                    }
                    detailsBlock
                    if let error = error {
                        ErrorView(message: error) { Task { await load() } }
                    }
                    SimilarBlock(itemId: item.id)
                }
                .padding(.bottom, 32)
            }
            // The poster reaches under the status bar and the buttons of the navigation bar.
            .ignoresSafeArea(edges: .top)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // The title on the picture has gone under the navigation bar.
                geometry.contentOffset.y + geometry.contentInsets.top > heroHeight - 170
            } action: { _, scrolled in
                withAnimation(.easeInOut(duration: 0.2)) { titleInBar = scrolled }
            }
        }
        .background(pageColor)
        .navigationTitle(current.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(current.title)
                    .font(.headline)
                    .lineLimit(1)
                    .opacity(titleInBar ? 1 : 0)
            }
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: shareURL) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                moreMenu
            }
        }
        .sheet(isPresented: $showSources) {
            SourcesSheet(item: current, episode: pendingEpisode, seasonNumbers: seasons.map { $0.number },
                         initialQuality: chosenQuality, initialVoice: chosenVoice)
        }
        .alert(alertText ?? "", isPresented: Binding(get: { alertText != nil }, set: { if !$0 { alertText = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .task(id: token) { await load() }
        .task(id: searchQuery) { await prefetchReleases() }
        .task(id: current.poster) { await loadTint() }
        .task(id: filmResolved) { await loadBackdrop() }
        .onReceive(NotificationCenter.default.publisher(for: TorrentSearchService.updated)) { note in
            // The slower source (Zona's index or Jacred) answered: its releases join the plan.
            guard let query = searchQuery, let key = note.object as? String,
                  key == TorrentSearchService.shared.identifier(for: query) else { return }
            Task {
                guard let result = await TorrentSearchService.shared.cachedResult(query), searchQuery == query else { return }
                releases = result.releases
                releasesFailed = false
            }
        }
        .task(id: warmupKey) { await warmUp(warmupKey) }
        .onChange(of: qualityOptions) { _, options in
            if let quality = chosenQuality, !options.contains(quality) { chosenQuality = nil }
        }
        .onChange(of: voiceOptions) { _, options in
            if let voice = chosenVoice, !options.contains(voice) { chosenVoice = nil }
        }
        .onChange(of: coordinator.request?.id) { _, id in
            // The choice is for one playback: next time the page continues what was watched.
            if id != nil {
                chosenQuality = nil
                chosenVoice = availableDefaultVoice(in: releases ?? [])
            }
        }
        .onAppear { library.addHistory(current) }
    }

    /// The poster takes about half of the screen.
    static func heroHeight(for width: CGFloat) -> CGFloat {
        min(max(width * 1.12, 360), 560)
    }

    /// The page takes the colour of the poster (a dark one: the text stays white).
    private var pageColor: Color { tint ?? Theme.background }

    private func loadTint() async {
        guard let url = current.poster else { return }
        if let color = await PosterTint.load(url), !Task.isCancelled, color != tint {
            withAnimation(.easeInOut(duration: 0.45)) { tint = color }
        }
    }

    /// A frame of the film for the trailer: Kinopoisk's cover, otherwise Zona's backdrop.
    private func loadBackdrop() async {
        guard filmResolved, backdrop == nil else { return }
        if let cover = film?.coverUrl?.nonEmpty, let url = URL(string: cover) {
            backdrop = url
            return
        }
        backdrop = await Backdrops.load(item.id)
    }

    /// "Смотреть" on the home screen opened the page: it starts as the button here does, once.
    private func autoplayIfNeeded() {
        guard autoplay, !autoplayDone, !Task.isCancelled else { return }
        autoplayDone = true
        watchTapped()
    }

    // MARK: Header

    /// The poster over the whole width, the title, the year, genres and ratings on its faded bottom.
    private func header(heroHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            HeroPicture(item: current, height: heroHeight, fade: pageColor)
            titleBlock
                .padding(.top, -96)
        }
    }

    private var titleBlock: some View {
        VStack(spacing: 0) {
            Text(current.title)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 2)
            if let original = current.originalTitle, !original.isEmpty, original != current.title {
                Text(original)
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.top, 4)
            }
            if !metaLine.isEmpty {
                Text(metaLine)
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
            ratingsLine
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    /// The full-size poster, drawn over the preview of the lists (that one is usually loaded already).
    private var largePoster: URL? {
        guard let preview = current.posterPreviewURL, !preview.isEmpty,
              let full = current.posterURL, full != preview else { return nil }
        return URL(string: full)
    }

    /// "2024 · Фантастика, боевик · 2 ч 46 мин · 12+".
    private var metaLine: String {
        var parts: [String] = []
        if let year = film?.yearText ?? current.year.map({ String($0) }), !year.isEmpty { parts.append(year) }
        let genres = current.genres.prefix(2).joined(separator: ", ")
        if !genres.isEmpty { parts.append(genres.capitalizedFirst) }
        if let length = film?.lengthText, !length.isEmpty { parts.append(length) }
        if let age = film?.ageText, !age.isEmpty { parts.append(age) }
        return parts.joined(separator: " · ")
    }

    /// "Кинопоиск 8,2 · IMDb 8,4", and the mark of a watched film.
    @ViewBuilder
    private var ratingsLine: some View {
        let kp = current.ratingKP ?? 0
        let imdb = current.ratingIMDb ?? 0
        let watched = library.isWatched(item.id)
        if kp > 0 || imdb > 0 || watched {
            HStack(spacing: 6) {
                if kp > 0 {
                    rating("Кинопоиск", kp)
                }
                if kp > 0 && imdb > 0 {
                    separatorDot
                }
                if imdb > 0 {
                    rating("IMDb", imdb)
                }
                if watched {
                    if kp > 0 || imdb > 0 {
                        separatorDot
                    }
                    Label("Просмотрено", systemImage: "eye.fill")
                        .foregroundStyle(Color.white.opacity(0.85))
                }
            }
            .font(.subheadline)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }

    private func rating(_ title: String, _ value: Double) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(Color.white.opacity(0.72))
            Text(RatingStyle.text(value))
                .fontWeight(.bold)
                .foregroundStyle(.white)
        }
    }

    private var separatorDot: some View {
        Text("·")
            .foregroundStyle(Color.white.opacity(0.5))
    }

    /// "…" in the navigation bar: the mark "Просмотрено", all the releases and the page on Kinopoisk.
    private var moreMenu: some View {
        Menu {
            Button {
                library.toggleWatched(current)
            } label: {
                Label(library.isWatched(item.id) ? "Отметить непросмотренным" : "Отметить просмотренным",
                      systemImage: library.isWatched(item.id) ? "eye.slash" : "eye")
            }
            Button {
                pendingEpisode = nil
                showSources = true
            } label: {
                Label("Все раздачи", systemImage: "list.bullet.rectangle")
            }
            Button {
                openURL(shareURL)
            } label: {
                Label("Открыть на Кинопоиске", systemImage: "safari")
            }
        } label: {
            Image(systemName: LiquidGlassSupport.isAvailable ? "ellipsis" : "ellipsis.circle")
        }
        .accessibilityLabel("Ещё")
    }

    // MARK: Actions

    /// One main button with "Позже" and "Избранное" beside it, the quality and the voice-over
    /// in one small menu under it.
    private var actions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    watchTapped()
                } label: {
                    Group {
                        if searchingRelease {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .tint(Theme.onAccent)
                                Text("Ищем раздачу…")
                            }
                        } else {
                            Label(watchTitle, systemImage: "play.fill")
                        }
                    }
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                }
                .primaryActionStyle()
                .disabled(searchingRelease)

                circleButton(library.isWatchLater(item) ? "bookmark.fill" : "bookmark",
                             label: library.isWatchLater(item) ? "Убрать из «Смотреть позже»" : "Смотреть позже") {
                    library.toggleWatchLater(current)
                }
                circleButton(library.isFavorite(item) ? "heart.fill" : "heart",
                             label: library.isFavorite(item) ? "Убрать из избранного" : "В избранное") {
                    library.toggleFavorite(current)
                }
            }

            choiceMenu

            if let text = captionText {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
    }

    private func circleButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 52, height: 52)
        }
        .glassButton(Circle())
        .accessibilityLabel(label)
    }

    /// "1080p · Дубляж ⌄": what "Смотреть" plays. Quality: "Авто" plays what was watched before or
    /// the best release of the preferred quality, a quality plays the best release of that quality.
    /// Voice-over filters the releases before the automatic quality and seeders ranking.
    @ViewBuilder
    private var choiceMenu: some View {
        let qualities = qualityOptions
        let voices = voiceOptions
        let showQuality = autoPlayBest && qualities.count > 1
        let showVoice = autoPlayBest && !voices.isEmpty
        if showQuality || showVoice {
            Menu {
                if showQuality {
                    Picker(selection: $chosenQuality) {
                        Text("Авто").tag(ReleaseQuality?.none)
                        ForEach(qualities) { quality in
                            Text(quality.title).tag(ReleaseQuality?.some(quality))
                        }
                    } label: {
                        Label("Качество", systemImage: "tv")
                    }
                    .pickerStyle(.menu)
                }
                if showVoice {
                    Picker(selection: $chosenVoice) {
                        Text("Авто").tag(ReleaseVoiceOption?.none)
                        ForEach(voices) { voice in
                            Text(voice.title).tag(ReleaseVoiceOption?.some(voice))
                        }
                    } label: {
                        Label("Озвучка", systemImage: "waveform")
                    }
                    .pickerStyle(.menu)
                }
            } label: {
                HStack(spacing: 5) {
                    Text(choiceSummary)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.7))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .contentShape(Capsule())
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// The chosen quality and voice-over, or those of the release "Смотреть" plays.
    private var choiceSummary: String {
        let release = planRelease
        let quality = chosenQuality?.title
            ?? release.flatMap { $0.quality == .unknown ? nil : $0.quality.title }
            ?? "Авто"
        var parts = [quality]
        if let voice = chosenVoice?.title ?? release.flatMap({ mainVoice(of: $0) }) {
            parts.append(voice)
        }
        return parts.joined(separator: " · ")
    }

    /// The found release the main button plays.
    private var planRelease: TorrentRelease? {
        switch plan {
        case .release(let release): return release
        case .resume(let entry): return foundRelease(for: entry.link)
        case .source(let source): return foundRelease(for: source.link)
        case nil: return nil
        }
    }

    private func mainVoice(of release: TorrentRelease) -> String? {
        if let kind = release.voiceKinds.filter({ $0 != .subtitles }).min() { return kind.title }
        return release.studios.first?.nonEmpty
    }

    // MARK: Trailer

    /// The trailer as a frame of the film with a play button on it.
    private var trailerCard: some View {
        Button {
            openTrailer()
        } label: {
            let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay { PosterImage(url: backdrop ?? largePoster ?? current.poster, maxPixel: 1200) }
                .overlay {
                    LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.6)],
                                   startPoint: .center, endPoint: .bottom)
                }
                .overlay {
                    Group {
                        if loadingTrailer {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(.white)
                                .offset(x: 2)
                        }
                    }
                    .frame(width: 64, height: 64)
                    .glassSurface(Circle(), style: .clear)
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Трейлер")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text(current.title)
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.75))
                            .lineLimit(1)
                    }
                    .padding(14)
                }
                .clipShape(shape)
                .overlay { shape.stroke(Color.white.opacity(0.1), lineWidth: 0.5) }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(loadingTrailer)
        .accessibilityLabel("Трейлер")
        .padding(.horizontal, 16)
    }

    private func watchTapped() {
        if let entry = continueEntry {
            continueWatching(entry)
        } else if isSeries, let episode = firstEpisode {
            play(episode)
        } else {
            playRelease(for: nil)
        }
    }

    private func continueWatching(_ entry: ContinueEntry) {
        var request = PlayRequest(continuing: entry, item: current)
        request.itemKey = item.key
        request.preferredAudio = chosenVoice?.title
            ?? PlaybackLearning.shared.preferredAudio(for: item.key)
        request.requestedQuality = chosenQuality
        request.requestedVoice = chosenVoice
        if case .release(let release) = plan {
            // Another quality is chosen: the same episode and place in that release.
            let source = SavedSource(release: release)
            library.addSource(source, for: item.key)
            request.link = source.link
            request.preferredFileId = nil
            if let time = entry.time, time > 10_000 { request.startTime = time }
        }
        coordinator.play(request)
    }

    private func play(_ episode: KPEpisode) {
        if chosenQuality == nil, chosenVoice == nil,
           let source = savedSource(season: episode.seasonNumber),
           !shouldReplaceSaved(link: source.link, season: episode.seasonNumber) {
            coordinator.play(request(for: episode, link: source.link))
        } else {
            playRelease(for: episode)
        }
    }

    private func request(for episode: KPEpisode?, link: String) -> PlayRequest {
        guard let episode = episode else {
            return PlayRequest(title: current.title, link: link, itemKey: item.key, item: current,
                               preferredAudio: chosenVoice?.title ?? PlaybackLearning.shared.preferredAudio(for: item.key),
                               requestedQuality: chosenQuality, requestedVoice: chosenVoice)
        }
        return PlayRequest(title: SeriesTitle.make(current.title, episode.seasonNumber, episode.episodeNumber),
                           link: link, itemKey: item.key, item: current,
                           season: episode.seasonNumber, episode: episode.episodeNumber,
                           preferredAudio: chosenVoice?.title ?? PlaybackLearning.shared.preferredAudio(for: item.key),
                           requestedQuality: chosenQuality, requestedVoice: chosenVoice)
    }

    /// Like Zona: starts the release watched before or the best found one right away (the search
    /// usually has finished while the page was open). The list of all releases opens when nothing
    /// suitable is found or auto start is off.
    private func playRelease(for episode: KPEpisode?) {
        let season = episode?.seasonNumber
        if chosenQuality == nil, chosenVoice == nil, episode == nil, let source = sources.first,
           !shouldReplaceSaved(link: source.link, season: season) {
            coordinator.play(request(for: nil, link: source.link))
            return
        }
        guard autoPlayBest else {
            pendingEpisode = episode
            showSources = true
            return
        }
        if releases != nil, let release = plannedRelease(season: season) {
            start(release, episode: episode)
            return
        }
        guard !searchingRelease else { return }
        searchingRelease = true
        let query = TorrentSearchQuery(item: current)
        Task {
            defer { searchingRelease = false }
            if let result = try? await TorrentSearchService.shared.search(query) {
                releases = result.releases
                applyDefaultVoiceIfNeeded(result.releases)
                releasesFailed = false
            }
            if let release = plannedRelease(season: season) {
                start(release, episode: episode)
            } else {
                pendingEpisode = episode
                showSources = true
            }
        }
    }

    private func start(_ release: TorrentRelease, episode: KPEpisode?) {
        let source = SavedSource(release: release)
        library.addSource(source, for: item.key)
        coordinator.play(request(for: episode, link: source.link))
    }

    // MARK: Speed-ups

    /// Searches the releases as soon as the page opens, so "Смотреть" starts without waiting.
    private func prefetchReleases() async {
        guard let query = searchQuery else { return }
        let service = TorrentSearchService.shared
        if releases == nil, let cached = await service.cachedResult(query), searchQuery == query {
            releases = cached.releases
            applyDefaultVoiceIfNeeded(cached.releases)
        }
        // Only for a page that stays open, not while flicking through pages (the server limits requests).
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }
        do {
            let result = try await service.search(query)
            guard searchQuery == query else { return }
            releases = result.releases
            applyDefaultVoiceIfNeeded(result.releases)
            releasesFailed = false
        } catch {
            guard searchQuery == query, !(error is CancellationError) else { return }
            releasesFailed = true
        }
    }

    private func availableDefaultVoice(in list: [TorrentRelease]) -> ReleaseVoiceOption? {
        guard let preferred = defaultVoice else { return nil }
        let options = ReleaseRanking.voiceOptions(list, season: planSeason)
        return options.contains(preferred) ? preferred : nil
    }

    private func applyDefaultVoiceIfNeeded(_ list: [TorrentRelease]) {
        guard !appliedDefaultVoice, !list.isEmpty else { return }
        appliedDefaultVoice = true
        chosenVoice = availableDefaultVoice(in: list)
    }

    /// Adds the torrent the button will play to the engine a moment after the page opens
    /// (not while scrolling through pages) and keeps it connected while the page is open.
    private func warmUp(_ key: WarmupKey) async {
        try? await Task.sleep(nanoseconds: 800_000_000)
        guard !Task.isCancelled else { return }
        guard let link = key.link, TorrentWarmup.shared.isEnabled else {
            // Not prepared in advance: the engine is still tuned for the current network before "Смотреть".
            await TorrServer.shared.prepareForPage()
            return
        }
        await TorrentWarmup.shared.prepare(link: link, title: current.title, poster: current.posterURL, target: key.target)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard !Task.isCancelled else { return }
            await TorrentWarmup.shared.keepAlive()
        }
    }

    private func openTrailer() {
        guard !loadingTrailer else { return }
        loadingTrailer = true
        let title = current.title
        Task {
            defer { loadingTrailer = false }
            // Zona's trailers are files on Russian film sites: they play here, without a key or a VPN.
            if let url = await ZonaCatalog.shared.trailer(item.id) {
                coordinator.play(PlayRequest(title: "Трейлер · \(title)", link: url.absoluteString,
                                             userAgent: ZonaTrailers.userAgent, startTime: 0))
                return
            }
            // Kinopoisk's (its widget, YouTube) open in Safari and need the key of its API.
            guard KPClient.shared.hasToken else {
                alertText = "Трейлер не найден"
                return
            }
            do {
                let videos = try await KPClient.shared.videos(item.id)
                let usable = videos.filter { ($0.url ?? "").hasPrefix("http") }
                let preferred = usable.first { $0.site == "KINOPOISK_WIDGET" }
                    ?? usable.first { $0.site == "YOUTUBE" }
                    ?? usable.first
                if let link = preferred?.url, let url = URL(string: link) {
                    openURL(url)
                } else {
                    alertText = "Трейлер не найден"
                }
            } catch {
                alertText = error.localizedDescription
            }
        }
    }

    // MARK: Description & info

    private var descriptionText: String? {
        let text = film?.description ?? film?.shortDescription
        guard let t = text?.trimmed, !t.isEmpty else { return nil }
        return t
    }

    private func descriptionBlock(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let slogan = film?.slogan?.trimmed, !slogan.isEmpty, slogan != "-" {
                Text(slogan)
                    .font(.subheadline.italic())
                    .foregroundStyle(Theme.secondary)
            }
            Text(text)
                .font(.subheadline)
                .lineLimit(expanded ? nil : 4)
            if text.count > 180 {
                Button(expanded ? "Свернуть" : "Читать полностью") {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
    }

    /// "Подробности": the country, genres and authors in two columns (the year, length and age
    /// are under the title).
    @ViewBuilder
    private var detailsBlock: some View {
        let rows = infoRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Подробности")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16, alignment: .topLeading),
                                    GridItem(.flexible(), spacing: 16, alignment: .topLeading)],
                          alignment: .leading, spacing: 18) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.title.uppercased())
                                .font(.caption2.weight(.semibold))
                                .tracking(0.8)
                                .foregroundStyle(Theme.secondary)
                            Text(row.value)
                                .font(.subheadline)
                                .foregroundStyle(.white)
                                .lineLimit(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var infoRows: [(title: String, value: String)] {
        let rows: [(title: String, value: String)] = [
            ("Страна", current.countries.joined(separator: ", ")),
            ("Жанр", current.genres.joined(separator: ", ").capitalizedFirst),
            ("Режиссёр", names(for: "DIRECTOR", limit: 3)),
            ("Сценарий", names(for: "WRITER", limit: 3))
        ]
        return rows.filter { !$0.value.isEmpty }
    }

    private func names(for profession: String, limit: Int) -> String {
        staff.filter { $0.professionKey == profession }
            .map { $0.name }
            .filter { !$0.isEmpty }
            .prefix(limit)
            .joined(separator: ", ")
    }

    /// The actors ("В ролях"); without them the directors. Everyone of the film opens from the title.
    private var cast: [KPStaff] {
        let actors = staff.filter { $0.professionKey == "ACTOR" && !$0.name.isEmpty }
        if !actors.isEmpty { return Array(actors.prefix(20)) }
        return Array(staff.filter { $0.professionKey == "DIRECTOR" && !$0.name.isEmpty }.prefix(3))
    }

    // MARK: Seasons

    private var seasonsBlock: some View {
        let watched = watchedEpisodes
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Сезоны и серии")
                    .font(.title3.weight(.bold))
                Spacer()
                if let season = seasons.first(where: { $0.number == selectedSeason }) {
                    seasonMenu(season, watched: watched)
                }
            }
            .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(seasons) { season in
                        let complete = !season.episodes.isEmpty && season.episodes.allSatisfy { watched.contains($0.id) }
                        Chip(title: complete ? "\(season.number) сезон ✓" : "\(season.number) сезон",
                             selected: season.number == selectedSeason) {
                            selectedSeason = season.number
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            if let season = seasons.first(where: { $0.number == selectedSeason }) {
                VStack(spacing: 0) {
                    ForEach(season.episodes) { episode in
                        Button {
                            play(episode)
                        } label: {
                            EpisodeRow(episode: episode,
                                       watched: watched.contains(episode.id),
                                       progress: progress(of: episode))
                        }
                        .buttonStyle(.plain)
                        .contextMenu { episodeMenu(episode, in: season, watched: watched) }
                        Divider().padding(.leading, 64)
                    }
                }
            }
        }
    }

    /// The share watched of the episode being continued.
    private func progress(of episode: KPEpisode) -> Double? {
        guard let entry = continueEntry, entry.episode == episode.episodeNumber,
              (entry.season ?? episode.seasonNumber) == episode.seasonNumber,
              entry.position > 0.01 else { return nil }
        return min(entry.position, 1)
    }

    @ViewBuilder
    private func episodeMenu(_ episode: KPEpisode, in season: KPSeason, watched: Set<String>) -> some View {
        let isWatched = watched.contains(episode.id)
        Button {
            play(episode)
        } label: {
            Label("Смотреть", systemImage: "play.fill")
        }
        Button {
            library.setEpisodeWatched(item.key, season: episode.seasonNumber, episode: episode.episodeNumber,
                                      watched: !isWatched)
        } label: {
            Label(isWatched ? "Снять отметку" : "Отметить просмотренной",
                  systemImage: isWatched ? "eye.slash" : "eye")
        }
        if episode.id != season.episodes.first?.id {
            Button {
                markWatched(upTo: episode)
            } label: {
                Label("Просмотрено до этой серии", systemImage: "checkmark.circle")
            }
        }
    }

    private func seasonMenu(_ season: KPSeason, watched: Set<String>) -> some View {
        let all = season.episodes.map { (season: $0.seasonNumber, episode: $0.episodeNumber) }
        let complete = !season.episodes.isEmpty && season.episodes.allSatisfy { watched.contains($0.id) }
        return Menu {
            if complete {
                Button {
                    library.setEpisodesWatched(item.key, all, watched: false)
                } label: {
                    Label("Снять отметки сезона", systemImage: "eye.slash")
                }
            } else {
                Button {
                    library.setEpisodesWatched(item.key, all, watched: true)
                } label: {
                    Label("Отметить сезон просмотренным", systemImage: "eye")
                }
                if season.episodes.contains(where: { watched.contains($0.id) }) {
                    Button {
                        library.setEpisodesWatched(item.key, all, watched: false)
                    } label: {
                        Label("Снять отметки сезона", systemImage: "eye.slash")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
        }
    }

    /// Everything before the episode (earlier seasons too) and the episode itself.
    private func markWatched(upTo episode: KPEpisode) {
        var list: [(season: Int, episode: Int)] = []
        for season in seasons where season.number > 0 || episode.seasonNumber == 0 {
            for candidate in season.episodes {
                if candidate.seasonNumber < episode.seasonNumber
                    || (candidate.seasonNumber == episode.seasonNumber && candidate.episodeNumber <= episode.episodeNumber) {
                    list.append((candidate.seasonNumber, candidate.episodeNumber))
                }
            }
        }
        library.setEpisodesWatched(item.key, list, watched: true)
    }

    // MARK: People

    private var peopleBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink {
                CastListView(staff: staff)
            } label: {
                SectionLinkLabel(title: cast.first?.professionKey == "ACTOR" ? "В ролях" : "Создатели")
            }
            .buttonStyle(.plain)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(Array(cast.enumerated()), id: \.offset) { _, person in
                        if let id = person.staffId {
                            NavigationLink(value: PersonRoute(id: id, name: person.name, professionKey: person.professionKey)) {
                                personCard(person)
                            }
                            .buttonStyle(.plain)
                        } else {
                            personCard(person)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func personCard(_ person: KPStaff) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .frame(width: 96, height: 128)
                .overlay { PosterImage(url: URL(string: person.posterUrl ?? ""), maxPixel: 400) }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                }
            Text(person.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            if person.professionKey == "DIRECTOR" {
                Text("Режиссёр")
                    .font(.caption2)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            } else if let role = person.description?.nonEmpty {
                Text(role)
                    .font(.caption2)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 96, alignment: .leading)
        .contentShape(Rectangle())
    }

    // MARK: Loading

    private func load() async {
        if film != nil && !staff.isEmpty {
            filmResolved = true
            return
        }
        let id = item.id
        // The film, its seasons and people load at the same time.
        let staffTask = Task { try? await KPClient.shared.staff(id) }
        var seasonsTask: Task<[KPSeason]?, Never>?
        if item.kind == .series {
            seasonsTask = Task { try? await KPClient.shared.seasons(id) }
        }
        do {
            let loaded = try await KPClient.shared.film(id)
            film = loaded
            error = nil
            filmResolved = true
            library.addHistory(loaded.item)
            if loaded.isSeries {
                var list = await seasonsTask?.value
                if list == nil {
                    list = try? await KPClient.shared.seasons(id)
                }
                if let list = list {
                    seasons = list.filter { !$0.episodes.isEmpty }.sorted { $0.number < $1.number }
                    if !seasonPreselected, let season = initialSeason(in: seasons) {
                        selectedSeason = season
                    }
                    seasonPreselected = true
                    if let first = seasons.first(where: { $0.number > 0 }) ?? seasons.first,
                       !seasons.contains(where: { $0.number == selectedSeason }) {
                        selectedSeason = first.number
                    }
                }
            }
        } catch {
            filmResolved = true
            if !Task.isCancelled && film == nil {
                self.error = error.localizedDescription
            }
        }
        autoplayIfNeeded()
        if let people = await staffTask.value {
            staff = people
        }
    }
}

enum SeriesTitle {
    static func make(_ title: String, _ season: Int?, _ episode: Int?) -> String {
        guard let episode = episode else { return title }
        if let season = season { return "\(title) · \(season) сезон, \(episode) серия" }
        return "\(title) · \(episode) серия"
    }
}

struct EpisodeRow: View {
    let episode: KPEpisode
    var watched = false
    /// The share watched of the episode being continued.
    var progress: Double? = nil

    private var upcoming: Bool { RuDate.isFuture(episode.releaseDate) }

    private var dateText: String? {
        guard let date = RuDate.text(episode.releaseDate) else { return nil }
        return upcoming ? "Выйдет " + date : date
    }

    private var icon: String {
        if watched { return "checkmark.circle.fill" }
        if progress != nil { return "play.circle.fill" }
        return upcoming ? "clock" : "play.circle"
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(episode.episodeNumber)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(watched ? Theme.secondary : .white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 3) {
                Text(episode.title)
                    .font(.subheadline)
                    .foregroundStyle(watched || upcoming ? Theme.secondary : .white)
                    .lineLimit(2)
                if let date = dateText {
                    Text(date)
                        .font(.caption)
                        .foregroundStyle(upcoming ? Theme.accent : Theme.secondary)
                }
                if let progress = progress, !watched {
                    ProgressView(value: progress)
                        .tint(Theme.accent)
                        .frame(maxWidth: 160)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(upcoming && !watched ? Theme.secondary : Theme.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// "Похожие" loaded only when scrolled into view to save API quota.
struct SimilarBlock: View {
    let itemId: Int
    @State private var items: [MediaItem] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !items.isEmpty {
                NavigationLink {
                    MediaListView(title: "Похожие", items: items)
                } label: {
                    SectionLinkLabel(title: "Похожие")
                }
                .buttonStyle(.plain)
                MediaRow(items: items, cardWidth: 120)
            }
        }
        .frame(minHeight: 1)
        .task(id: itemId) {
            guard !loaded else { return }
            if let list = try? await KPClient.shared.similars(itemId) {
                items = list.uniqued(by: \.id)
                loaded = true
            }
        }
    }
}

/// A whole row of films on its own screen ("Похожие").
struct MediaListView: View {
    let title: String
    let items: [MediaItem]

    var body: some View {
        ScrollView {
            MediaGrid(items: items)
                .padding(.vertical, 12)
        }
        .background(Theme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Everyone of a film by their work: directors, actors, writers…
struct CastListView: View {
    let staff: [KPStaff]

    private struct CrewSection: Identifiable {
        let order: Int
        let title: String
        var people: [KPStaff]
        var id: String { title }
    }

    private var sections: [CrewSection] {
        var byTitle: [String: CrewSection] = [:]
        for person in staff where !person.name.isEmpty {
            let group = CastListView.group(person.professionKey ?? "")
            byTitle[group.title, default: CrewSection(order: group.order, title: group.title, people: [])]
                .people.append(person)
        }
        return byTitle.values.sorted { $0.order < $1.order }
    }

    static func group(_ key: String) -> (order: Int, title: String) {
        switch key {
        case "DIRECTOR": return (0, "Режиссёры")
        case "ACTOR": return (1, "Актёры")
        case "WRITER": return (2, "Сценаристы")
        case "PRODUCER", "PRODUCER_USSR": return (3, "Продюсеры")
        case "OPERATOR": return (4, "Операторы")
        case "COMPOSER": return (5, "Композиторы")
        case "DESIGN": return (6, "Художники")
        case "EDITOR": return (7, "Монтажёры")
        case "VOICE_DIRECTOR": return (8, "Режиссёры дубляжа")
        case "TRANSLATOR": return (9, "Переводчики")
        default: return (10, "Другие")
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sections) { section in
                    Section {
                        ForEach(Array(section.people.enumerated()), id: \.offset) { _, person in
                            row(person)
                        }
                    } header: {
                        SectionHeader(title: section.title)
                            .padding(.top, 22)
                            .padding(.bottom, 6)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .background(Theme.background)
        .navigationTitle("Актёры и создатели")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func row(_ person: KPStaff) -> some View {
        if let id = person.staffId {
            NavigationLink(value: PersonRoute(id: id, name: person.name, professionKey: person.professionKey)) {
                rowLabel(person, opens: true)
            }
            .buttonStyle(.plain)
        } else {
            rowLabel(person, opens: false)
        }
    }

    private func rowLabel(_ person: KPStaff, opens: Bool) -> some View {
        HStack(spacing: 12) {
            Color.clear
                .frame(width: 48, height: 64)
                .overlay { PosterImage(url: URL(string: person.posterUrl ?? ""), maxPixel: 200) }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let role = person.description?.nonEmpty {
                    Text(role)
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if opens {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.secondary.opacity(0.7))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
