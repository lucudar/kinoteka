import SwiftUI
import AVFoundation
import UIKit

/// The orientations the screen may turn to: only the current one while the player is locked.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { OrientationLock.mask }
    }
}

@main
struct KinotekaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
            SettingsKeys.playerGestures: true,
            SettingsKeys.engineEncryption: EngineEncryptionMode.automatic.rawValue,
            SettingsKeys.zonaIndex: true,
            SettingsKeys.pipAuto: false,
            SettingsKeys.downloadsWifiOnly: true,
            SettingsKeys.downloadsPauseWhileWatching: true,
            SettingsKeys.downloadsKeepAwake: false,
            SettingsKeys.subtitleLanguage: "ru",
            SettingsKeys.subtitleEnglishFallback: true,
            SettingsKeys.subtitleAuto: false
        ])
        // Video needs the memory more: API responses are small, images have their own cache.
        URLCache.shared = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        // 0.9.0 had a "never" choice; an unknown value would leave the picker without a choice.
        let encryption = UserDefaults.standard.string(forKey: SettingsKeys.engineEncryption)
        if let value = encryption, EngineEncryptionMode(rawValue: value) == nil {
            UserDefaults.standard.set(EngineEncryptionMode.stored(value).rawValue, forKey: SettingsKeys.engineEncryption)
        }
        MemoryPressure.start()
        _ = NetworkMonitor.shared
        TorrServer.shared.launch()
        DownloadManager.shared.start()
        KPClient.shared.pruneCache()
        ZonaCatalog.shared.pruneCache()
        SubtitleService.pruneCache()
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

    /// The player covers the app; minimized it plays in Picture in Picture and the app is usable.
    private var playerCovers: Bool { coordinator.request != nil && !coordinator.minimized }

    var body: some View {
        ZStack {
            tabs
                .accessibilityHidden(playerCovers)
            if let request = coordinator.request {
                PlayerHostView(request: request)
                    .id(request.id)
                    .tint(Theme.accent)
                    .opacity(coordinator.minimized ? 0 : 1)
                    .allowsHitTesting(!coordinator.minimized)
                    .accessibilityHidden(coordinator.minimized)
                    .transition(.move(edge: .bottom))
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: coordinator.request?.id)
        .animation(.easeInOut(duration: 0.25), value: coordinator.minimized)
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
    }

    private var tabs: some View {
        // On iOS 26 the tab bar is Liquid Glass: it floats over the content, shrinks while a list
        // scrolls down, and the search tab is a separate round button that turns into the field.
        TabView(selection: $tab) {
            Tab("Главная", systemImage: "house.fill", value: AppTab.home) {
                HomeView()
            }
            Tab("Каталог", systemImage: "square.grid.2x2.fill", value: AppTab.catalog) {
                CatalogView()
            }
            Tab("ТВ-каналы", systemImage: "tv.fill", value: AppTab.tv) {
                TVChannelsView()
            }
            Tab("Моё", systemImage: "heart.fill", value: AppTab.my) {
                MyView()
            }
            Tab("Поиск", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                SearchView()
            }
        }
        .tabBarMinimizesOnScroll()
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
