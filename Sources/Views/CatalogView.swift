import SwiftUI

struct CatalogView: View {
    @EnvironmentObject private var library: LibraryStore
    @AppStorage(SettingsKeys.kpToken) private var token = ""
    @AppStorage(SettingsKeys.zonaIndex) private var zonaIndex = true
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
        let zona: Bool
    }

    /// Without a key the catalog comes from Zona's index.
    private var catalogAvailable: Bool { !token.trimmed.isEmpty || zonaIndex }

    /// Filter as sent to the server ("hide watched" is applied locally). The names stay: Zona's
    /// index filters by them.
    private var serverFilter: CatalogFilter {
        var f = filter
        f.hideWatched = false
        return f
    }

    private var loadKey: LoadKey {
        LoadKey(filter: serverFilter, token: token, zona: zonaIndex)
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

                    if !catalogAvailable {
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
                                .secondaryActionStyle()
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
                    .disabled(!catalogAvailable)
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
            .task(id: loadKey) {
                let key = loadKey
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
        if filter.genreId != nil || filter.genreName != nil { parts.append(filter.genreName?.lowercased() ?? "жанр") }
        if filter.countryId != nil || filter.countryName != nil { parts.append(filter.countryName ?? "страна") }
        if filter.decade != "all" { parts.append(Decade.byId(filter.decade).title) }
        if filter.ratingFrom > 0 { parts.append("рейтинг от \(filter.ratingFrom)") }
        if filter.hideWatched { parts.append("без просмотренного") }
        return "Фильтры: " + parts.joined(separator: ", ")
    }

    private func reload() async {
        guard catalogAvailable else { return }
        items = []
        page = 0
        totalPages = 1
        error = nil
        loading = false
        await loadMore()
    }

    private func loadMore() async {
        guard !loading, page < totalPages, catalogAvailable else { return }
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
    private let initial: CatalogFilter
    let onApply: (CatalogFilter) -> Void

    init(filter: CatalogFilter, onApply: @escaping (CatalogFilter) -> Void) {
        _draft = State(initialValue: filter)
        initial = filter
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
                    // Chosen by the name: the list from Zona's index (without the API) has no ids.
                    Picker("Жанр", selection: $draft.genreName) {
                        Text("Все жанры").tag(String?.none)
                        ForEach(genres, id: \.title) { genre in
                            Text(genre.title.capitalizedFirst).tag(Optional(genre.title))
                        }
                    }
                    .pickerStyle(.navigationLink)

                    Picker("Страна", selection: $draft.countryName) {
                        Text("Все страны").tag(String?.none)
                        ForEach(countries, id: \.title) { country in
                            Text(country.title).tag(Optional(country.title))
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
                        onApply(resolved(draft))
                        dismiss()
                    }
                }
            }
            .task { await loadFilters() }
        }
    }

    /// The Kinopoisk ids of the chosen genre and country (the API filters by them). A list from
    /// Zona's index has none: the earlier id stays when the name did not change, otherwise the
    /// index filters by the name.
    private func resolved(_ filter: CatalogFilter) -> CatalogFilter {
        var result = filter
        result.genreId = id(of: filter.genreName, in: genres,
                            previous: filter.genreName == initial.genreName ? initial.genreId : nil)
        result.countryId = id(of: filter.countryName, in: countries,
                              previous: filter.countryName == initial.countryName ? initial.countryId : nil)
        return result
    }

    private func id(of name: String?, in list: [KPFilterValue], previous: Int?) -> Int? {
        guard let name = name else { return nil }
        return list.first(where: { $0.title == name })?.id ?? previous
    }

    private func loadFilters() async {
        guard genres.isEmpty else { return }
        do {
            let filters = try await KPClient.shared.filters()
            genres = filters.genres
                .filter { !$0.title.isEmpty }
                .uniqued(by: \.title)
                .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
            let popular = ["Россия", "СССР", "США", "Великобритания", "Франция", "Германия", "Италия", "Испания", "Япония", "Корея Южная", "Китай", "Индия", "Канада", "Австралия", "Турция"]
            let valid = filters.countries.filter { !$0.title.isEmpty }.uniqued(by: \.title)
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
