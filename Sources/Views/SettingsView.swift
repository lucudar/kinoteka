import SwiftUI
import UniformTypeIdentifiers

// MARK: - Rows

/// A colored square with a symbol, like in the iOS Settings app.
struct SettingsIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct SettingsRow: View {
    let title: String
    let icon: String
    let color: Color
    var value: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(systemName: icon, color: color)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let value, !value.isEmpty {
                Text(value)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private extension View {
    func settingsPage(_ title: String) -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }

    func messageAlert(_ message: Binding<String?>) -> some View {
        alert(message.wrappedValue ?? "",
              isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }
}

// MARK: - Main screen

/// Settings are grouped like in iOS: one short list, every group on its own page.
struct SettingsView: View {
    @ObservedObject private var downloads = DownloadManager.shared
    @AppStorage(SettingsKeys.kpToken) private var token = ""
    @AppStorage(SettingsKeys.playlistURL) private var playlistURL = ""
    @AppStorage(SettingsKeys.preferredQuality) private var preferredQuality = ReleaseQuality.fullHD.rawValue
    @AppStorage(SettingsKeys.preferredVoice) private var preferredVoice = "auto"
    @AppStorage(SettingsKeys.searchServer) private var searchServer = TorrentSearchService.defaultServer
    @AppStorage(SettingsKeys.zonaIndex) private var zonaIndex = true
    @AppStorage(SettingsKeys.subtitleAuto) private var subtitleAuto = false
    @AppStorage(SettingsKeys.subtitleLanguage) private var subtitleLanguage = "ru"
    @AppStorage(SettingsKeys.openSubtitlesKey) private var openSubtitlesKey = ""
    @AppStorage(SettingsKeys.downloadsWifiOnly) private var downloadsWifiOnly = true
    @AppStorage(SettingsKeys.pipAuto) private var pipAuto = false
    @AppStorage(SettingsKeys.playerGestures) private var playerGestures = true
    @State private var engineStatus = ""
    @State private var cacheSize = ""
    @State private var diagnosticsSize = ""

    var body: some View {
        List {
            Section {
                NavigationLink {
                    PlayerSettingsView()
                } label: {
                    SettingsRow(title: "Плеер", icon: "play.rectangle.fill", color: .blue, value: playerSummary)
                }
                NavigationLink {
                    ReleaseSettingsView()
                } label: {
                    SettingsRow(title: "Качество и озвучка", icon: "sparkles", color: .purple, value: qualitySummary)
                }
                NavigationLink {
                    SubtitleSettingsView()
                } label: {
                    SettingsRow(title: "Субтитры", icon: "captions.bubble.fill", color: .orange, value: subtitleSummary)
                }
                NavigationLink {
                    DownloadSettingsView()
                } label: {
                    SettingsRow(title: "Загрузки", icon: "arrow.down.circle.fill", color: .green, value: downloadsSummary)
                }
            }

            Section {
                NavigationLink {
                    KinopoiskSettingsView()
                } label: {
                    SettingsRow(title: "Кинопоиск", icon: "film.fill", color: .orange,
                                value: token.trimmed.isEmpty ? "без ключа" : "ключ задан")
                }
                NavigationLink {
                    PlaylistSetupView()
                        .navigationTitle("Плейлист")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    SettingsRow(title: "ТВ-каналы", icon: "tv.fill", color: .indigo, value: playlistSummary)
                }
                NavigationLink {
                    SearchSettingsView()
                } label: {
                    SettingsRow(title: "Поиск раздач", icon: "magnifyingglass", color: .teal, value: searchSummary)
                }
                NavigationLink {
                    EngineSettingsView()
                } label: {
                    SettingsRow(title: "Торрент-движок", icon: "bolt.horizontal.fill", color: .gray, value: engineStatus)
                }
            }

            Section {
                NavigationLink {
                    DataSettingsView()
                } label: {
                    SettingsRow(title: "Данные и резервная копия", icon: "externaldrive.fill", color: .brown, value: cacheSize)
                }
                NavigationLink {
                    DiagnosticsSettingsView()
                } label: {
                    SettingsRow(title: "Диагностика", icon: "stethoscope", color: .red, value: diagnosticsSize)
                }
            }

            Section {
                LabeledContent("Версия", value: AppInfo.version)
            }
        }
        .settingsPage("Настройки")
        .task {
            cacheSize = KPClient.shared.cacheSizeText
            diagnosticsSize = AppDiagnostics.shared.sizeText
            engineStatus = await TorrServer.shared.ping() ? "работает" : "не отвечает"
        }
    }

    private var playerSummary: String {
        var parts: [String] = []
        if pipAuto { parts.append("авто-PiP") }
        if playerGestures { parts.append("жесты") }
        return parts.joined(separator: ", ")
    }

    private var qualitySummary: String {
        let quality = ReleaseQuality(rawValue: preferredQuality)?.title ?? ""
        let voice = ReleaseVoiceOption.fromSetting(preferredVoice)?.title ?? "авто"
        return "\(quality), \(voice.lowercased())"
    }

    private var subtitleSummary: String {
        if openSubtitlesKey.trimmed.isEmpty { return "нет ключа" }
        let language = SubtitleService.languageTitle(subtitleLanguage).lowercased()
        return subtitleAuto ? "\(language), авто" : language
    }

    private var downloadsSummary: String {
        let count = downloads.items.filter { $0.state == .completed }.count
        let unfinished = downloads.items.filter(\.isUnfinished).count
        if unfinished > 0 { return "в очереди \(unfinished)" }
        if count > 0 { return downloads.usedText }
        return downloadsWifiOnly ? "только Wi‑Fi" : ""
    }

    private var searchSummary: String {
        let host = URL(string: searchServer.trimmed)?.host ?? searchServer
        return zonaIndex ? "Zona + \(host)" : host
    }

    private var playlistSummary: String {
        if playlistURL.isEmpty { return "не задан" }
        if playlistURL == ChannelsStore.localMarker { return "файл" }
        return URL(string: playlistURL)?.host ?? playlistURL
    }
}

// MARK: - Player

struct PlayerSettingsView: View {
    @AppStorage(SettingsKeys.autoNext) private var autoNext = true
    @AppStorage(SettingsKeys.savePlayerSettings) private var savePlayerSettings = true
    @AppStorage(SettingsKeys.backgroundAudio) private var backgroundAudio = true
    @AppStorage(SettingsKeys.automaticRecovery) private var automaticRecovery = true
    @AppStorage(SettingsKeys.preloadNextEpisode) private var preloadNextEpisode = true
    @AppStorage(SettingsKeys.playerGestures) private var playerGestures = true
    @AppStorage(SettingsKeys.pipAuto) private var pipAuto = false

    var body: some View {
        Form {
            Section {
                Toggle("Автопереход к следующей серии", isOn: $autoNext)
                Toggle("Готовить следующую серию", isOn: $preloadNextEpisode)
                Toggle("Восстанавливать после зависания", isOn: $automaticRecovery)
                Toggle("Запоминать скорость и пропорции", isOn: $savePlayerSettings)
            } footer: {
                Text("При зависании поток переподключится с того же места, затем попробует более лёгкую раздачу.")
            }

            Section {
                Toggle("Жесты", isOn: $playerGestures)
            } footer: {
                Text("По горизонтали — перемотка, слева по вертикали — яркость, справа — громкость. Двойное касание — 10 секунд назад или вперёд.")
            }

            Section {
                Toggle("Звук в фоне", isOn: $backgroundAudio)
                Toggle("Картинка в картинке при выходе", isOn: $pipAuto)
            } header: {
                Text("Когда приложение свёрнуто")
            } footer: {
                Text("Кнопка ⧉ в плеере сворачивает видео в окно поверх других приложений — можно листать каталог. С переключателем видео уходит в окно само при выходе на домашний экран (со следующего запуска видео).")
            }
        }
        .settingsPage("Плеер")
    }
}

// MARK: - Quality and voice

struct ReleaseSettingsView: View {
    @ObservedObject private var network = NetworkMonitor.shared
    @AppStorage(SettingsKeys.preferredQuality) private var preferredQuality = ReleaseQuality.fullHD.rawValue
    @AppStorage(SettingsKeys.preferredVoice) private var preferredVoice = "auto"
    @AppStorage(SettingsKeys.autoPlayBest) private var autoPlayBest = true
    @AppStorage(SettingsKeys.prepareTorrent) private var prepareTorrent = true
    @AppStorage(SettingsKeys.smartQuality) private var smartQuality = true
    @AppStorage(SettingsKeys.automaticFallback) private var automaticFallback = true

    var body: some View {
        Form {
            Section {
                Picker("Качество", selection: $preferredQuality) {
                    ForEach(ReleaseQuality.choices) { quality in
                        Text(quality.title).tag(quality.rawValue)
                    }
                }
                Picker("Озвучка", selection: $preferredVoice) {
                    Text("Авто").tag("auto")
                    ForEach(VoiceKind.audioChoices, id: \.rawValue) { voice in
                        Text(voice.title).tag(ReleaseVoiceOption.kind(voice).settingValue)
                    }
                }
                Toggle("Сразу включать лучшую раздачу", isOn: $autoPlayBest)
            }

            Section {
                Toggle("Автокачество по сети", isOn: $smartQuality)
                Toggle("Менять нерабочую раздачу", isOn: $automaticFallback)
                Toggle("Готовить раздачу заранее", isOn: $prepareTorrent)
                LabeledContent("Сейчас", value: network.title)
            } footer: {
                Text("В мобильной сети качество ограничивается 720p. «Готовить заранее»: пока открыта страница фильма, скачиваются начало и конец видео — плеер стартует быстрее.")
            }
        }
        .settingsPage("Качество и озвучка")
    }
}

// MARK: - Subtitles

struct SubtitleSettingsView: View {
    @AppStorage(SettingsKeys.openSubtitlesKey) private var apiKey = ""
    @AppStorage(SettingsKeys.openSubtitlesUser) private var username = ""
    @AppStorage(SettingsKeys.subtitleLanguage) private var language = "ru"
    @AppStorage(SettingsKeys.subtitleEnglishFallback) private var englishFallback = true
    @AppStorage(SettingsKeys.subtitleAuto) private var automatic = false
    @State private var password = ""
    @State private var hasPassword = KeychainStore.string(SubtitleService.passwordAccount) != nil
    @State private var checking = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Picker("Язык", selection: $language) {
                    ForEach(SubtitleService.languageChoices, id: \.code) { choice in
                        Text(choice.title).tag(choice.code)
                    }
                }
                if language != "en" {
                    Toggle("Если нет — английские", isOn: $englishFallback)
                }
                Toggle("Искать автоматически", isOn: $automatic)
                    .disabled(apiKey.trimmed.isEmpty)
            } footer: {
                Text("Автоматически — когда у видео нет русской озвучки и русских субтитров: лучшие найденные субтитры включатся сами. Вручную: в плеере кнопка настроек → Субтитры → «Найти в интернете».")
            }

            Section {
                SecureField("Ключ API", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in
                        if let first = strings.first { apiKey = first.trimmed }
                    }
                }
                if let url = SubtitleService.keyPage {
                    Link(destination: url) {
                        Label("Получить ключ бесплатно", systemImage: "arrow.up.right.square")
                    }
                }
            } header: {
                Text("OpenSubtitles")
            } footer: {
                Text("Зарегистрируйтесь на opensubtitles.com, откройте «API consumers», создайте ключ и вставьте сюда.")
            }

            Section {
                TextField("Имя пользователя", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                SecureField(hasPassword ? "Пароль сохранён" : "Пароль", text: $password)
                    .textContentType(.password)
                    .onSubmit(savePassword)
                Button {
                    savePassword()
                    checkLogin()
                } label: {
                    HStack {
                        Text("Проверить вход")
                        Spacer()
                        if checking { ProgressView() }
                    }
                }
                .disabled(checking || apiKey.trimmed.isEmpty || username.trimmed.isEmpty)
                if hasPassword {
                    Button("Выйти", role: .destructive) {
                        KeychainStore.set(nil, for: SubtitleService.passwordAccount)
                        SubtitleService.shared.forgetLogin()
                        hasPassword = false
                        password = ""
                    }
                }
            } header: {
                Text("Аккаунт (необязательно)")
            } footer: {
                Text("Без входа OpenSubtitles даёт несколько скачиваний в день, с бесплатным аккаунтом — 20. Пароль хранится в связке ключей iPhone.")
            }
        }
        .settingsPage("Субтитры")
        .messageAlert($message)
        .onChange(of: apiKey) { _, _ in SubtitleService.shared.forgetLogin() }
    }

    private func savePassword() {
        let value = password.trimmed
        guard !value.isEmpty else { return }
        KeychainStore.set(value, for: SubtitleService.passwordAccount)
        SubtitleService.shared.forgetLogin()
        hasPassword = true
        password = ""
    }

    private func checkLogin() {
        checking = true
        Task {
            defer { checking = false }
            do {
                SubtitleService.shared.forgetLogin()
                try await SubtitleService.shared.login(user: username.trimmed)
                message = "Вход выполнен"
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

// MARK: - Downloads

struct DownloadSettingsView: View {
    @ObservedObject private var downloads = DownloadManager.shared
    @AppStorage(SettingsKeys.downloadsWifiOnly) private var wifiOnly = true
    @AppStorage(SettingsKeys.downloadsPauseWhileWatching) private var pauseWhileWatching = true
    @AppStorage(SettingsKeys.downloadsKeepAwake) private var keepAwake = false
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    DownloadsView()
                } label: {
                    LabeledContent("Загрузки", value: downloads.items.isEmpty ? "нет" : "\(downloads.items.count)")
                }
                LabeledContent("Занято", value: downloads.usedText)
                if let free = downloads.freeText {
                    LabeledContent("Свободно на iPhone", value: free)
                }
            }

            Section {
                Toggle("Только по Wi‑Fi", isOn: $wifiOnly)
                Toggle("Пауза во время просмотра", isOn: $pauseWhileWatching)
                Toggle("Не гасить экран", isOn: $keepAwake)
            } footer: {
                Text("Файлы качаются, пока Кинотека открыта: iOS приостанавливает приложение вскоре после выхода. Для долгой загрузки включите «Не гасить экран» и поставьте iPhone на зарядку. Пауза во время просмотра отдаёт всю скорость плееру.")
            }

            if !downloads.items.isEmpty {
                Section {
                    Button("Удалить все загрузки", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .settingsPage("Загрузки")
        .confirmationDialog("Удалить все загрузки?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { downloads.removeAll() }
        } message: {
            Text("Скачанные файлы будут удалены с iPhone.")
        }
    }
}

// MARK: - Kinopoisk

struct KinopoiskSettingsView: View {
    @AppStorage(SettingsKeys.kpToken) private var token = ""

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
            } footer: {
                Text(token.trimmed.isEmpty
                     ? "Необязательно: без ключа каталог и описания берутся из индекса Zona. С ключом — подробнее: названия серий, возрастной рейтинг, трейлеры. Бесплатно — 500 запросов в сутки."
                     : "Ключ сохранён. Если Кинопоиск не отвечает или лимит исчерпан, каталог временно берётся из индекса Zona.")
            }
        }
        .settingsPage("Кинопоиск")
    }
}

// MARK: - Torrent search

struct SearchSettingsView: View {
    @AppStorage(SettingsKeys.searchServer) private var searchServer = TorrentSearchService.defaultServer
    @AppStorage(SettingsKeys.searchApiKey) private var searchApiKey = ""
    @AppStorage(SettingsKeys.zonaIndex) private var zonaIndex = true
    @State private var checking = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Toggle("Индекс Zona", isOn: $zonaIndex)
                    .onChange(of: zonaIndex) { _, _ in
                        TorrentSearchService.shared.clearCache()
                    }
            } footer: {
                Text("Раздачи, как в Zona, — с распознанными озвучкой и качеством. Сервер в России, работает без VPN.")
            }

            Section {
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
                        if checking { ProgressView() }
                    }
                }
                .disabled(checking)
                if searchServer.trimmed != TorrentSearchService.defaultServer {
                    Button("Вернуть сервер по умолчанию") {
                        searchServer = TorrentSearchService.defaultServer
                        searchApiKey = ""
                        TorrentSearchService.shared.clearCache()
                    }
                }
            } header: {
                Text("Jacred / Jackett")
            } footer: {
                Text("Одинаковые раздачи из Zona и jac.red объединяются. Если jac.red не отвечает, поиск сам переходит на зеркала в России.")
            }
        }
        .settingsPage("Поиск раздач")
        .messageAlert($message)
    }

    private func checkSearch() {
        checking = true
        Task {
            defer { checking = false }
            let query = TorrentSearchQuery(title: "Матрица", originalTitle: "The Matrix", year: 1999, isSeries: false)
            do {
                let result = try await TorrentSearchService.shared.search(query, force: true)
                let host = result.server.flatMap(SearchMirrors.host).map { " Ответил \($0)." } ?? ""
                if result.releases.isEmpty {
                    message = "Сервер ответил, но раздач «Матрицы» не нашёл (результатов: \(result.found)). Проверьте адрес и API-ключ." + host
                } else {
                    message = "Поиск работает. Раздач «Матрицы»: \(result.releases.count)." + host
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

// MARK: - Torrent engine

struct EngineSettingsView: View {
    @ObservedObject private var network = NetworkMonitor.shared
    @AppStorage(SettingsKeys.engineEncryption) private var engineEncryption = EngineEncryptionMode.automatic.rawValue
    @State private var engineStatus = "Проверка…"
    @State private var profileText = ""
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Состояние", value: engineStatus)
                Button("Проверить и запустить") {
                    Task {
                        engineStatus = "Запуск…"
                        do {
                            try await TorrServer.shared.ensureRunning(retune: true)
                        } catch {
                            message = error.localizedDescription
                        }
                        await refreshStatus()
                    }
                }
                if !profileText.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Настройка под сеть")
                        Text(profileText)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondary)
                    }
                }
            } footer: {
                Text("Встроенный TorrServer сам настраивается под сеть: по Wi‑Fi — большой буфер и до 60 пиров, в мобильной сети — меньше буфер и только TCP.")
            }

            Section {
                Picker("Шифрование", selection: $engineEncryption) {
                    ForEach(EngineEncryptionMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
            } footer: {
                Text("«Всегда» — только зашифрованные соединения: оператору труднее замедлить торрент, но пиров меньше.")
            }

            Section {
                Button("Очистить список торрентов", role: .destructive) {
                    Task {
                        await TorrServer.shared.wipe()
                        message = "Список торрентов очищен"
                    }
                }
            }
        }
        .settingsPage("Торрент-движок")
        .messageAlert($message)
        .task { await refreshStatus() }
        .onChange(of: engineEncryption) { _, _ in
            refreshProfile()
            Task {
                // Retuning closes the torrents of the engine, so not while a film plays.
                let server = TorrServer.shared
                if server.isRunning, !server.isPlayerActive {
                    try? await server.ensureRunning(retune: true)
                }
                refreshProfile()
            }
        }
        .onChange(of: network.connection) { _, _ in refreshProfile() }
    }

    /// What the engine runs with now, or what it will use for the current network.
    private func refreshProfile() {
        let server = TorrServer.shared
        let desired = server.desiredProfile
        if let active = server.activeProfile, active != desired {
            profileText = active.summary + "\nДля текущей сети — при открытии фильма: " + desired.summary
        } else {
            profileText = desired.summary
        }
    }

    private func refreshStatus() async {
        refreshProfile()
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

// MARK: - Data and backup

struct DataSettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var cacheSize = ""
    @State private var message: String?
    @State private var importingBackup = false
    @State private var backupURL: URL?

    var body: some View {
        Form {
            Section {
                LabeledContent("Кэш каталога", value: cacheSize)
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
            }

            Section {
                if let backupURL {
                    ShareLink(item: backupURL) {
                        Label("Экспортировать", systemImage: "square.and.arrow.up")
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
                Text("Медиатека, прогресс, история, свои раздачи и настройки. Ключи API и адрес плейлиста в файл не попадают.")
            }
        }
        .settingsPage("Данные")
        .messageAlert($message)
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
            backupURL = BackupService.exportURL(library: library.data)
        }
    }
}

// MARK: - Diagnostics

struct DiagnosticsSettingsView: View {
    @State private var diagnosticsSize = ""
    @State private var reportVersion = 0
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    NetworkCheckView()
                } label: {
                    Label("Проверка сети", systemImage: "network")
                }
            } footer: {
                Text("Что доступно в текущей сети без VPN: Zona, Кинопоиск, поиск раздач, трекеры, DHT и реальная скорость торрента.")
            }

            Section {
                LabeledContent("Размер журнала", value: diagnosticsSize)
                DiagnosticsReportLink()
                    .id(reportVersion)
                Button("Очистить журнал", role: .destructive) {
                    AppDiagnostics.shared.clear()
                    diagnosticsSize = AppDiagnostics.shared.sizeText
                    reportVersion += 1
                    message = "Журнал диагностики очищен"
                }
            } footer: {
                Text("Отчёт хранится только на iPhone и отправляется только этой кнопкой — например, в Telegram.")
            }
        }
        .settingsPage("Диагностика")
        .messageAlert($message)
        .task { diagnosticsSize = AppDiagnostics.shared.sizeText }
    }
}
