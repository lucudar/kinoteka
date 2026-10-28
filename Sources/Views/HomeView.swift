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

/// What is popular now as big cards paged sideways: the poster over its own blurred copy,
/// with Liquid Glass buttons.
struct FeaturedCarousel: View {
    let section: HomeSection
    let token: String
    @State private var items: [MediaItem] = []
    @State private var failed = false

    var body: some View {
        Group {
            if failed && items.isEmpty {
                // The ordinary row of this collection tells what went wrong.
                CollectionRow(section: section, token: token)
            } else {
                cards
            }
        }
        .task(id: token) { await load() }
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: section) {
                HStack(alignment: .firstTextBaseline) {
                    Text(section.title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("Все")
                        .font(.subheadline)
                        .foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    if items.isEmpty {
                        ForEach(0..<2, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: FeaturedCard.cornerRadius, style: .continuous)
                                .fill(Theme.card)
                                .frame(height: FeaturedCard.height)
                                .containerRelativeFrame(.horizontal) { length, _ in length * 0.9 }
                        }
                    } else {
                        ForEach(items) { item in
                            FeaturedCard(item: item)
                                .containerRelativeFrame(.horizontal) { length, _ in length * 0.9 }
                                .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                    content
                                        .scaleEffect(phase.isIdentity ? 1 : 0.94)
                                        .opacity(phase.isIdentity ? 1 : 0.7)
                                }
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollDisabled(items.isEmpty)
            .modifier(PulseWhenEmpty(empty: items.isEmpty))
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

struct FeaturedCard: View {
    static let height: CGFloat = 236
    static let cornerRadius: CGFloat = 24

    @EnvironmentObject private var library: LibraryStore
    let item: MediaItem

    /// The full-size poster: the card is bigger than a grid cell.
    private var largePoster: URL? {
        URL(string: item.posterURL ?? "") ?? item.poster
    }

    var body: some View {
        NavigationLink(value: item) {
            ZStack(alignment: .bottomLeading) {
                Color.clear
                    .overlay {
                        PosterImage(url: item.poster, maxPixel: 300)
                            .scaleEffect(1.3)
                            .blur(radius: 26)
                    }
                    .overlay {
                        LinearGradient(colors: [Color.black.opacity(0.05), Color.black.opacity(0.7)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                    .clipped()

                HStack(alignment: .bottom, spacing: 14) {
                    Color.clear
                        .frame(width: 124, height: 186)
                        .overlay { PosterImage(url: largePoster, maxPixel: 600) }
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 0.75)
                        }
                        .shadow(color: .black.opacity(0.45), radius: 14, y: 8)

                    VStack(alignment: .leading, spacing: 6) {
                        Spacer(minLength: 0)
                        if !item.subtitleLine.isEmpty {
                            Text(item.subtitleLine)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(2)
                        }
                        Text(item.title)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(3)
                            .minimumScaleFactor(0.8)
                        if let rating = item.ratingKP ?? item.ratingIMDb, rating > 0 {
                            RatingBadge(value: rating)
                        }
                        Label(item.kind == .series ? "К сериалу" : "К фильму", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .glassSurface(Capsule(), style: .clear, tint: Theme.accent.opacity(0.55))
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, maxHeight: 186, alignment: .bottomLeading)
                }
                .padding(16)
            }
            .frame(height: FeaturedCard.height)
            .clipShape(RoundedRectangle(cornerRadius: FeaturedCard.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FeaturedCard.cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: FeaturedCard.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Button {
                library.toggleWatchLater(item)
            } label: {
                Image(systemName: library.isWatchLater(item) ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 40, height: 40)
                    .glassSurface(Circle(), style: .clear, interactive: true)
            }
            .buttonStyle(.plain)
            .padding(12)
            .accessibilityLabel(library.isWatchLater(item) ? "Убрать из «Смотреть позже»" : "Смотреть позже")
        }
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

    /// "Осталось 34 мин": the length is known from the saved position and its share.
    private var remainingText: String? {
        guard let time = entry.time, time > 0, entry.position > 0.02, entry.position < 0.98 else { return nil }
        let total = Double(time) / entry.position
        let minutes = Int(((total - Double(time)) / 60_000).rounded(.up))
        guard minutes > 0, minutes < 1_000 else { return nil }
        if minutes < 60 { return "Осталось \(minutes) мин" }
        let rest = minutes % 60
        return rest == 0 ? "Осталось \(minutes / 60) ч" : "Осталось \(minutes / 60) ч \(rest) мин"
    }

    var body: some View {
        HStack(spacing: 12) {
            Color.clear
                .frame(width: 60, height: 90)
                .overlay { PosterImage(url: entry.item?.poster) }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .glassSurface(Circle(), style: .clear)
                }
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.item?.title ?? entry.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let subtitle = entry.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if let remaining = remainingText {
                    Text(remaining)
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                }
                ProgressView(value: min(max(entry.position, 0), 1))
                    .tint(Theme.accent)
            }
            .padding(.vertical, 4)
        }
        .padding(10)
        .frame(width: 270, height: 110)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.75)
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
                HStack(alignment: .firstTextBaseline) {
                    Text(section.title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("Все")
                        .font(.subheadline)
                        .foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 16)
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
    @State private var items: [MediaItem] = []
    @State private var page = 0
    @State private var totalPages = 1
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            MediaGrid(items: items) { item in
                if item.id == items.last?.id {
                    Task { await loadMore() }
                }
            }
            .padding(.top, 8)
            if loading {
                ProgressView().padding()
            }
            if let error = error {
                ErrorView(message: error) { Task { await loadMore() } }
            }
        }
        .background(Theme.background)
        .navigationTitle(section.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if items.isEmpty { await loadMore() }
        }
    }

    private func loadMore() async {
        guard !loading, page < totalPages else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await KPClient.shared.collection(section.id, page: page + 1)
            let known = Set(items.map { $0.id })
            items += result.items.filter { !known.contains($0.id) }
            totalPages = result.totalPages
            page += 1
            error = nil
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}
