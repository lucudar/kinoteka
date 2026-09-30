import SwiftUI

struct DetailsView: View {
    let item: MediaItem
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @Environment(\.openURL) private var openURL
    @AppStorage(SettingsKeys.kpToken) private var token = ""
    @AppStorage(SettingsKeys.autoPlayBest) private var autoPlayBest = true

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

    private var current: MediaItem { film?.item ?? item }
    private var isSeries: Bool { film?.isSeries ?? (item.kind == .series) }
    private var sources: [SavedSource] { library.sources(for: item.key) }
    private var continueEntry: ContinueEntry? { library.continueEntry(for: item.key) }
    private var shareURL: URL {
        URL(string: film?.webUrl ?? "") ?? URL(string: "https://www.kinopoisk.ru/film/\(item.id)/")!
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
            SourcesSheet(item: current, episode: pendingEpisode, seasonNumbers: seasons.map { $0.number })
        }
        .alert(alertText ?? "", isPresented: Binding(get: { alertText != nil }, set: { if !$0 { alertText = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .task(id: token) { await load() }
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
        VStack(spacing: 14) {
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
                        Label(continueEntry != nil ? "Продолжить" : "Смотреть", systemImage: "play.fill")
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

            if let entry = continueEntry, let subtitle = entry.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity)
            } else if continueEntry == nil, !isSeries, let source = sources.first {
                Text("Раздача: " + (source.info ?? source.title))
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
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
        }
        .padding(.horizontal, 16)
    }

    private func watchTapped() {
        if let entry = continueEntry {
            coordinator.play(PlayRequest(title: entry.title, link: entry.link, itemKey: item.key, item: current, preferredFileId: entry.fileId))
        } else if isSeries, let first = (seasons.first(where: { $0.number > 0 }) ?? seasons.first)?.episodes.first {
            play(first)
        } else if let source = sources.first {
            coordinator.play(PlayRequest(title: current.title, link: source.link, itemKey: item.key, item: current))
        } else {
            playBestRelease(for: nil)
        }
    }

    private func play(_ episode: KPEpisode) {
        let season = episode.seasonNumber
        let source = sources.first { $0.seasons?.contains(season) == true } ?? sources.first { $0.seasons == nil }
        if let source = source {
            coordinator.play(request(for: episode, link: source.link))
        } else {
            playBestRelease(for: episode)
        }
    }

    private func request(for episode: KPEpisode?, link: String) -> PlayRequest {
        guard let episode = episode else {
            return PlayRequest(title: current.title, link: link, itemKey: item.key, item: current)
        }
        return PlayRequest(title: SeriesTitle.make(current.title, episode.seasonNumber, episode.episodeNumber),
                           link: link, itemKey: item.key, item: current,
                           season: episode.seasonNumber, episode: episode.episodeNumber)
    }

    /// Like Zona: finds the torrents for the title and starts the best one right away.
    /// The list of all releases opens when nothing suitable is found (or auto start is off).
    private func playBestRelease(for episode: KPEpisode?) {
        guard autoPlayBest else {
            pendingEpisode = episode
            showSources = true
            return
        }
        guard !searchingRelease else { return }
        searchingRelease = true
        let title = current
        let query = TorrentSearchQuery(title: title.title, originalTitle: title.originalTitle, year: title.year, isSeries: isSeries)
        Task {
            defer { searchingRelease = false }
            let service = TorrentSearchService.shared
            var candidates = (try? await service.search(query))?.releases ?? []
            if let season = episode?.seasonNumber {
                candidates = candidates.filter { $0.seasons.isEmpty || $0.seasons.contains(season) }
            }
            guard let best = ReleaseRanking.best(candidates, preferred: service.preferredQuality, season: episode?.seasonNumber) else {
                pendingEpisode = episode
                showSources = true
                return
            }
            let source = SavedSource(release: best)
            library.addSource(source, for: item.key)
            coordinator.play(request(for: episode, link: source.link))
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
        if film != nil && !staff.isEmpty { return }
        do {
            let loaded = try await KPClient.shared.film(item.id)
            film = loaded
            error = nil
            library.addHistory(loaded.item)
            if loaded.isSeries {
                if let list = try? await KPClient.shared.seasons(item.id) {
                    seasons = list.filter { !$0.episodes.isEmpty }.sorted { $0.number < $1.number }
                    if let first = seasons.first, !seasons.contains(where: { $0.number == selectedSeason }) {
                        selectedSeason = first.number
                    }
                }
            }
            if let people = try? await KPClient.shared.staff(item.id) {
                staff = people
            }
        } catch {
            if !Task.isCancelled && film == nil {
                self.error = error.localizedDescription
            }
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
