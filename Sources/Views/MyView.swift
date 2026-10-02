import SwiftUI
import UniformTypeIdentifiers

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
    case title
    case year
    case rating

    var id: String { rawValue }
    var title: String {
        switch self {
        case .added: return "Сначала новые"
        case .title: return "По названию"
        case .year: return "По году"
        case .rating: return "По рейтингу"
        }
    }
}

struct MyView: View {
    @EnvironmentObject private var library: LibraryStore

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
    @State private var sort: LibrarySort = .added

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
            break
        case .title:
            result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .year:
            result.sort { ($0.year ?? 0) > ($1.year ?? 0) }
        case .rating:
            result.sort { ($0.ratingKP ?? $0.ratingIMDb ?? 0) > ($1.ratingKP ?? $1.ratingIMDb ?? 0) }
        }
        return result
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
                                Text(option.title).tag(option)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
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
            ForEach(library.data.favoriteChannels) { channel in
                Button {
                    library.addRecentChannel(channel)
                    coordinator.play(PlayRequest(title: channel.name, link: channel.url, isLive: true, userAgent: channel.userAgent, referrer: channel.referrer))
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.card)
                            PosterImage(url: URL(string: channel.logo ?? ""), mode: .fit)
                                .padding(4)
                        }
                        .frame(width: 64, height: 40)
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

struct SettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var channels: ChannelsStore
    @ObservedObject private var network = NetworkMonitor.shared
    @AppStorage(SettingsKeys.kpToken) private var token = ""
    @AppStorage(SettingsKeys.playlistURL) private var playlistURL = ""
    @AppStorage(SettingsKeys.autoNext) private var autoNext = true
    @AppStorage(SettingsKeys.savePlayerSettings) private var savePlayerSettings = true
    @AppStorage(SettingsKeys.backgroundAudio) private var backgroundAudio = true
    @AppStorage(SettingsKeys.searchServer) private var searchServer = TorrentSearchService.defaultServer
    @AppStorage(SettingsKeys.searchApiKey) private var searchApiKey = ""
    @AppStorage(SettingsKeys.preferredQuality) private var preferredQuality = ReleaseQuality.fullHD.rawValue
    @AppStorage(SettingsKeys.preferredVoice) private var preferredVoice = "auto"
    @AppStorage(SettingsKeys.autoPlayBest) private var autoPlayBest = true
    @AppStorage(SettingsKeys.prepareTorrent) private var prepareTorrent = true
    @AppStorage(SettingsKeys.smartQuality) private var smartQuality = true
    @AppStorage(SettingsKeys.automaticFallback) private var automaticFallback = true
    @AppStorage(SettingsKeys.automaticRecovery) private var automaticRecovery = true
    @AppStorage(SettingsKeys.preloadNextEpisode) private var preloadNextEpisode = true
    @AppStorage(SettingsKeys.playerGestures) private var playerGestures = true
    @State private var checkingSearch = false
    @State private var engineStatus = "Проверка…"
    @State private var cacheSize = ""
    @State private var diagnosticsSize = ""
    @State private var reportVersion = 0
    @State private var message: String?
    @State private var importingBackup = false
    @State private var backupURL: URL?

    var body: some View {
        Form {
            Section {
                SecureField("Ключ API", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in
                        if let first = strings.first { token = first.trimmed }
                    }
                }
                if let url = URL(string: "https://kinopoiskapiunofficial.tech/signup") {
                    Link(destination: url) {
                        Label("Получить ключ бесплатно", systemImage: "arrow.up.right.square")
                    }
                }
            } header: {
                Text("Кинопоиск")
            } footer: {
                Text(token.trimmed.isEmpty
                     ? "Зарегистрируйтесь на kinopoiskapiunofficial.tech, скопируйте токен из профиля и вставьте сюда. Бесплатно — 500 запросов в сутки, ответы кэшируются на устройстве."
                     : "Ключ сохранён. Бесплатный тариф — 500 запросов в сутки, ответы кэшируются на устройстве.")
            }

            Section {
                NavigationLink {
                    PlaylistSetupView()
                        .navigationTitle("Плейлист")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    HStack {
                        Label("Плейлист M3U", systemImage: "tv")
                        Spacer()
                        Text(playlistSummary)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                }
            } header: {
                Text("ТВ-каналы")
            }

            Section {
                Toggle("Сразу включать лучшую раздачу", isOn: $autoPlayBest)
                Picker("Качество по умолчанию", selection: $preferredQuality) {
                    ForEach(ReleaseQuality.choices) { quality in
                        Text(quality.title).tag(quality.rawValue)
                    }
                }
                Picker("Озвучка по умолчанию", selection: $preferredVoice) {
                    Text("Авто").tag("auto")
                    ForEach(VoiceKind.audioChoices, id: \.rawValue) { voice in
                        Text(voice.title).tag(ReleaseVoiceOption.kind(voice).settingValue)
                    }
                }
                Toggle("Автокачество по сети", isOn: $smartQuality)
                Toggle("Готовить раздачу заранее", isOn: $prepareTorrent)
                Toggle("Автоматически менять нерабочую раздачу", isOn: $automaticFallback)
                LabeledContent("Текущая сеть", value: network.title)
                LabeledContent("Сервер") {
                    TextField(TorrentSearchService.defaultServer, text: $searchServer)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                LabeledContent("API-ключ") {
                    SecureField("не нужен для jac.red", text: $searchApiKey)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Button {
                    checkSearch()
                } label: {
                    HStack {
                        Text("Проверить поиск")
                        Spacer()
                        if checkingSearch {
                            ProgressView()
                        }
                    }
                }
                .disabled(checkingSearch)
                if searchServer.trimmed != TorrentSearchService.defaultServer {
                    Button("Вернуть сервер по умолчанию") {
                        searchServer = TorrentSearchService.defaultServer
                        searchApiKey = ""
                        TorrentSearchService.shared.clearCache()
                    }
                }
            } header: {
                Text("Поиск раздач")
            } footer: {
                Text("«Автокачество по сети» ограничивает мобильную сеть до 720p; Wi‑Fi использует выбранное качество. При нерабочей раздаче приложение само попробует следующую подходящую. Запросы Jacred выполняются по очереди и повторяются после ограничения сервера.\n\n«Готовить раздачу заранее»: пока открыта страница фильма, его раздача уже подключается к пирам. Тратит немного трафика.")
            }

            Section {
                Toggle("Автопереход к следующей серии", isOn: $autoNext)
                Toggle("Запоминать скорость и пропорции", isOn: $savePlayerSettings)
                Toggle("Звук в фоне", isOn: $backgroundAudio)
                Toggle("Восстанавливать после зависания", isOn: $automaticRecovery)
                Toggle("Готовить следующую серию", isOn: $preloadNextEpisode)
                Toggle("Жесты в плеере", isOn: $playerGestures)
            } header: {
                Text("Плеер")
            } footer: {
                Text("При зависании поток переподключится с сохранённого места, затем попробует более лёгкую раздачу. Следующая серия заранее получает небольшой начальный буфер только не в мобильной сети.\n\nЖесты: по горизонтали — перемотка, слева по вертикали — яркость, справа — громкость.")
            }

            Section {
                HStack {
                    Text("Торрент-движок")
                    Spacer()
                    Text(engineStatus)
                        .foregroundStyle(Theme.secondary)
                }
                Button("Проверить и запустить движок") {
                    Task {
                        engineStatus = "Запуск…"
                        do {
                            try await TorrServer.shared.ensureRunning()
                        } catch {
                            message = error.localizedDescription
                        }
                        await refreshStatus()
                    }
                }
                Button("Очистить список торрентов", role: .destructive) {
                    Task {
                        await TorrServer.shared.wipe()
                        message = "Список торрентов очищен"
                    }
                }
            } header: {
                Text("Торренты")
            } footer: {
                Text("Встроенный TorrServer MatriX раздаёт видео плееру прямо на устройстве. Видео не скачивается целиком — кэш в памяти.")
            }

            Section {
                HStack {
                    Text("Кэш Кинопоиска")
                    Spacer()
                    Text(cacheSize)
                        .foregroundStyle(Theme.secondary)
                }
                Button("Очистить кэш", role: .destructive) {
                    KPClient.shared.clearCache()
                    URLCache.shared.removeAllCachedResponses()
                    cacheSize = KPClient.shared.cacheSizeText
                    message = "Кэш очищен"
                }
                if !library.data.blockedReleaseIDs.isEmpty {
                    Button("Вернуть скрытые раздачи (\(library.data.blockedReleaseIDs.count))") {
                        library.clearBlockedReleases()
                        message = "Скрытые раздачи снова будут предлагаться"
                    }
                }
            } header: {
                Text("Данные")
            }

            Section {
                if let backupURL = backupURL {
                    ShareLink(item: backupURL) {
                        Label("Экспортировать резервную копию", systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    importingBackup = true
                } label: {
                    Label("Восстановить из файла", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Резервная копия")
            } footer: {
                Text("Сохраняются медиатека, прогресс, история, свои раздачи и обычные настройки. Ключи API и адрес плейлиста в файл не попадают.")
            }

            Section {
                HStack {
                    Text("Размер журнала")
                    Spacer()
                    Text(diagnosticsSize)
                        .foregroundStyle(Theme.secondary)
                }
                DiagnosticsReportLink()
                    .id(reportVersion)
                Button("Очистить журнал", role: .destructive) {
                    AppDiagnostics.shared.clear()
                    diagnosticsSize = AppDiagnostics.shared.sizeText
                    reportVersion += 1
                    message = "Журнал диагностики очищен"
                }
            } header: {
                Text("Диагностика")
            } footer: {
                Text("Отчёт хранится только на iPhone: события плеера и движка, память, зависания, сбои прошлых запусков и системные отчёты iOS (MetricKit). Он отправляется только через кнопку выше — например, в Telegram или по почте.")
            }

            Section {
                HStack {
                    Text("Версия")
                    Spacer()
                    Text(AppInfo.version)
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Настройки")
        .navigationBarTitleDisplayMode(.inline)
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .fileImporter(isPresented: $importingBackup, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                do {
                    let backup = try BackupService.load(from: url)
                    backup.settings.apply()
                    library.replaceData(backup.library)
                    backupURL = BackupService.exportURL(library: library.data)
                    message = "Резервная копия восстановлена"
                } catch {
                    message = error.localizedDescription
                }
            case .failure(let error):
                message = error.localizedDescription
            }
        }
        .task {
            cacheSize = KPClient.shared.cacheSizeText
            diagnosticsSize = AppDiagnostics.shared.sizeText
            backupURL = BackupService.exportURL(library: library.data)
            await refreshStatus()
        }
    }

    private func checkSearch() {
        checkingSearch = true
        Task {
            defer { checkingSearch = false }
            let query = TorrentSearchQuery(title: "Матрица", originalTitle: "The Matrix", year: 1999, isSeries: false)
            do {
                let result = try await TorrentSearchService.shared.search(query, force: true)
                if result.releases.isEmpty {
                    message = "Сервер ответил, но раздач «Матрицы» не нашёл (результатов: \(result.found)). Проверьте адрес и API-ключ."
                } else {
                    message = "Поиск работает. Раздач «Матрицы»: \(result.releases.count)."
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private var playlistSummary: String {
        if playlistURL.isEmpty { return "не задан" }
        if playlistURL == ChannelsStore.localMarker { return "файл" }
        return URL(string: playlistURL)?.host ?? playlistURL
    }

    private func refreshStatus() async {
        let ok = await TorrServer.shared.ping()
        if ok {
            engineStatus = "работает"
        } else if let error = TorrServer.shared.startError {
            engineStatus = "ошибка: \(error)"
        } else {
            engineStatus = "не отвечает"
        }
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
                Text("• Каталог, поиск, описания, рейтинги, сезоны и актёры — из неофициального API Кинопоиска.\n• Раздачи находятся автоматически через Jacred / Jackett. Можно выбрать качество и озвучку; нерабочая раздача заменяется автоматически.\n• «Смотреть позже», персональные рекомендации, недавние ТВ-каналы и сортировка медиатеки.\n• Плеер VLCKit: жесты, блокировка управления, таймер сна, запоминание дорожек и обратный отсчёт до следующей серии.\n• Медиатеку и прогресс можно экспортировать и восстановить; секретные ключи в копию не попадают.\n• Локальный журнал и системные отчёты о сбоях экспортируются только вручную из настроек.\n• Свои magnet, .torrent, прямые ссылки, HLS и M3U-телеканалы.")
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
