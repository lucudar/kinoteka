import SwiftUI

struct HomeSection: Identifiable, Hashable {
    let id: String
    let title: String

    static let all: [HomeSection] = [
        HomeSection(id: "TOP_POPULAR_ALL", title: "Популярное сейчас"),
        HomeSection(id: "TOP_POPULAR_MOVIES", title: "Популярные фильмы"),
        HomeSection(id: "POPULAR_SERIES", title: "Популярные сериалы"),
        HomeSection(id: "CLOSES_RELEASES", title: "Скоро премьера"),
        HomeSection(id: "TOP_250_MOVIES", title: "250 лучших фильмов"),
        HomeSection(id: "TOP_250_TV_SHOWS", title: "250 лучших сериалов"),
        HomeSection(id: "FAMILY", title: "Для всей семьи"),
        HomeSection(id: "KIDS_ANIMATION_THEME", title: "Мультфильмы"),
        HomeSection(id: "COMICS_THEME", title: "По комиксам"),
        HomeSection(id: "LOVE_THEME", title: "Про любовь")
    ]

    /// The big cards at the top of the home screen.
    static var featured: HomeSection { all[0] }
    /// The rows under them.
    static var rows: [HomeSection] { Array(all.dropFirst()) }
}

/// "Смотреть" over the big poster of the home screen: the page of the film opens and starts the best release.
struct AutoplayRoute: Hashable {
    let item: MediaItem
}

struct HomeView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @AppStorage(SettingsKeys.kpToken) private var token = ""
    @AppStorage(SettingsKeys.zonaIndex) private var zonaIndex = true
    @State private var path = NavigationPath()

    /// Without a key the collections come from Zona's index.
    private var catalogAvailable: Bool { !token.trimmed.isEmpty || zonaIndex }

    /// The rows load again when the key or the source changes.
    private var sourceKey: String { token.trimmed + (zonaIndex ? "|zona" : "") }

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { proxy in
                let topInset = proxy.safeAreaInsets.top
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        if catalogAvailable {
                            FeaturedHero(section: HomeSection.featured, token: sourceKey,
                                         height: FeaturedHero.height(for: proxy.size, topInset: topInset),
                                         topInset: topInset, watch: watch)
                        } else {
                            TokenBanner()
                                .padding(.top, topInset + 12)
                        }
                        if !library.data.continueWatching.isEmpty {
                            ContinueWatchingRow(entries: library.data.continueWatching) { item in
                                path.append(item)
                            }
                        }
                        if !library.data.watchLater.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionHeader(title: "Смотреть позже")
                                MediaRow(items: Array(library.data.watchLater.prefix(12)))
                            }
                        }
                        if catalogAvailable {
                            if RecommendationService.hasProfile(library.data) {
                                PersonalizedRow(data: library.data, token: sourceKey)
                            }
                            ForEach(HomeSection.rows) { section in
                                CollectionRow(section: section, token: sourceKey)
                            }
                            if token.trimmed.isEmpty {
                                TokenBanner()
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
                .overlay(alignment: .top) {
                    // The clock and the battery stay readable over the pictures.
                    LinearGradient(colors: [Color.black.opacity(0.35), Color.black.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: topInset + 18)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                // The poster at the top reaches under the status bar.
                .ignoresSafeArea(edges: .top)
            }
            .background(Theme.background)
            .navigationTitle("Кинотека")
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: MediaItem.self) { DetailsView(item: $0) }
            .navigationDestination(for: AutoplayRoute.self) { DetailsView(item: $0.item, autoplay: true) }
            .navigationDestination(for: HomeSection.self) { CollectionGridView(section: $0) }
            .navigationDestination(for: PersonRoute.self) { PersonView(route: $0) }
        }
    }

    /// Continues what was watched of the film, otherwise opens its page, which starts the best release.
    private func watch(_ item: MediaItem) {
        if let entry = library.continueEntry(for: item.key) {
            coordinator.play(PlayRequest(continuing: entry))
        } else {
            path.append(AutoplayRoute(item: item))
        }
    }
}

/// What is popular now, a poster over the whole screen from its very top: the title, the genres
/// and the buttons are on the picture, the dots under them show the page.
struct FeaturedHero: View {
    let section: HomeSection
    let token: String
    let height: CGFloat
    /// The status bar over the picture.
    let topInset: CGFloat
    let watch: (MediaItem) -> Void
    @State private var items: [MediaItem] = []
    @State private var failed = false
    /// The poster on screen.
    @State private var currentID: Int?

    /// Most of the screen: the dots and the title of the next row stay in sight.
    static func height(for size: CGSize, topInset: CGFloat) -> CGFloat {
        max(400, min(size.width * 1.45, (size.height + topInset) * 0.76))
    }

    private var currentIndex: Int {
        items.firstIndex { $0.id == currentID } ?? 0
    }

    var body: some View {
        Group {
            if failed && items.isEmpty {
                // The ordinary row of this collection tells what went wrong.
                CollectionRow(section: section, token: token)
                    .padding(.top, topInset + 12)
            } else {
                pager
            }
        }
        .task(id: token) { await load() }
    }

    private var pager: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                if items.isEmpty {
                    HeroPlaceholder(height: height)
                        .containerRelativeFrame(.horizontal)
                } else {
                    ForEach(items) { item in
                        HeroPage(item: item, section: section, height: height, watch: watch)
                            .containerRelativeFrame(.horizontal)
                    }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentID)
        // The poster pulled down grows above the row.
        .scrollClipDisabled()
        .scrollDisabled(items.isEmpty)
        .frame(height: height)
        .overlay(alignment: .bottom) {
            if items.count > 1 {
                PageDots(count: items.count, current: currentIndex)
                    .padding(.bottom, 14)
            }
        }
    }

    private func load() async {
        do {
            let page = try await KPClient.shared.collection(section.id)
            items = Array(page.items.uniqued(by: \.id).prefix(10))
            failed = false
        } catch {
            if Task.isCancelled { return }
            if items.isEmpty { failed = true }
        }
    }
}

/// One poster at the top of the home screen: the picture and the title open the page,
/// "Смотреть" starts the film, "Позже" puts it in "Смотреть позже".
private struct HeroPage: View {
    @EnvironmentObject private var library: LibraryStore
    let item: MediaItem
    let section: HomeSection
    let height: CGFloat
    let watch: (MediaItem) -> Void

    /// "Фэнтези · Боевик · Приключения · 2026".
    private var meta: String {
        var parts = item.genres.prefix(3).map { $0.capitalizedFirst }
        if let year = item.year { parts.append(String(year)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let later = library.isWatchLater(item)
        ZStack(alignment: .bottom) {
            NavigationLink(value: item) {
                HeroPicture(item: item, height: height)
            }
            .buttonStyle(.plain)

            VStack(spacing: 0) {
                NavigationLink(value: section) {
                    HStack(spacing: 4) {
                        Text(section.title.uppercased())
                            .tracking(1.5)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .heavy))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                NavigationLink(value: item) {
                    VStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 38, weight: .bold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.55)
                        if !meta.isEmpty {
                            Text(meta)
                                .font(.subheadline)
                                .foregroundStyle(Color.white.opacity(0.75))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    .shadow(color: .black.opacity(0.45), radius: 12, y: 2)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 6)

                HStack(spacing: 10) {
                    Button {
                        watch(item)
                    } label: {
                        Label("Смотреть", systemImage: "play.fill")
                            .lineLimit(1)
                    }
                    .primaryActionStyle()

                    Button {
                        library.toggleWatchLater(item)
                    } label: {
                        Label("Позже", systemImage: later ? "checkmark" : "plus")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .contentTransition(.symbolEffect(.replace))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 15)
                    }
                    .glassButton(Capsule())
                    .accessibilityLabel(later ? "Убрать из «Смотреть позже»" : "Смотреть позже")
                }
                .padding(.top, 18)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .frame(height: height)
    }
}

/// The top of the home screen while the posters load.
private struct HeroPlaceholder: View {
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Theme.card, Theme.background], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 12) {
                Capsule()
                    .fill(Theme.card)
                    .frame(width: 120, height: 10)
                Capsule()
                    .fill(Theme.card)
                    .frame(width: 220, height: 30)
                Capsule()
                    .fill(Theme.card)
                    .frame(width: 170, height: 12)
            }
            .padding(.bottom, 112)
            .modifier(LoadingPulse())
        }
        .frame(height: height)
    }
}

/// The page of the posters at the top: a short line for the one on screen, dots for the others.
private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(index == current ? 0.95 : 0.35))
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: current)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct PersonalizedRow: View {
    let data: LibraryData
    let token: String
    @State private var items: [MediaItem] = []
    @State private var reason = ""
    @State private var loaded = false

    private var key: String {
        token + "|" + RecommendationService.profileKey(data)
    }

    var body: some View {
        Group {
            if !items.isEmpty || !loaded {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Для вас")
                    if !reason.isEmpty {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 16)
                    }
                    if items.isEmpty {
                        PlaceholderRow()
                    } else {
                        MediaRow(items: items)
                    }
                }
            }
        }
        .task(id: key) {
            loaded = false
            if let result = try? await RecommendationService.recommendations(for: data),
               !Task.isCancelled {
                items = result.items.uniqued(by: \.id)
                reason = result.reason
            }
            loaded = true
        }
    }
}

struct ContinueWatchingRow: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var coordinator: PlayerCoordinator
    let entries: [ContinueEntry]
    /// Opens the page of the film or series.
    var openItem: ((MediaItem) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Продолжить просмотр")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(entries) { entry in
                        Button {
                            coordinator.play(PlayRequest(continuing: entry))
                        } label: {
                            ContinueCard(entry: entry)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if let item = entry.item, let openItem = openItem {
                                Button {
                                    openItem(item)
                                } label: {
                                    Label(item.kind == .series ? "Страница сериала" : "Страница фильма",
                                          systemImage: "info.circle")
                                }
                            }
                            Button(role: .destructive) {
                                library.removeContinue(entry.itemKey)
                            } label: {
                                Label("Убрать из списка", systemImage: "xmark.circle")
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

/// A big frame of the film with its title, the episode and the time left written on it, and
/// the line of the progress along the bottom edge.
struct ContinueCard: View {
    static let width: CGFloat = 264
    static let height: CGFloat = 148
    static let cornerRadius: CGFloat = 18

    let entry: ContinueEntry
    /// A landscape frame of the film (Zona's backdrop); the middle of the poster until it comes.
    @State private var backdrop: URL?

    init(entry: ContinueEntry) {
        self.entry = entry
        _backdrop = State(initialValue: Backdrops.cached(entry.item?.id))
    }

    /// "34 мин": the length is known from the saved position and its share.
    private var remaining: String? {
        guard let time = entry.time, time > 0, entry.position > 0.02, entry.position < 0.98 else { return nil }
        let total = Double(time) / entry.position
        let minutes = Int(((total - Double(time)) / 60_000).rounded(.up))
        guard minutes > 0, minutes < 1_000 else { return nil }
        if minutes < 60 { return "\(minutes) мин" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) ч" : "\(minutes / 60) ч \(rest) мин"
    }

    /// "С1 Э3": the episode being watched.
    private var episodeText: String? {
        guard let episode = entry.episode else { return nil }
        if let season = entry.season { return "С\(season) Э\(episode)" }
        return "Серия \(episode)"
    }

    /// "С1 Э3 · ещё 34 мин", "Далее: С1 Э4", or "Осталось 34 мин" for a film.
    private var details: String? {
        let subtitle = entry.subtitle?.trimmed ?? ""
        if subtitle.hasPrefix("Далее") {
            return episodeText.map { "Далее: " + $0 } ?? subtitle
        }
        // "Просмотрено 45%" of a film: the time left says more.
        let label = episodeText ?? (subtitle.hasPrefix("Просмотрено") ? nil : subtitle.nonEmpty)
        switch (label, remaining) {
        case (nil, nil): return subtitle.nonEmpty
        case (nil, let left?): return "Осталось " + left
        case (let label?, nil): return label
        case (let label?, let left?): return label + " · ещё " + left
        }
    }

    private var progress: CGFloat { CGFloat(min(max(entry.position, 0), 1)) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ContinueCard.cornerRadius, style: .continuous)
        Color.clear
            .frame(width: ContinueCard.width, height: ContinueCard.height)
            .overlay { PosterImage(url: entry.item?.poster) }
            .overlay {
                if let backdrop = backdrop {
                    PosterImage(url: backdrop, maxPixel: 900, placeholder: false)
                        .transition(.opacity)
                }
            }
            .overlay {
                LinearGradient(stops: [
                    .init(color: Color.black.opacity(0), location: 0.3),
                    .init(color: Color.black.opacity(0.8), location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.item?.title ?? entry.title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let details = details {
                        Text(details)
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.75))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 15)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .glassSurface(Circle(), style: .clear)
                    .padding(10)
            }
            .overlay(alignment: .bottomLeading) {
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.25))
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: ContinueCard.width * progress)
                }
                .frame(height: 3)
            }
            .clipShape(shape)
            .overlay { shape.stroke(Color.white.opacity(0.1), lineWidth: 0.5) }
            .contentShape(shape)
            .task(id: entry.item?.id) {
                guard backdrop == nil, let id = entry.item?.id else { return }
                if let url = await Backdrops.load(id), !Task.isCancelled {
                    withAnimation(.easeInOut(duration: 0.3)) { backdrop = url }
                }
            }
    }
}

struct CollectionRow: View {
    let section: HomeSection
    let token: String
    @State private var items: [MediaItem] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: section) {
                SectionLinkLabel(title: section.title)
            }
            .buttonStyle(.plain)

            if !items.isEmpty {
                MediaRow(items: items)
            } else if let error = error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 16)
            } else {
                PlaceholderRow()
            }
        }
        .task(id: token) { await load() }
    }

    private func load() async {
        do {
            let page = try await KPClient.shared.collection(section.id)
            items = page.items
            error = nil
        } catch {
            if Task.isCancelled { return }
            if items.isEmpty { self.error = error.localizedDescription }
        }
    }
}

struct CollectionGridView: View {
    let section: HomeSection
    @AppStorage(SettingsKeys.collectionOrder) private var order: TitleOrder = .original
    @State private var items: [MediaItem] = []
    @State private var page = 0
    @State private var totalPages = 1
    @State private var loading = false
    @State private var error: String?

    /// Sorted by year or rating, the collection is shown whole: its pages (up to
    /// `TitleOrder.collectionPages`) are loaded first.
    private var loadedForSorting: Bool { page > 0 && page >= min(totalPages, TitleOrder.collectionPages) }

    private var shownItems: [MediaItem] { order.sorted(items) }

    var body: some View {
        ScrollView {
            if order != .original && !loadedForSorting && error == nil {
                ProgressView("Загружаю подборку целиком…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
            } else {
                MediaGrid(items: shownItems) { item in
                    if order == .original, item.id == items.last?.id {
                        Task { await loadMore() }
                    }
                }
                .padding(.top, 8)
                if loading {
                    ProgressView().padding()
                }
            }
            if let error = error {
                ErrorView(message: error) { Task { await load() } }
            }
        }
        .background(Theme.background)
        .navigationTitle(section.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                TitleOrderMenu(order: $order, originalTitle: "Как в подборке")
            }
        }
        .task(id: order) { await load() }
    }

    private func load() async {
        if order == .original {
            if items.isEmpty || error != nil { await loadMore() }
        } else {
            await loadAll()
        }
    }

    private func loadMore() async {
        guard !loading, page < totalPages else { return }
        loading = true
        defer { loading = false }
        do {
            append(try await KPClient.shared.collection(section.id, page: page + 1))
            error = nil
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    /// The rest of the collection, a few pages at a time.
    private func loadAll() async {
        // A page requested by scrolling is awaited.
        while loading {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return }
        }
        error = nil
        if page == 0 {
            await loadMore()
            guard error == nil, !Task.isCancelled else { return }
        }
        let last = min(totalPages, TitleOrder.collectionPages)
        guard page < last else { return }
        loading = true
        defer { loading = false }
        let id = section.id
        let answer = await PagedLoad.pages((page + 1)...last) { number in
            try await KPClient.shared.collection(id, page: number)
        }
        for result in answer.pages {
            append(result)
        }
        if let failure = answer.error, !Task.isCancelled, !(failure is CancellationError) {
            error = failure.localizedDescription
        }
    }

    private func append(_ result: KPPage) {
        let known = Set(items.map { $0.id })
        items += result.items.filter { !known.contains($0.id) }
        totalPages = result.totalPages
        page += 1
    }
}
