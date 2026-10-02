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
}

struct HomeView: View {
    @EnvironmentObject private var library: LibraryStore
    @AppStorage(SettingsKeys.kpToken) private var token = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if token.trimmed.isEmpty {
                        TokenBanner()
                    }
                    if !library.data.continueWatching.isEmpty {
                        ContinueWatchingRow(entries: library.data.continueWatching)
                    }
                    if !library.data.watchLater.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(title: "Смотреть позже")
                            MediaRow(items: Array(library.data.watchLater.prefix(12)))
                        }
                    }
                    if !token.trimmed.isEmpty {
                        if RecommendationService.hasProfile(library.data) {
                            PersonalizedRow(data: library.data, token: token)
                        }
                        ForEach(HomeSection.all) { section in
                            CollectionRow(section: section, token: token)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .background(Theme.background)
            .navigationTitle("Кинотека")
            .navigationDestination(for: MediaItem.self) { DetailsView(item: $0) }
            .navigationDestination(for: HomeSection.self) { CollectionGridView(section: $0) }
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

    var body: some View {
        HStack(spacing: 12) {
            Color.clear
                .frame(width: 60, height: 90)
                .overlay { PosterImage(url: entry.item?.poster) }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    Image(systemName: "play.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 4)
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
                ProgressView(value: min(max(entry.position, 0), 1))
                    .tint(Theme.accent)
            }
            .padding(.vertical, 4)
        }
        .padding(10)
        .frame(width: 270, height: 110)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
