import SwiftUI

struct CatalogView: View {
    @EnvironmentObject private var library: LibraryStore
    @AppStorage(SettingsKeys.kpToken) private var token = ""
    @State private var filter = CatalogFilter.restored()
    @State private var items: [MediaItem] = []
    @State private var page = 0
    @State private var totalPages = 1
    @State private var loading = false
    @State private var error: String?
    @State private var showFilters = false
    @State private var loadedKey: LoadKey?

    private struct LoadKey: Equatable {
        let filter: CatalogFilter
        let token: String
    }

    /// Filter as sent to the server ("hide watched" is applied locally).
    private var serverFilter: CatalogFilter {
        var f = filter
        f.hideWatched = false
        f.genreName = nil
        f.countryName = nil
        return f
    }

    private var visibleItems: [MediaItem] {
        filter.hideWatched ? items.filter { !library.isWatched($0.id) } : items
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Picker("Раздел", selection: $filter.type) {
                        Text("Фильмы").tag("FILM")
                        Text("Сериалы").tag("TV_SERIES")
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)

                    if token.trimmed.isEmpty {
                        TokenBanner()
                    } else {
                        if !filter.isDefault {
                            activeFilters
                        }
                        MediaGrid(items: visibleItems) { item in
                            if item.id == visibleItems.last?.id {
                                Task { await loadMore() }
                            }
                        }
                        if loading {
                            ProgressView().padding()
                        } else if let error = error {
                            ErrorView(message: error) { Task { await loadMore() } }
                        } else if page > 0 && page < totalPages && visibleItems.count < 12 {
                            Button("Загрузить ещё") { Task { await loadMore() } }
                                .buttonStyle(.bordered)
                                .padding()
                        } else if page > 0 && visibleItems.isEmpty {
                            ContentUnavailableView("Ничего не найдено", systemImage: "film.stack", description: Text("Попробуйте изменить фильтры"))
                                .padding(.top, 40)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .background(Theme.background)
            .navigationTitle(filter.type == "FILM" ? "Фильмы" : "Сериалы")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showFilters = true
                    } label: {
                        Image(systemName: filter.isDefault ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .disabled(token.trimmed.isEmpty)
                }
            }
            .sheet(isPresented: $showFilters) {
                FiltersView(filter: filter) { newFilter in
                    filter = newFilter
                }
            }
            .onChange(of: filter) { _, newFilter in
                newFilter.save()
            }
            .task(id: LoadKey(filter: serverFilter, token: token)) {
                let key = LoadKey(filter: serverFilter, token: token)
                if key == loadedKey && !items.isEmpty { return }
                loadedKey = key
                await reload()
            }
            .navigationDestination(for: MediaItem.self) { DetailsView(item: $0) }
            .navigationDestination(for: PersonRoute.self) { PersonView(route: $0) }
        }
    }

    private var activeFilters: some View {
        HStack {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(Theme.accent)
            Text(filterSummary)
                .font(.footnote)
                .foregroundStyle(Theme.secondary)
                .lineLimit(2)
            Spacer()
            Button("Сбросить") {
                let type = filter.type
                filter = CatalogFilter()
                filter.type = type
            }
            .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 16)
    }

    private var filterSummary: String {
        var parts: [String] = []
        switch filter.order {
        case "RATING": parts.append("по рейтингу")
        case "YEAR": parts.append("по дате выхода")
        default: break
        }
        if filter.genreId != nil { parts.append(filter.genreName?.lowercased() ?? "жанр") }
        if filter.countryId != nil { parts.append(filter.countryName ?? "страна") }
        if filter.decade != "all" { parts.append(Decade.byId(filter.decade).title) }
        if filter.ratingFrom > 0 { parts.append("рейтинг от \(filter.ratingFrom)") }
        if filter.hideWatched { parts.append("без просмотренного") }
        return "Фильтры: " + parts.joined(separator: ", ")
    }

    private func reload() async {
        guard !token.trimmed.isEmpty else { return }
        items = []
        page = 0
        totalPages = 1
        error = nil
        loading = false
        await loadMore()
    }

    private func loadMore() async {
        guard !loading, page < totalPages, !token.trimmed.isEmpty else { return }
        let requested = serverFilter
        loading = true
        defer { loading = false }
        do {
            let result = try await KPClient.shared.films(requested, page: page + 1)
            guard requested == serverFilter else { return }
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

struct FiltersView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CatalogFilter
    @State private var genres: [KPFilterValue] = []
    @State private var countries: [KPFilterValue] = []
    @State private var loadError: String?
    let onApply: (CatalogFilter) -> Void

    init(filter: CatalogFilter, onApply: @escaping (CatalogFilter) -> Void) {
        _draft = State(initialValue: filter)
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Сортировка") {
                    Picker("Сортировка", selection: $draft.order) {
                        Text("По популярности").tag("NUM_VOTE")
                        Text("По рейтингу").tag("RATING")
                        Text("По дате выхода").tag("YEAR")
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("Параметры") {
                    Picker("Жанр", selection: $draft.genreId) {
                        Text("Все жанры").tag(Int?.none)
                        ForEach(genres) { genre in
                            Text(genre.title.capitalizedFirst).tag(genre.id)
                        }
                    }
                    .pickerStyle(.navigationLink)

                    Picker("Страна", selection: $draft.countryId) {
                        Text("Все страны").tag(Int?.none)
                        ForEach(countries) { country in
                            Text(country.title).tag(country.id)
                        }
                    }
                    .pickerStyle(.navigationLink)

                    Picker("Годы выхода", selection: $draft.decade) {
                        ForEach(Decade.all) { decade in
                            Text(decade.title).tag(decade.id)
                        }
                    }

                    Picker("Рейтинг", selection: $draft.ratingFrom) {
                        Text("Любой").tag(0)
                        Text("от 5").tag(5)
                        Text("от 6").tag(6)
                        Text("от 7").tag(7)
                        Text("от 8").tag(8)
                    }
                }

                Section {
                    Toggle("Скрывать просмотренное", isOn: $draft.hideWatched)
                }

                if let loadError = loadError {
                    Section {
                        Text(loadError)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondary)
                    }
                }

                Section {
                    Button("Сбросить фильтры", role: .destructive) {
                        let type = draft.type
                        draft = CatalogFilter()
                        draft.type = type
                    }
                }
            }
            .navigationTitle("Фильтры")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отменить") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Показать") {
                        onApply(named(draft))
                        dismiss()
                    }
                }
            }
            .task { await loadFilters() }
        }
    }

    /// The names of the chosen genre and country, for the summary above the catalog.
    private func named(_ filter: CatalogFilter) -> CatalogFilter {
        var result = filter
        if let id = result.genreId {
            if let genre = genres.first(where: { $0.id == id }) { result.genreName = genre.title }
        } else {
            result.genreName = nil
        }
        if let id = result.countryId {
            if let country = countries.first(where: { $0.id == id }) { result.countryName = country.title }
        } else {
            result.countryName = nil
        }
        return result
    }

    private func loadFilters() async {
        guard genres.isEmpty else { return }
        do {
            let filters = try await KPClient.shared.filters()
            genres = filters.genres
                .filter { $0.id != nil && !$0.title.isEmpty }
                .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
            let popular = ["Россия", "СССР", "США", "Великобритания", "Франция", "Германия", "Италия", "Испания", "Япония", "Корея Южная", "Китай", "Индия", "Канада", "Австралия", "Турция"]
            let valid = filters.countries.filter { $0.id != nil && !$0.title.isEmpty }
            let top = popular.compactMap { name in valid.first { $0.title == name } }
            let rest = valid
                .filter { !popular.contains($0.title) }
                .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
            countries = top + rest
        } catch {
            loadError = error.localizedDescription
        }
    }
}
