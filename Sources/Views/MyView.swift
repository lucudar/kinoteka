import SwiftUI

enum LibraryListKind: Hashable {
    case favorites(MediaKind)
    case watchLater
    case watched(MediaKind)
    case history

    var title: String {
        switch self {
        case .favorites(let kind): return kind == .movie ? "Избранные фильмы" : "Избранные сериалы"
        case .watchLater: return "Смотреть позже"
        case .watched(let kind): return kind == .movie ? "Просмотренные фильмы" : "Просмотренные сериалы"
        case .history: return "Недавно открывали"
        }
    }
}

private enum LibrarySort: String, CaseIterable, Identifiable {
    case added
    case newest
    case oldest
    case title
    case rating

    var id: String { rawValue }

    func title(for kind: LibraryListKind) -> String {
        switch self {
        case .added:
            switch kind {
            case .watched, .history: return "Недавно просмотренные"
            case .favorites, .watchLater: return "Недавно добавленные"
            }
        case .newest: return "Сначала новые"
        case .oldest: return "Сначала старые"
        case .title: return "По названию"
        case .rating: return "По рейтингу"
        }
    }
}

struct MyView: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        NavigationStack {
            List {
                Section("Избранное") {
                    NavigationLink {
                        ItemsGridScreen(kind: .favorites(.movie))
                    } label: {
                        row("Фильмы", "film", library.favorites(.movie).count)
                    }
                    NavigationLink {
                        ItemsGridScreen(kind: .favorites(.series))
                    } label: {
                        row("Сериалы", "play.rectangle.on.rectangle", library.favorites(.series).count)
                    }
                    NavigationLink {
                        FavoriteChannelsScreen()
                    } label: {
                        row("ТВ-каналы", "tv", library.data.favoriteChannels.count)
                    }
                }

                Section("Мой список") {
                    NavigationLink {
                        ItemsGridScreen(kind: .watchLater)
                    } label: {
                        row("Смотреть позже", "bookmark", library.data.watchLater.count)
                    }
                    NavigationLink {
                        DownloadsView()
                    } label: {
                        HStack {
                            Label("Загрузки", systemImage: "arrow.down.circle")
                            Spacer()
                            if let active = downloads.activeItem {
                                Text("\(Int(active.progress * 100))%")
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.accent)
                            } else if !downloads.items.isEmpty {
                                Text("\(downloads.items.count)")
                                    .foregroundStyle(Theme.secondary)
                            }
                        }
                    }
                }

                Section("Просмотренное") {
                    NavigationLink {
                        ItemsGridScreen(kind: .watched(.movie))
                    } label: {
                        row("Фильмы", "eye", library.watched(.movie).count)
                    }
                    NavigationLink {
                        ItemsGridScreen(kind: .watched(.series))
                    } label: {
                        row("Сериалы", "eye.circle", library.watched(.series).count)
                    }
                    NavigationLink {
                        ItemsGridScreen(kind: .history)
                    } label: {
                        row("Недавно открывали", "clock", library.data.history.count)
                    }
                }

                Section {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Настройки", systemImage: "gearshape")
                    }
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("О приложении", systemImage: "info.circle")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Моё")
            .navigationDestination(for: MediaItem.self) { DetailsView(item: $0) }
            .navigationDestination(for: PersonRoute.self) { PersonView(route: $0) }
        }
    }

    private func row(_ title: String, _ icon: String, _ count: Int) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .foregroundStyle(Theme.secondary)
            }
        }
    }
}

struct ItemsGridScreen: View {
    @EnvironmentObject private var library: LibraryStore
    let kind: LibraryListKind
    @State private var confirmClear = false
    @State private var searchText = ""
    @AppStorage(SettingsKeys.librarySort) private var sort: LibrarySort = .added

    private var sourceItems: [MediaItem] {
        switch kind {
        case .favorites(let type): return library.favorites(type)
        case .watchLater: return library.data.watchLater
        case .watched(let type): return library.watched(type)
        case .history: return library.data.history
        }
    }

    private var items: [MediaItem] {
        let query = searchText.trimmed.lowercased()
        var result = query.isEmpty ? sourceItems : sourceItems.filter {
            $0.title.lowercased().contains(query) ||
            ($0.originalTitle?.lowercased().contains(query) == true) ||
            $0.genres.contains { $0.lowercased().contains(query) }
        }
        switch sort {
        case .added:
            return result
        case .newest:
            return TitleOrder.newest.sorted(result)
        case .oldest:
            return TitleOrder.oldest.sorted(result)
        case .title:
            result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return result
        case .rating:
            return TitleOrder.rating.sorted(result)
        }
    }

    var body: some View {
        ScrollView {
            if items.isEmpty {
                ContentUnavailableView(searchText.trimmed.isEmpty ? "Пока пусто" : "Ничего не найдено",
                                       systemImage: searchText.trimmed.isEmpty ? "tray" : "magnifyingglass",
                                       description: Text(searchText.trimmed.isEmpty
                                                         ? "Здесь появятся фильмы и сериалы"
                                                         : "Попробуйте другое название или жанр"))
                    .padding(.top, 80)
            } else {
                MediaGrid(items: items)
                    .padding(.vertical, 8)
            }
        }
        .background(Theme.background)
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Название или жанр")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !sourceItems.isEmpty {
                    Menu {
                        Picker("Сортировка", selection: $sort) {
                            ForEach(LibrarySort.allCases) { option in
                                Text(option.title(for: kind)).tag(option)
                            }
                        }
                    } label: {
                        Image(systemName: sort == .added ? "arrow.up.arrow.down.circle" : "arrow.up.arrow.down.circle.fill")
                    }
                    .accessibilityLabel("Сортировка")
                }
                if kind == .history && !sourceItems.isEmpty {
                    Button("Очистить") { confirmClear = true }
                }
            }
        }
        .confirmationDialog("Очистить историю?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Очистить", role: .destructive) { library.clearHistory() }
        }
    }
}

struct FavoriteChannelsScreen: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var coordinator: PlayerCoordinator

    var body: some View {
        List {
            if library.data.favoriteChannels.isEmpty {
                Text("Удерживайте канал в разделе «ТВ-каналы» и выберите «В избранное».")
                    .foregroundStyle(Theme.secondary)
            }
            // Built-in channels get the current name and logo of the catalog.
            ForEach(library.data.favoriteChannels.map(\.refreshed)) { channel in
                Button {
                    ChannelPlayback.play(channel, library: library, coordinator: coordinator)
                } label: {
                    HStack(spacing: 12) {
                        ChannelArtwork(channel: channel, cornerRadius: 8)
                            .frame(width: 64)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(channel.name)
                                .foregroundStyle(.white)
                            if let group = channel.group {
                                Text(group)
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondary)
                            }
                        }
                    }
                }
            }
            .onDelete { library.removeFavoriteChannels(at: $0) }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Избранные каналы")
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum AppInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Image(systemName: "play.tv.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading) {
                        Text("Кинотека")
                            .font(.title2.weight(.bold))
                        Text("Версия \(AppInfo.version)")
                            .foregroundStyle(Theme.secondary)
                    }
                }
                Text("Личный медиаплеер в стиле Zona для iPhone.")
                Text("• Каталог, поиск, описания, рейтинги, сезоны, актёры и их фильмография — из индекса Zona (работает без VPN и без ключа) или из неофициального API Кинопоиска.\n• Просмотренные серии отмечаются сами; «Смотреть» включает первую непросмотренную.\n• Раздачи находятся автоматически, как в Zona, — из её индекса по фильму, плюс Jacred / Jackett и зеркала jac.red в России. Можно выбрать качество и озвучку; нерабочая раздача заменяется автоматически.\n• Встроенный TorrServer подстраивается под сеть: большой буфер на диске по Wi‑Fi, шифрование и только TCP в мобильной сети; начало фильма скачивается заранее.\n• «Проверка сети» показывает, что доступно без VPN, и измеряет реальную скорость торрента.\n• «Смотреть позже», персональные рекомендации, недавние ТВ-каналы и сортировка медиатеки.\n• Плеер VLCKit: жесты и двойное касание для перемотки, синхронизация звука и субтитров, блокировка управления, таймер сна, запоминание дорожек и обратный отсчёт до следующей серии.\n• Медиатеку и прогресс можно экспортировать и восстановить; секретные ключи в копию не попадают.\n• Локальный журнал и системные отчёты о сбоях экспортируются только вручную из настроек.\n• 44 встроенных телеканала — официальные бесплатные трансляции с программой передач — и свой M3U-плейлист.\n• Свои magnet, .torrent, прямые ссылки и HLS.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                Text("Приложение не содержит и не распространяет контент.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
            }
            .padding(20)
        }
        .background(Theme.background)
        .navigationTitle("О приложении")
        .navigationBarTitleDisplayMode(.inline)
    }
}
