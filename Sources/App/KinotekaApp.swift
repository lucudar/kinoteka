import SwiftUI
import AVFoundation
import UIKit

@main
struct KinotekaApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var coordinator = PlayerCoordinator()
    @StateObject private var channels = ChannelsStore()

    init() {
        // A write to a closed connection (VLC, the engine, URLSession) must return an error
        // instead of killing the whole app with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        AppDiagnostics.shared.start()
        UserDefaults.standard.register(defaults: [
            SettingsKeys.autoNext: true,
            SettingsKeys.savePlayerSettings: true,
            SettingsKeys.playerRate: 1.0,
            SettingsKeys.playerAspect: AspectMode.fit.rawValue,
            SettingsKeys.backgroundAudio: true,
            SettingsKeys.searchServer: TorrentSearchService.defaultServer,
            SettingsKeys.preferredQuality: ReleaseQuality.fullHD.rawValue,
            SettingsKeys.preferredVoice: "auto",
            SettingsKeys.autoPlayBest: true,
            SettingsKeys.prepareTorrent: true,
            SettingsKeys.smartQuality: true,
            SettingsKeys.automaticFallback: true,
            SettingsKeys.automaticRecovery: true,
            SettingsKeys.preloadNextEpisode: true,
            SettingsKeys.playerGestures: true
        ])
        // Video needs the memory more: API responses are small, images have their own cache.
        URLCache.shared = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        MemoryPressure.start()
        _ = NetworkMonitor.shared
        TorrServer.shared.start()
        KPClient.shared.pruneCache()
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
    @ObservedObject private var notice = DiagnosticsNotice.shared
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
            // The phases themselves are logged by AppDiagnostics.
            if phase == .active {
                TorrServer.shared.start()
            } else {
                library.persist()
            }
        }
        .sheet(isPresented: Binding(get: { notice.isPresented && coordinator.request == nil },
                                    set: { if !$0 { notice.dismiss() } })) {
            CrashReportSheet(lines: notice.lines)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
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

/// Frees caches when iOS warns about memory, so that the app is not terminated during playback.
@MainActor
enum MemoryPressure {
    private static var observer: NSObjectProtocol?
    private static var lastWarning: Date?

    static func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { MemoryPressure.handleWarning() }
        }
    }

    static func handleWarning() {
        let now = Date()
        if let last = lastWarning, now.timeIntervalSince(last) < 10 { return }
        lastWarning = now
        AppDiagnostics.shared.log("memory", "iOS просит освободить память · \(AppDiagnostics.memorySummary())")
        ImageCache.shared.purgeMemory()
        let capacity = URLCache.shared.memoryCapacity
        URLCache.shared.memoryCapacity = 0
        URLCache.shared.memoryCapacity = capacity
        TorrentWarmup.shared.releaseUnused()
    }
}
