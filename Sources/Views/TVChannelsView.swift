import SwiftUI
import UniformTypeIdentifiers

struct TVChannelsView: View {
    @EnvironmentObject private var channels: ChannelsStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @AppStorage(SettingsKeys.playlistURL) private var playlistURL = ""
    @State private var group = TVChannelsView.allTag
    @State private var filterText = ""
    @State private var showSetup = false

    static let allTag = "__all__"
    static let favoritesTag = "__favorites__"
    static let recentTag = "__recent__"

    private var hasPlaylist: Bool { !playlistURL.trimmed.isEmpty }

    var body: some View {
        NavigationStack {
            Group {
                if !hasPlaylist {
                    PlaylistSetupView()
                } else if channels.isLoading && channels.channels.isEmpty {
                    ProgressView("Загрузка плейлиста…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = channels.error, channels.channels.isEmpty {
                    ScrollView {
                        ErrorView(message: error) { Task { await channels.reload() } }
                            .padding(.top, 60)
                        Button("Сменить плейлист") { showSetup = true }
                    }
                } else {
                    channelGrid
                }
            }
            .background(Theme.background)
            .navigationTitle("ТВ-каналы")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if hasPlaylist {
                        Menu {
                            Button {
                                Task { await channels.reload() }
                            } label: {
                                Label("Обновить плейлист", systemImage: "arrow.clockwise")
                            }
                            Button {
                                showSetup = true
                            } label: {
                                Label("Сменить плейлист", systemImage: "list.bullet.rectangle")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
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
        }
    }

    private var filtered: [Channel] {
        var list: [Channel]
        switch group {
        case TVChannelsView.allTag:
            list = channels.channels
        case TVChannelsView.favoritesTag:
            list = library.data.favoriteChannels
        case TVChannelsView.recentTag:
            list = library.data.recentChannels
        default:
            list = channels.channels.filter { $0.group == group }
        }
        let q = filterText.trimmed.lowercased()
        if !q.isEmpty {
            list = list.filter { $0.name.lowercased().contains(q) }
        }
        // Playlists often repeat a channel; the grid needs unique ids.
        return list.uniqued(by: \.url)
    }

    private var channelGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Chip(title: "Все", selected: group == TVChannelsView.allTag) { group = TVChannelsView.allTag }
                        if !library.data.recentChannels.isEmpty {
                            Chip(title: "Недавние", selected: group == TVChannelsView.recentTag) { group = TVChannelsView.recentTag }
                        }
                        Chip(title: "Избранные", selected: group == TVChannelsView.favoritesTag) { group = TVChannelsView.favoritesTag }
                        ForEach(channels.groups, id: \.self) { name in
                            Chip(title: name, selected: group == name) { group = name }
                        }
                    }
                    .padding(.horizontal, 16)
                }

                if filtered.isEmpty {
                    ContentUnavailableView(group == TVChannelsView.favoritesTag ? "Нет избранных каналов" :
                                           (group == TVChannelsView.recentTag ? "Нет недавних каналов" : "Каналы не найдены"),
                                           systemImage: "tv",
                                           description: Text(group == TVChannelsView.favoritesTag ? "Удерживайте канал и выберите «В избранное»" : ""))
                        .padding(.top, 40)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 12, alignment: .top)], spacing: 14) {
                        ForEach(filtered) { channel in
                            Button {
                                play(channel)
                            } label: {
                                ChannelCell(channel: channel, favorite: library.isFavoriteChannel(channel))
                            }
                            .buttonStyle(.plain)
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
            .padding(.vertical, 8)
        }
        .searchable(text: $filterText, prompt: "Поиск канала")
    }

    private func play(_ channel: Channel) {
        library.addRecentChannel(channel)
        coordinator.play(PlayRequest(title: channel.name, link: channel.url, isLive: true, userAgent: channel.userAgent, referrer: channel.referrer))
    }
}

struct ChannelCell: View {
    let channel: Channel
    let favorite: Bool

    private var initials: String {
        let words = channel.name.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first }.map { String($0) }.joined()
        return letters.isEmpty ? "TV" : letters.uppercased()
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.card)
                if let logo = channel.logo, let url = URL(string: logo) {
                    PosterImage(url: url, mode: .fit)
                        .padding(12)
                } else {
                    Text(initials)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.secondary)
                }
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .overlay(alignment: .topTrailing) {
                if favorite {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.accent)
                        .padding(6)
                }
            }
            Text(channel.name)
                .font(.caption)
                .foregroundStyle(.white)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.center)
        }
        .contentShape(Rectangle())
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
                Text("Укажите ссылку на свой IPTV-плейлист (например, от провайдера). Названия, группы и логотипы каналов берутся из плейлиста.")
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
