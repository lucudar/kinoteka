import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var library: LibraryStore
    @AppStorage(SettingsKeys.kpToken) private var token = ""
    @State private var query = ""
    @State private var results: [MediaItem] = []
    @State private var searchedQuery = ""
    @State private var page = 0
    @State private var totalPages = 1
    @State private var loading = false
    @State private var error: String?
    @State private var kindFilter: MediaKind?
    @State private var path = NavigationPath()

    private var trimmedQuery: String { query.trimmed }

    private var visibleResults: [MediaItem] {
        guard let kind = kindFilter else { return results }
        return results.filter { $0.kind == kind }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                content
                    .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.immediately)
            .background(Theme.background)
            .navigationTitle("Поиск")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Фильмы и сериалы")
            .onSubmit(of: .search) {
                library.addQuery(query)
            }
            .onChange(of: path.count) { old, new in
                // A result was opened: the query was useful, keep it in "Недавние запросы".
                if old == 0, new > 0, trimmedQuery == searchedQuery { library.addQuery(searchedQuery) }
            }
            .task(id: trimmedQuery) {
                let q = trimmedQuery
                guard q.count >= 2 else {
                    results = []
                    searchedQuery = ""
                    error = nil
                    return
                }
                if q == searchedQuery && !results.isEmpty { return }
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                await search(q)
            }
            .navigationDestination(for: MediaItem.self) { DetailsView(item: $0) }
            .navigationDestination(for: PersonRoute.self) { PersonView(route: $0) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if trimmedQuery.count < 2 {
            recentBlock
        } else if token.trimmed.isEmpty {
            TokenBanner()
        } else if let error = error, results.isEmpty {
            ErrorView(message: error) { Task { await search(trimmedQuery) } }
        } else if results.isEmpty {
            if loading || searchedQuery != trimmedQuery {
                ProgressView().padding(.top, 40)
            } else {
                ContentUnavailableView("Ничего не найдено", systemImage: "magnifyingglass", description: Text("Проверьте написание или попробуйте другое название"))
                    .padding(.top, 40)
            }
        } else {
            if kindFilter != nil
                || (results.contains(where: { $0.kind == .series }) && results.contains(where: { $0.kind == .movie })) {
                kindPicker
            }
            MediaGrid(items: visibleResults) { item in
                if item.id == visibleResults.last?.id {
                    Task { await loadMore() }
                }
            }
            if loading {
                ProgressView().padding()
            } else if visibleResults.isEmpty {
                Text(kindFilter == .series ? "Сериалов среди найденного нет" : "Фильмов среди найденного нет")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                    .padding(.top, 30)
                if page < totalPages {
                    Button("Искать дальше") { Task { await loadMore() } }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var kindPicker: some View {
        Picker("Тип", selection: $kindFilter) {
            Text("Всё").tag(MediaKind?.none)
            Text("Фильмы").tag(MediaKind?.some(.movie))
            Text("Сериалы").tag(MediaKind?.some(.series))
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var recentBlock: some View {
        if !library.data.recentQueries.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Недавние запросы")
                        .font(.headline)
                    Spacer()
                    Button("Очистить") { library.clearQueries() }
                        .font(.subheadline)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                ForEach(library.data.recentQueries, id: \.self) { recent in
                    HStack(spacing: 12) {
                        Button {
                            query = recent
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(Theme.secondary)
                                Text(recent)
                                    .foregroundStyle(.white)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button {
                            library.removeQuery(recent)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption)
                                .foregroundStyle(Theme.secondary)
                                .padding(6)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    Divider().padding(.leading, 48)
                }
            }
        } else if token.trimmed.isEmpty {
            TokenBanner()
                .padding(.top, 8)
        } else {
            ContentUnavailableView("Найдите фильм или сериал", systemImage: "magnifyingglass", description: Text("Введите название на русском или английском"))
                .padding(.top, 60)
        }
    }

    private func search(_ q: String) async {
        loading = true
        defer { loading = false }
        do {
            let result = try await KPClient.shared.search(q, page: 1)
            guard q == trimmedQuery else { return }
            results = result.items
            totalPages = result.totalPages
            page = 1
            searchedQuery = q
            error = nil
        } catch {
            if Task.isCancelled { return }
            guard q == trimmedQuery else { return }
            results = []
            searchedQuery = q
            self.error = error.localizedDescription
        }
    }

    private func loadMore() async {
        let q = searchedQuery
        guard !loading, page >= 1, page < totalPages, q == trimmedQuery else { return }
        loading = true
        defer { loading = false }
        if let result = try? await KPClient.shared.search(q, page: page + 1), q == trimmedQuery {
            let known = Set(results.map { $0.id })
            results += result.items.filter { !known.contains($0.id) }
            page += 1
        }
    }
}
