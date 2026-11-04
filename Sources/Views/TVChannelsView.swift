import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What the «ТВ-каналы» screen shows.
enum TVFilter: Hashable {
    case all
    case favorites
    case recent
    case group(TVGroup)
    case playlist
}

/// Built-in channels by sections, favourites, recent ones and the channels of the user's M3U playlist.
struct TVChannelsView: View {
    @EnvironmentObject private var channels: ChannelsStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @AppStorage(SettingsKeys.playlistURL) private var playlistURL = ""
    @State private var filter: TVFilter = .all
    @State private var playlistGroup: String?
    @State private var query = ""
    @State private var showSetup = false

    private var hasPlaylist: Bool { !playlistURL.trimmed.isEmpty }

    /// Saved built-in channels get the current name and logo of the catalog.
    private var favorites: [Channel] {
        library.data.favoriteChannels.map(\.refreshed).uniqued(by: \.url)
    }

    private var recents: [Channel] {
        library.data.recentChannels.map(\.refreshed).uniqued(by: \.url)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if query.trimmed.isEmpty {
                        chips
                    }
                    content
                }
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.immediately)
            .background(Theme.background)
            .navigationTitle("ТВ-каналы")
            .searchable(text: $query, prompt: "Поиск канала")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showSetup = true
                        } label: {
                            Label(hasPlaylist ? "Сменить плейлист" : "Добавить плейлист M3U", systemImage: "list.bullet.rectangle")
                        }
                        if hasPlaylist {
                            Button {
                                Task { await channels.reload() }
                            } label: {
                                Label("Обновить плейлист", systemImage: "arrow.clockwise")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Плейлист")
                }
            }
            .sheet(isPresented: $showSetup) {
                NavigationStack {
                    PlaylistSetupView(onDone: { showSetup = false })
                        .navigationTitle("Плейлист")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Закрыть") { showSetup = false }
                            }
                        }
                }
            }
            .task(id: playlistURL) {
                await channels.loadIfNeeded()
            }
            .onChange(of: playlistURL) { old, new in
                // A playlist just added opens at once; a removed one returns to the built-in channels.
                if !new.trimmed.isEmpty, new != old {
                    playlistGroup = nil
                    filter = .playlist
                } else if new.trimmed.isEmpty, filter == .playlist {
                    filter = .all
                }
            }
        }
    }

    // MARK: Chips

    private var chips: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("Все", .all)
                    if !favorites.isEmpty || filter == .favorites {
                        chip("Избранные", .favorites)
                    }
                    if !recents.isEmpty || filter == .recent {
                        chip("Недавние", .recent)
                    }
                    if hasPlaylist {
                        chip("Мой плейлист", .playlist)
                    }
                    ForEach(TVGroup.allCases, id: \.self) { group in
                        chip(group.title, .group(group))
                    }
                }
                .padding(.horizontal, 16)
            }
            if filter == .playlist, channels.groups.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Chip(title: "Все группы", selected: playlistGroup == nil) { playlistGroup = nil }
                        ForEach(channels.groups, id: \.self) { name in
                            Chip(title: name, selected: playlistGroup == name) { playlistGroup = name }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private func chip(_ title: String, _ value: TVFilter) -> some View {
        Chip(title: title, selected: filter == value) { filter = value }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let q = query.trimmed
        if !q.isEmpty {
            searchResults(q)
        } else {
            switch filter {
            case .all:
                ForEach(TVGroup.allCases, id: \.self) { group in
                    let list = TVCatalog.all.filter { $0.primaryGroup == group }.map(\.channel)
                    if !list.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: group.title)
                            grid(list)
                        }
                        .padding(.bottom, 6)
                    }
                }
                Text("Официальные бесплатные трансляции телеканалов. Эфирные каналы показывают только в России: с включённым VPN они могут не открыться.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 16)
            case .group(let group):
                grid(TVCatalog.channels(in: group).map(\.channel))
            case .favorites:
                if favorites.isEmpty {
                    empty("Нет избранных каналов", "Удерживайте канал и выберите «В избранное».")
                } else {
                    grid(favorites)
                }
            case .recent:
                if recents.isEmpty {
                    empty("Нет недавних каналов", "Здесь появятся каналы, которые вы смотрели.")
                } else {
                    grid(recents)
                }
            case .playlist:
                playlistContent
            }
        }
    }

    @ViewBuilder
    private func searchResults(_ q: String) -> some View {
        let builtIn = TVCatalog.search(q).map(\.channel)
        let fromPlaylist = playlistMatches(q)
        if builtIn.isEmpty && fromPlaylist.isEmpty {
            empty("Каналы не найдены", "Попробуйте другое название.")
        } else {
            if !builtIn.isEmpty {
                if !fromPlaylist.isEmpty {
                    SectionHeader(title: "Встроенные")
                }
                grid(builtIn)
            }
            if !fromPlaylist.isEmpty {
                SectionHeader(title: "Мой плейлист")
                grid(fromPlaylist)
            }
        }
    }

    private func playlistMatches(_ q: String) -> [Channel] {
        let needle = TextMatch.normalized(q)
        guard !needle.isEmpty, hasPlaylist else { return [] }
        let found = channels.channels.filter { TextMatch.normalized($0.name).contains(needle) }
        return Array(found.uniqued(by: \.url).prefix(200))
    }

    @ViewBuilder
    private var playlistContent: some View {
        if !hasPlaylist {
            VStack(spacing: 12) {
                empty("Плейлист не задан", "Добавьте ссылку на M3U-плейлист или файл .m3u.")
                Button("Добавить плейлист") { showSetup = true }
                    .prominentButtonStyle()
            }
            .frame(maxWidth: .infinity)
        } else if channels.isLoading && channels.channels.isEmpty {
            ProgressView("Загрузка плейлиста…")
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        } else if let error = channels.error, channels.channels.isEmpty {
            VStack(spacing: 6) {
                ErrorView(message: error) { Task { await channels.reload() } }
                Button("Сменить плейлист") { showSetup = true }
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.top, 40)
        } else if playlistChannels.isEmpty {
            empty("В плейлисте нет каналов", "Проверьте ссылку или выберите другой файл.")
        } else {
            grid(playlistChannels)
        }
    }

    private var playlistChannels: [Channel] {
        let all = channels.channels
        let list = playlistGroup.map { group in all.filter { $0.group == group } } ?? all
        // Playlists often repeat a channel; the grid needs unique ids.
        return list.uniqued(by: \.url)
    }

    private func empty(_ title: String, _ text: String) -> some View {
        ContentUnavailableView(title, systemImage: "tv", description: Text(text))
            .padding(.top, 40)
    }

    private func grid(_ list: [Channel]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 12, alignment: .top)],
                  alignment: .leading, spacing: 18) {
            ForEach(list) { channel in
                ChannelTile(channel: channel, favorite: library.isFavoriteChannel(channel)) {
                    ChannelPlayback.play(channel, library: library, coordinator: coordinator)
                }
                .contextMenu {
                    Button {
                        library.toggleFavoriteChannel(channel)
                    } label: {
                        if library.isFavoriteChannel(channel) {
                            Label("Убрать из избранного", systemImage: "heart.slash")
                        } else {
                            Label("В избранное", systemImage: "heart")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

/// Starting a channel from any screen: it goes to the recent ones, a built-in channel opens by
/// its "tv:" link (the player asks the broadcaster for the stream).
@MainActor
enum ChannelPlayback {
    static func play(_ channel: Channel, library: LibraryStore, coordinator: PlayerCoordinator) {
        let fresh = channel.refreshed
        library.addRecentChannel(fresh)
        coordinator.play(PlayRequest(title: fresh.name, link: fresh.url, isLive: true,
                                     userAgent: fresh.isBuiltIn ? TVNet.userAgent : fresh.userAgent,
                                     referrer: fresh.referrer))
    }
}

/// A channel in the grid: the logo card, the name and what is on the air.
struct ChannelTile: View {
    let channel: Channel
    let favorite: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ChannelArtwork(channel: channel)
                    .overlay(alignment: .topTrailing) {
                        if favorite {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .glassSurface(Circle(), style: .clear)
                                .padding(6)
                        }
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text(channel.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    ChannelNowLine(channel: channel)
                }
                .padding(.horizontal, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(TilePressStyle())
    }
}

/// The card of a channel: the logo of a built-in channel fills it, a playlist logo sits on a dark card.
struct ChannelArtwork: View {
    let channel: Channel
    var cornerRadius: CGFloat = 14

    var body: some View {
        Color.clear
            .aspectRatio(100.0 / 55.0, contentMode: .fit)
            .overlay { picture }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.75)
            }
    }

    @ViewBuilder
    private var picture: some View {
        if let name = channel.assetName, let image = UIImage(named: name) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Theme.card
                if let logo = channel.logo, !channel.isBuiltIn, let url = URL(string: logo) {
                    PosterImage(url: url, mode: .fit, maxPixel: 400, placeholder: false)
                        .padding(12)
                } else {
                    Text(channel.initials)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
    }
}

/// What is on the air now with its progress (the guide of a built-in channel); a playlist
/// channel shows its group.
struct ChannelNowLine: View {
    let channel: Channel
    @ObservedObject var guide = TVGuide.shared

    var body: some View {
        let tv = TVCatalog.channel(forLink: channel.url)
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let programme = tv.flatMap { guide.now(for: $0.id, at: context.date) }
            VStack(alignment: .leading, spacing: 6) {
                Text(programme?.title ?? placeholder(tv))
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                ProgressCapsule(value: programme?.progress(at: context.date) ?? 0)
                    .opacity(programme == nil ? 0 : 1)
            }
        }
        .task(id: tv?.id) {
            if let tv = tv { await guide.load(tv) }
        }
    }

    /// Keeps the height of the tiles equal while the guide loads or when there is none.
    private func placeholder(_ tv: TVChannel?) -> String {
        if tv != nil { return " " }
        return channel.group?.nonEmpty ?? "Плейлист"
    }
}

struct ProgressCapsule: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule().fill(Color.white.opacity(0.85))
                    .frame(width: CGFloat(max(0, min(1, value))) * geo.size.width)
            }
        }
        .frame(height: 3)
    }
}

/// A tile shrinks a little under the finger.
struct TilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(duration: 0.22), value: configuration.isPressed)
    }
}

struct PlaylistSetupView: View {
    @EnvironmentObject private var channels: ChannelsStore
    @AppStorage(SettingsKeys.playlistURL) private var playlistURL = ""
    @State private var draft = ""
    @State private var importing = false
    var onDone: (() -> Void)? = nil

    private var playlistTypes: [UTType] {
        [UTType(filenameExtension: "m3u"), UTType(filenameExtension: "m3u8")].compactMap { $0 } + [.plainText, .data]
    }

    private var draftIsValid: Bool {
        guard let url = URL(string: draft.trimmed), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    var body: some View {
        Form {
            Section {
                TextField("https://…/playlist.m3u", text: $draft)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in
                        if let first = strings.first { draft = first.trimmed }
                    }
                }
                Button("Загрузить каналы") { apply() }
                    .disabled(!draftIsValid)
            } header: {
                Text("Ссылка на плейлист M3U")
            } footer: {
                Text("Укажите ссылку на свой IPTV-плейлист (например, от провайдера). Его каналы появятся в разделе «ТВ-каналы» под кнопкой «Мой плейлист» — с названиями, группами и логотипами из плейлиста. Встроенные каналы работают и без него.")
            }

            Section {
                Button {
                    importing = true
                } label: {
                    HStack {
                        Label("Выбрать файл .m3u", systemImage: "folder")
                        if channels.isLoading {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(channels.isLoading)
            } footer: {
                if let error = channels.error {
                    Text(error)
                }
            }

            if !playlistURL.isEmpty {
                Section {
                    Button("Удалить плейлист", role: .destructive) {
                        playlistURL = ""
                        channels.clear()
                        onDone?()
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .fileImporter(isPresented: $importing, allowedContentTypes: playlistTypes) { result in
            guard case .success(let url) = result else { return }
            Task {
                if await channels.importFile(url) {
                    playlistURL = ChannelsStore.localMarker
                    onDone?()
                }
            }
        }
        .onAppear {
            if draft.isEmpty && !playlistURL.hasPrefix("local:") {
                draft = playlistURL
            }
        }
    }

    private func apply() {
        let value = draft.trimmed
        if value == playlistURL {
            Task { await channels.reload() }
        } else {
            playlistURL = value
        }
        onDone?()
    }
}
