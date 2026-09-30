import SwiftUI
import AVFoundation

@main
struct KinotekaApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var coordinator = PlayerCoordinator()
    @StateObject private var channels = ChannelsStore()

    init() {
        UserDefaults.standard.register(defaults: [
            SettingsKeys.autoNext: true,
            SettingsKeys.savePlayerSettings: true,
            SettingsKeys.playerRate: 1.0,
            SettingsKeys.playerAspect: AspectMode.fit.rawValue,
            SettingsKeys.backgroundAudio: true,
            SettingsKeys.searchServer: TorrentSearchService.defaultServer,
            SettingsKeys.preferredQuality: ReleaseQuality.fullHD.rawValue,
            SettingsKeys.autoPlayBest: true,
            SettingsKeys.prepareTorrent: true
        ])
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 512 * 1024 * 1024)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        TorrServer.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(coordinator)
                .environmentObject(channels)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

enum AppTab: Hashable {
    case home, catalog, tv, search, my
}

struct RootView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @EnvironmentObject private var channels: ChannelsStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: AppTab = .home

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("Главная", systemImage: "house.fill") }
                .tag(AppTab.home)
            CatalogView()
                .tabItem { Label("Каталог", systemImage: "square.grid.2x2.fill") }
                .tag(AppTab.catalog)
            TVChannelsView()
                .tabItem { Label("ТВ-каналы", systemImage: "tv.fill") }
                .tag(AppTab.tv)
            SearchView()
                .tabItem { Label("Поиск", systemImage: "magnifyingglass") }
                .tag(AppTab.search)
            MyView()
                .tabItem { Label("Моё", systemImage: "heart.fill") }
                .tag(AppTab.my)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                TorrServer.shared.start()
            } else {
                library.persist()
            }
        }
        .fullScreenCover(item: $coordinator.request) { request in
            PlayerHostView(request: request)
                .environmentObject(library)
                .environmentObject(coordinator)
                .environmentObject(channels)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}
