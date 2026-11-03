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

struct HomeView: View {
    @EnvironmentObject private var library: LibraryStore
    @AppStorage(SettingsKeys.kpToken) private var token = ""
    @AppStorage(SettingsKeys.zonaIndex) private var zonaIndex = true
    @State private var path = NavigationPath()

    /// Without a key the collections come from Zona's index.
    private var catalogAvailable: Bool { !token.trimmed.isEmpty || zonaIndex }

    /// The rows load again when the key or the source changes.
    private var sourceKey: String { token.trimmed + (zonaIndex ? "|zona" : "") }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if catalogAvailable {
                        FeaturedCarousel(section: HomeSection.featured, token: sourceKey)
                    } else {
                        TokenBanner()
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
                .padding(.vertical, 12)
            }
            .background(Theme.background)
            .navigationTitle("Кинотека")
            .navigationDestination(for: MediaItem.self) { DetailsView(item: $0) }
            .navigationDestination(for: HomeSection.self) { CollectionGridView(section: $0) }
            .navigationDestination(for: PersonRoute.self) { PersonView(route: $0) }
        }
    }
}

/// What is popular now as a cover flow: the poster in the middle is big, its neighbours are
/// smaller and dimmed, and the top of the screen takes the colour of the poster in the middle.
struct FeaturedCarousel: View {
    let section: HomeSection
    let token: String
    @State private var items: [MediaItem] = []
    @State private var failed = false
    /// The poster in the middle.
    @State private var currentID: Int?

    private var current: MediaItem? {
        items.first { $0.id == currentID } ?? items.first
    }

    var body: some View {
        Group {
            if failed && items.isEmpty {
                // The ordinary row of this collection tells what went wrong.
                CollectionRow(section: section, token: token)
            } else {
                content
            }
        }
        .task(id: token) { await load() }
    }

    private var content: some View {
        VStack(spacing: 0) {
            NavigationLink(value: section) {
                SectionLinkLabel(title: section.title)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 14)

            coverflow

            caption
                .frame(height: 52)
                .animation(.easeInOut(duration: 0.25), value: current?.id)
                .padding(.top, 16)
        }
        .background(alignment: .top) {
            // Reaches up under the large title and the status bar, fades out under the caption.
            AmbientGlow(url: current?.poster, height: 1250)
                .offset(y: -600)
        }
    }

    private var coverflow: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let margin = max(16, (width - CoverCard.width) / 2)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    if items.isEmpty {
                        ForEach([-1, -2, -3], id: \.self) { _ in
                            RoundedRectangle(cornerRadius: CoverCard.cornerRadius, style: .continuous)
                                .fill(Theme.card)
                                .frame(width: CoverCard.width, height: CoverCard.height)
                                .modifier(CoverflowEffect(width: width))
                        }
                    } else {
                        ForEach(items) { item in
                            CoverCard(item: item)
                                .modifier(CoverflowEffect(width: width))
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, margin, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $currentID, anchor: .center)
            .scrollClipDisabled()
            .scrollDisabled(items.isEmpty)
            .modifier(PulseWhenEmpty(empty: items.isEmpty))
        }
        .frame(height: CoverCard.height)
    }

    @ViewBuilder
    private var caption: some View {
        if let item = current {
            NavigationLink(value: item) {
                VStack(spacing: 4) {
                    Text(item.title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(item.shortMeta)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .id(item.id)
            .transition(.opacity)
        } else {
            VStack(spacing: 8) {
                Capsule()
                    .fill(Theme.card)
                    .frame(width: 190, height: 18)
                Capsule()
                    .fill(Theme.card)
                    .frame(width: 120, height: 12)
            }
            .modifier(LoadingPulse())
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

/// The posters of the cover flow shrink and dim as they move away from the middle.
private struct CoverflowEffect: ViewModifier {
    /// The width of the cover flow.
    let width: CGFloat

    func body(content: Content) -> some View {
        let center = width / 2
        let step = CoverCard.width
        return content.visualEffect { effect, geometry in
            let frame = geometry.frame(in: .scrollView(axis: .horizontal))
            let distance = min(abs(frame.midX - center) / step, 1)
            return effect
                .scaleEffect(1 - distance * 0.2)
                .opacity(1 - distance * 0.5)
        }
    }
}

private struct PulseWhenEmpty: ViewModifier {
    let empty: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if empty {
            content.modifier(LoadingPulse())
        } else {
            content
        }
    }
}

/// A big poster of the cover flow on the home screen.
struct CoverCard: View {
    static let width: CGFloat = 214
    static let height: CGFloat = 321
    static let cornerRadius: CGFloat = 20

    @EnvironmentObject private var library: LibraryStore
    let item: MediaItem

    /// The full-size poster, drawn over the preview of the lists (that one is usually loaded already).
    private var largePoster: URL? {
        guard let preview = item.posterPreviewURL, !preview.isEmpty,
              let full = item.posterURL, full != preview else { return nil }
        return URL(string: full)
    }

    var body: some View {
        NavigationLink(value: item) {
            Color.clear
                .frame(width: CoverCard.width, height: CoverCard.height)
                .overlay { PosterImage(url: item.poster) }
                .overlay { PosterImage(url: largePoster, maxPixel: 1000, placeholder: false) }
                .overlay(alignment: .topTrailing) { PosterMarks(item: item) }
                .clipShape(RoundedRectangle(cornerRadius: CoverCard.cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: CoverCard.cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
                }
                .background {
                    // The shadow of a plain shape is cheaper than one of the picture.
                    RoundedRectangle(cornerRadius: CoverCard.cornerRadius, style: .continuous)
                        .fill(Color.black)
                        .shadow(color: .black.opacity(0.5), radius: 22, y: 14)
                }
                .contentShape(RoundedRectangle(cornerRadius: CoverCard.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu { LibraryMenuItems(library: library, item: item) }
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
        VStack(alignment: .leading, spacing: 10) {
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

struct ContinueCard: View {
    let entry: ContinueEntry

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

    /// "2 сезон, 3 серия · ещё 34 мин", or "Осталось 34 мин" for a film.
    private var details: String? {
        let subtitle = entry.subtitle?.trimmed ?? ""
        switch (subtitle.isEmpty, remaining) {
        case (true, nil): return nil
        case (true, let left?): return "Осталось " + left
        case (false, nil): return subtitle
        case (false, let left?): return subtitle + " · ещё " + left
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Color.clear
                .frame(width: 52, height: 78)
                .overlay { PosterImage(url: entry.item?.poster) }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .glassSurface(Circle(), style: .clear)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.item?.title ?? entry.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let details = details {
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                }
                ProgressView(value: min(max(entry.position, 0), 1))
                    .tint(.white)
                    .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .frame(width: 290, height: 98)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .glassSurface(RoundedRectangle(cornerRadius: 22, style: .continuous))
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
