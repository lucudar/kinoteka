import SwiftUI

struct DetailsView: View {
    let item: MediaItem
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

    private var current: MediaItem { film?.item ?? item }
    private var isSeries: Bool { film?.isSeries ?? (item.kind == .series) }
    private var sources: [SavedSource] { library.sources(for: item.key) }
    private var continueEntry: ContinueEntry? { library.continueEntry(for: item.key) }
    private var shareURL: URL {
        URL(string: film?.webUrl ?? "") ?? URL(string: "https://www.kinopoisk.ru/film/\(item.id)/")!
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

    /// The episode "Смотреть" starts for a series: the first one of the season chosen below.
    private var firstEpisode: KPEpisode? {
        let season = seasons.first(where: { $0.number == selectedSeason })
            ?? seasons.first(where: { $0.number > 0 })
            ?? seasons.first
        return season?.episodes.first
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

    private var watchTitle: String {
        let title = continueEntry != nil ? "Продолжить" : "Смотреть"
        let choices = [chosenQuality?.title, chosenVoice?.title].compactMap { $0 }
        return choices.isEmpty ? title : title + " · " + choices.joined(separator: " · ")
    }

    private var captionText: String? {
        switch plan {
        case .resume(let entry):
            var parts: [String] = []
            if let subtitle = entry.subtitle, !subtitle.isEmpty { parts.append(subtitle) }
            if let info = sources.first(where: { $0.link == entry.link })?.info { parts.append(info) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .source(let source):
            return "Раздача: " + (source.info ?? source.title)
        case .release(let release):
            return "Раздача: " + (release.summary.isEmpty ? release.title : release.summary)
        case nil:
            if searchingRelease { return nil }
            if releases == nil {
                return releasesFailed ? "Поиск раздач не ответил — «Смотреть» попробует ещё раз" : "Ищем раздачи…"
            }
            return "Раздачи не найдены автоматически — откройте «Раздачи»"
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                header
                actions
                if let text = descriptionText {
                    descriptionBlock(text)
                }
                infoBlock
                if isSeries && !seasons.isEmpty {
                    seasonsBlock
                }
                if !actors.isEmpty {
                    actorsBlock
                }
                if let error = error {
                    ErrorView(message: error) { Task { await load() } }
                }
                SimilarBlock(itemId: item.id)
            }
            .padding(.bottom, 32)
        }
        .background(Theme.background)
        .navigationTitle(current.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: shareURL) {
                    Image(systemName: "square.and.arrow.up")
                }
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
        .task(id: warmupLink) { await warmUp(warmupLink) }
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

    // MARK: Header

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .frame(height: 250)
                .frame(maxWidth: .infinity)
                .overlay {
                    if let cover = film?.coverUrl, let url = URL(string: cover) {
                        PosterImage(url: url)
                    } else {
                        PosterImage(url: current.poster)
                            .blur(radius: 24)
                            .opacity(0.55)
                    }
                }
                .overlay {
                    LinearGradient(colors: [Theme.background.opacity(0.1), Theme.background], startPoint: .top, endPoint: .bottom)
                }
                .clipped()

            HStack(alignment: .bottom, spacing: 14) {
                Color.clear
                    .frame(width: 108, height: 162)
                    .overlay { PosterImage(url: URL(string: current.posterURL ?? "") ?? current.poster) }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 10)
                VStack(alignment: .leading, spacing: 6) {
                    Text(current.title)
                        .font(.title2.weight(.bold))
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                    if let original = current.originalTitle {
                        Text(original)
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 12) {
                        if let kp = current.ratingKP, kp > 0 {
                            ratingLabel("КП", kp)
                        }
                        if let imdb = current.ratingIMDb, imdb > 0 {
                            ratingLabel("IMDb", imdb)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .offset(y: 36)
        }
        .padding(.bottom, 36)
    }

    private func ratingLabel(_ title: String, _ value: Double) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondary)
            Text(RatingStyle.text(value))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(RatingStyle.color(value))
        }
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                watchTapped()
            } label: {
                Group {
                    if searchingRelease {
                        HStack(spacing: 10) {
                            ProgressView()
                                .tint(.white)
                            Text("Ищем раздачу…")
                        }
                    } else {
                        Label(watchTitle, systemImage: "play.fill")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(searchingRelease)

            qualityChips
            voiceChips

            if let text = captionText {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            HStack(alignment: .top) {
                CircleAction(title: "Трейлер", systemImage: loadingTrailer ? "hourglass" : "film") {
                    openTrailer()
                }
                CircleAction(title: library.isFavorite(item) ? "В избранном" : "В избранное",
                             systemImage: library.isFavorite(item) ? "heart.fill" : "heart",
                             active: library.isFavorite(item)) {
                    library.toggleFavorite(current)
                }
                CircleAction(title: library.isWatchLater(item) ? "Отложено" : "Позже",
                             systemImage: library.isWatchLater(item) ? "bookmark.fill" : "bookmark",
                             active: library.isWatchLater(item)) {
                    library.toggleWatchLater(current)
                }
                CircleAction(title: "Просмотрено",
                             systemImage: library.isWatched(item.id) ? "eye.fill" : "eye",
                             active: library.isWatched(item.id)) {
                    library.toggleWatched(current)
                }
                CircleAction(title: "Раздачи",
                             systemImage: "list.bullet.rectangle",
                             active: !sources.isEmpty) {
                    pendingEpisode = nil
                    showSources = true
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 16)
    }

    /// "Авто" plays what was watched before or the best release of the preferred quality;
    /// a quality plays the best release of that quality.
    @ViewBuilder
    private var qualityChips: some View {
        let options = qualityOptions
        if autoPlayBest && options.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Text("Качество")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                        .padding(.trailing, 2)
                    Chip(title: "Авто", selected: chosenQuality == nil) { chosenQuality = nil }
                    ForEach(options) { quality in
                        Chip(title: quality.title, selected: chosenQuality == quality) { chosenQuality = quality }
                    }
                }
            }
        }
    }

    /// Voice-over filters releases before the automatic quality/seeders ranking.
    @ViewBuilder
    private var voiceChips: some View {
        let options = voiceOptions
        if autoPlayBest && !options.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Text("Озвучка")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                        .padding(.trailing, 2)
                    Chip(title: "Авто", selected: chosenVoice == nil) { chosenVoice = nil }
                    ForEach(options) { voice in
                        Chip(title: voice.title, selected: chosenVoice == voice) { chosenVoice = voice }
                    }
                }
            }
        }
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
    private func warmUp(_ link: String?) async {
        guard let link = link, TorrentWarmup.shared.isEnabled else { return }
        try? await Task.sleep(nanoseconds: 800_000_000)
        guard !Task.isCancelled else { return }
        await TorrentWarmup.shared.prepare(link: link, title: current.title, poster: current.posterURL)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard !Task.isCancelled else { return }
            await TorrentWarmup.shared.keepAlive()
        }
    }

    private func openTrailer() {
        guard !loadingTrailer else { return }
        loadingTrailer = true
        Task {
            defer { loadingTrailer = false }
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

    private var infoBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            infoLine("Год", film?.yearText ?? current.year.map { String($0) } ?? "")
            infoLine("Страна", current.countries.joined(separator: ", "))
            infoLine("Жанр", current.genres.joined(separator: ", ").capitalizedFirst)
            infoLine("Режиссёр", names(for: "DIRECTOR", limit: 3))
            infoLine("Сценарий", names(for: "WRITER", limit: 3))
            infoLine("Время", film?.lengthText ?? "")
            infoLine("Возраст", film?.ageText ?? "")
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func infoLine(_ title: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 88, alignment: .leading)
                Text(value)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.subheadline)
        }
    }

    private func names(for profession: String, limit: Int) -> String {
        staff.filter { $0.professionKey == profession }
            .map { $0.name }
            .filter { !$0.isEmpty }
            .prefix(limit)
            .joined(separator: ", ")
    }

    private var actors: [KPStaff] {
        Array(staff.filter { $0.professionKey == "ACTOR" && !$0.name.isEmpty }.prefix(20))
    }

    // MARK: Seasons

    private var seasonsBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Сезоны и серии")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(seasons) { season in
                        Chip(title: "\(season.number) сезон", selected: season.number == selectedSeason) {
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
                            EpisodeRow(episode: episode)
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 64)
                    }
                }
            }
        }
    }

    // MARK: Actors

    private var actorsBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Актёры")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(Array(actors.enumerated()), id: \.offset) { _, person in
                        VStack(spacing: 6) {
                            Color.clear
                                .frame(width: 72, height: 72)
                                .overlay { PosterImage(url: URL(string: person.posterUrl ?? "")) }
                                .clipShape(Circle())
                            Text(person.name)
                                .font(.caption)
                                .lineLimit(2, reservesSpace: true)
                                .multilineTextAlignment(.center)
                            if let role = person.description, !role.isEmpty {
                                Text(role)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: 84)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
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
                    if let first = seasons.first, !seasons.contains(where: { $0.number == selectedSeason }) {
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

    private var dateText: String? {
        guard let raw = episode.releaseDate, raw.count >= 10 else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: String(raw.prefix(10))) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter.string(from: date)
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(episode.episodeNumber)")
                .font(.subheadline.weight(.bold))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.card))
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title)
                    .font(.subheadline)
                    .lineLimit(2)
                if let date = dateText {
                    Text(date)
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "play.circle")
                .font(.title3)
                .foregroundStyle(Theme.accent)
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
                SectionHeader(title: "Похожие")
                MediaRow(items: items)
            }
        }
        .frame(minHeight: 1)
        .task(id: itemId) {
            guard !loaded else { return }
            if let list = try? await KPClient.shared.similars(itemId) {
                items = list
                loaded = true
            }
        }
    }
}
