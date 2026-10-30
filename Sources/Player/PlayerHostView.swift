import SwiftUI
import UIKit
import VLCKitSPM

struct PlayerHostView: View {
    let request: PlayRequest

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = VLCPlayerModel()
    @ObservedObject private var network = NetworkMonitor.shared

    @AppStorage(SettingsKeys.autoNext) private var autoNext = true
    @AppStorage(SettingsKeys.savePlayerSettings) private var savePlayerSettings = true
    @AppStorage(SettingsKeys.playerRate) private var savedRate = 1.0
    @AppStorage(SettingsKeys.playerAspect) private var savedAspect = AspectMode.fit.rawValue
    @AppStorage(SettingsKeys.backgroundAudio) private var backgroundAudio = true
    @AppStorage(SettingsKeys.preferredQuality) private var preferredQualityRaw = ReleaseQuality.fullHD.rawValue
    @AppStorage(SettingsKeys.smartQuality) private var smartQuality = true
    @AppStorage(SettingsKeys.automaticFallback) private var automaticFallback = true
    @AppStorage(SettingsKeys.automaticRecovery) private var automaticRecovery = true
    @AppStorage(SettingsKeys.preloadNextEpisode) private var preloadNextEpisode = true
    @AppStorage(SettingsKeys.playerGestures) private var playerGestures = true
    @AppStorage(SettingsKeys.playerShowRemaining) private var showRemaining = false
    @AppStorage(SettingsKeys.pipAuto) private var pipAuto = false
    @AppStorage(SettingsKeys.subtitleAuto) private var subtitleAuto = false
    @AppStorage(SettingsKeys.openSubtitlesKey) private var openSubtitlesKey = ""

    enum Phase: Equatable {
        case resolving
        case choosing
        case playing
        case failed(String)
    }

    private enum GestureMode: Equatable {
        case seek
        case brightness
        case volume
    }

    private enum SleepChoice: Int, CaseIterable, Identifiable {
        case off = 0
        case minutes15 = 15
        case minutes30 = 30
        case minutes45 = 45
        case minutes60 = 60
        case endOfVideo = -1

        var id: Int { rawValue }
        var title: String {
            switch self {
            case .off: return "Выключен"
            case .minutes15: return "Через 15 минут"
            case .minutes30: return "Через 30 минут"
            case .minutes45: return "Через 45 минут"
            case .minutes60: return "Через 60 минут"
            case .endOfVideo: return "До конца фильма или серии"
            }
        }
    }

    /// Pages of the player's settings: a short menu, every choice on its own page.
    private enum OptionsPage: Hashable {
        case release, audio, subtitles, subtitleSearch, speed, aspect, sync, sleep, download, torrent
    }

    @State private var phase: Phase = .resolving
    @State private var statusText = "Подготовка…"
    @State private var detailText = ""
    @State private var hash: String?
    @State private var allFiles: [TorrentFile] = []
    @State private var files: [TorrentFile] = []
    @State private var currentFile: TorrentFile?
    @State private var streamKey = ""
    @State private var streamURL: URL?
    @State private var showControls = true
    @State private var controlsLocked = false
    @State private var hideToken = 0
    @State private var showFiles = false
    @State private var showOptions = false
    @State private var scrubbing = false
    @State private var scrubValue = 0.0
    @State private var chooserNote: String?
    @State private var lastResumeSave = Date.distantPast
    @State private var lastContinueSave = Date.distantPast
    @State private var bufferInfo = ""
    @State private var closing = false
    @State private var addedAudio: Set<Int> = []
    @State private var preferredAudioApplied = false
    @State private var preferredSubtitleApplied = false
    @State private var desiredAudioName: String?
    @State private var desiredQuality: ReleaseQuality?
    @State private var desiredVoice: ReleaseVoiceOption?
    /// The link that plays: the requested one, or another release picked in "Качество".
    @State private var link: String
    @State private var wantedFileId: Int?
    @State private var wantedSeason: Int?
    @State private var wantedEpisode: Int?
    /// Where to start the first file (continuing in another release).
    @State private var pendingStart: Int32?
    @State private var resolveTask: Task<Void, Never>?
    @State private var attemptedLinks: Set<String> = []
    @State private var fallbackCount = 0
    /// Other releases of the film searched for their torrent data (the file list) at the same time
    /// as the one that opens, by hash: the first one whose peers send it plays.
    @State private var racers: [String: TorrentRelease] = [:]
    /// Racers being added now (the engine has not answered yet).
    @State private var racersPending = 0
    /// Changes when the racers are closed: a racer added after that is not needed.
    @State private var racingGeneration = 0
    @State private var attemptStartedAt = Date()
    @State private var playbackBeganAt = Date.distantPast
    @State private var playbackSuccessRecorded = false
    @State private var firstFrameLogged = false
    @State private var startupMs: Double?
    @State private var recoveryAttempts = 0
    @State private var recoveryTask: Task<Void, Never>?
    @State private var startupWatchdogTask: Task<Void, Never>?
    @State private var recoveryText: String?
    @State private var nextPreparedID: Int?
    @State private var preloadTask: Task<Void, Never>?
    /// Releases found for the film: the choices of "Качество".
    @State private var alternatives: [TorrentRelease] = []
    @State private var alternativesLoaded = false
    @State private var switching: TorrentRelease?
    @State private var switchStatus = ""
    @State private var switchTask: Task<Void, Never>?
    @State private var switchError: String?
    @State private var showQuality = false
    @State private var gestureMode: GestureMode?
    @State private var gestureStartTime: Int32 = 0
    @State private var gestureTargetTime: Int32?
    @State private var gestureStartLevel: CGFloat = 0
    @State private var gestureIcon = ""
    @State private var gestureText = ""
    @State private var gestureHUDToken = 0
    @State private var sleepChoice: SleepChoice = .off
    @State private var sleepDeadline: Date?
    @State private var sleepTask: Task<Void, Never>?
    @State private var playerNotice: String?
    @State private var noticeToken = 0
    @State private var showNextEpisodePrompt = false
    @State private var autoNextCancelled = false
    /// Double tap on the left or right side seeks by 10 seconds (every further quick tap adds 10).
    @State private var pendingTap: Task<Void, Never>?
    @State private var lastTapAt = Date.distantPast
    @State private var lastTapSide = 0
    @State private var seekStreakSide = 0
    @State private var seekStreakSeconds = 0
    @State private var lockHintVisible = false
    @State private var lockHintToken = 0
    @State private var optionsPath: [OptionsPage] = []
    /// The file plays from the iPhone (downloaded), not through the engine.
    @State private var playingLocal = false
    /// The torrent is open in the engine, not only its saved file list.
    @State private var engineAttached = false
    @State private var preferEngine = false
    @State private var autoSubtitleTried: Set<String> = []

    init(request: PlayRequest) {
        self.request = request
        _link = State(initialValue: request.link)
        _wantedFileId = State(initialValue: request.preferredFileId)
        _wantedSeason = State(initialValue: request.season)
        _wantedEpisode = State(initialValue: request.episode)
        _pendingStart = State(initialValue: request.startTime)
        _desiredQuality = State(initialValue: request.requestedQuality)
        _desiredVoice = State(initialValue: request.requestedVoice)
        _desiredAudioName = State(initialValue: request.preferredAudio)
    }

    private static let audioExtensions: Set<String> = ["mka", "ac3", "eac3", "dts", "aac", "mp3", "flac", "ogg", "opus", "m4a", "wav"]
    private static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "smi"]
    /// At most this many other releases are searched at the same time as the one that opens.
    private static let maxRacers = 2

    var body: some View {
        systemObservers(playbackObservers(screen))
            .sheet(isPresented: $showFiles) { filesSheet }
            .sheet(isPresented: $showOptions) { optionsSheet }
            .sheet(isPresented: $showQuality) { qualitySheet }
            .alert("Не удалось сменить раздачу",
                   isPresented: Binding(get: { switchError != nil }, set: { if !$0 { switchError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(switchError ?? "")
            }
    }

    /// The screen of the player with its system options and the tasks of the playback.
    /// (The modifiers are split into parts: one long chain is too much for the type checker.)
    private var screen: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if showsBackdrop, let poster = request.item?.poster {
                // While the video is prepared: the poster, blurred, under the glass panel.
                Color.clear
                    .overlay {
                        PosterImage(url: poster, maxPixel: 300)
                            .scaleEffect(1.2)
                            .blur(radius: 40)
                            .opacity(0.5)
                    }
                    .clipped()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            switch phase {
            case .resolving:
                resolvingView
            case .choosing:
                chooserView
            case .failed(let message):
                failedView(message)
            case .playing:
                playerView
            }
        }
        .statusBarHidden(!coordinator.minimized)
        .persistentSystemOverlays(coordinator.minimized ? .automatic : .hidden)
        // Locked: a swipe from the edge does not open the Control Center or leave the app at once.
        .defersSystemGestures(on: controlsLocked ? .all : [])
        .task {
            if resolveTask == nil {
                await adaptInitialLinkForNetworkFromCache()
                startResolve()
            }
            await loadAlternatives()
        }
        .task { await loadArtwork() }
        .task(id: hash) { await pollTorrentStats() }
        .onAppear {
            IdleTimer.set("player", active: true)
            // Frames for Picture in Picture from the start: iOS can move the video there by itself.
            model.prefersSampleBuffer = pipAuto && model.pipSupported
            model.automaticPictureInPicture = pipAuto && model.pipSupported
            if OrientationHelper.isPhone {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    OrientationHelper.set(landscape: true)
                }
            }
        }
        .onDisappear {
            finish()
        }
    }

    /// Reactions to the playback.
    private func playbackObservers<Content: View>(_ content: Content) -> some View {
        content
            .onChange(of: model.timeMs) { _, _ in
                periodicSave()
                prepareNextEpisodeIfNeeded()
                updateNextEpisodePrompt()
            }
            .onChange(of: model.ended) { _, ended in
                if ended { handleEnded() }
            }
            .onChange(of: model.isPlaying) { _, playing in
                if playing {
                    IdleTimer.set("player", active: true)
                    bumpControls()
                } else if !controlsLocked {
                    withAnimation { showControls = true }
                }
            }
            .onChange(of: model.started) { _, started in
                if started { playbackDidStart() }
            }
            .onChange(of: model.failed) { _, failed in
                if failed { scheduleRecovery(reason: "ошибка VLC", delay: 1) }
            }
            .onChange(of: model.isBuffering) { _, buffering in
                if buffering && model.started {
                    scheduleRecovery(reason: "поток завис", delay: 12)
                } else if !buffering && !model.failed {
                    recoveryTask?.cancel()
                    recoveryTask = nil
                    recoveryText = nil
                }
            }
            .onChange(of: model.audioTracks) { _, _ in
                applyPreferredAudio()
            }
            .onChange(of: model.subtitleTracks) { _, _ in
                applyPreferredSubtitle()
            }
            .onChange(of: showOptions) { _, open in
                if !open {
                    optionsPath = []
                    bumpControls()
                }
            }
            .onChange(of: showFiles) { _, open in
                if !open { bumpControls() }
            }
    }

    /// Reactions to the app going to the background and to Picture in Picture.
    private func systemObservers<Content: View>(_ content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    model.setVideoEnabled(true)
                    model.recoverVideoLayer()
                    // iOS moved the video to the window when the app was closed: back in the app,
                    // it returns to the player.
                    if model.pipActive, model.pipStartedAutomatically, !coordinator.minimized {
                        model.exitPictureInPicture()
                    }
                case .background:
                    recoveryTask?.cancel()
                    startupWatchdogTask?.cancel()
                    saveProgress(final: true)
                    if model.pipActive || (pipAuto && model.renderMode == .sampleBuffer && model.isPlaying) {
                        // The picture stays in Picture in Picture; checked again once it has started.
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            guard UIApplication.shared.applicationState == .background, !model.pipActive, !closing else { return }
                            enteredBackgroundWithoutWindow()
                        }
                    } else {
                        enteredBackgroundWithoutWindow()
                    }
                default:
                    saveProgress(final: true)
                }
            }
            .onChange(of: model.pipStarts) { _, _ in pictureInPictureStarted() }
            .onChange(of: model.pipRestoreRequests) { _, _ in restoreFromPictureInPicture() }
            .onChange(of: model.pipClosedRequests) { _, _ in pictureInPictureClosed() }
            .onChange(of: model.pipMessage) { _, text in
                guard let text else { return }
                showNotice(text)
                model.clearPipMessage()
            }
    }

    // MARK: - Resolving the link

    private var effectivePreferredQuality: ReleaseQuality {
        if let desiredQuality = desiredQuality { return desiredQuality }
        let configured = ReleaseQuality(rawValue: preferredQualityRaw) ?? .fullHD
        return PlaybackPolicy.effectiveQuality(configured, connection: network.connection, smart: smartQuality)
    }

    private func startResolve(resetAttempts: Bool = true) {
        resolveTask?.cancel()
        if resetAttempts {
            attemptedLinks.removeAll()
            fallbackCount = 0
        }
        resolveTask = Task { await resolveWithFallback() }
    }

    private func resolveWithFallback() async {
        phase = .resolving
        while !Task.isCancelled && !closing {
            let target = link.trimmed
            attemptedLinks.insert(canonicalLink(target))
            attemptStartedAt = Date()
            playbackSuccessRecorded = false
            firstFrameLogged = false
            startupMs = nil
            let release = release(matching: target)
            AppDiagnostics.shared.log("player", "Попытка запуска: \(release?.qualityText ?? "ссылка"), сеть \(network.title)")
            do {
                try await resolve(target)
                return
            } catch {
                if Task.isCancelled || closing { return }
                // The release that plays now: another one may have given its data first meanwhile.
                PlaybackLearning.shared.recordFailure(self.release(matching: link) ?? release)
                AppDiagnostics.shared.log("player", "Запуск не удался: \(error.localizedDescription)")
                // Waiting for the torrent data has tried other releases at the same time already;
                // they stay connected, so "Повторить" goes on with the peers found.
                if (error as? TorrServerError)?.isTimeout == true, automaticFallback, canSwitchRelease {
                    phase = .failed(error.localizedDescription)
                    return
                }
                guard await selectAutomaticFallback(preferLowerQuality: false) else {
                    phase = .failed(error.localizedDescription)
                    return
                }
            }
        }
    }

    private func resolve(_ target: String) async throws {
        switch LinkInspector.kind(of: target) {
        case .direct:
            guard let url = URL(string: target) else { throw TorrServerError.server("Некорректная ссылка.") }
            streamKey = target
            start(url: url, slaves: [])
        case .torrent:
            try await resolveTorrent(LinkInspector.stripMarker(target))
        }
    }

    private func resolveTorrent(_ torrent: String) async throws {
        // The player closed meanwhile: it must not stay marked as playing.
        guard !closing else { throw CancellationError() }
        phase = .resolving
        // A downloaded file plays from the iPhone: no engine and no peers, works without the network.
        if !preferEngine, let saved = DownloadManager.shared.torrent(forLink: torrent),
           let file = savedFile(in: saved) {
            hash = saved.hash
            allFiles = saved.files
            files = videoFiles(saved.files)
            AppDiagnostics.shared.log("player", "Воспроизведение скачанного файла")
            play(file, startAt: takePendingStart())
            return
        }
        statusText = fallbackCount > 0 ? "Пробуем запасную раздачу…" : "Запуск торрент-движка…"
        detailText = ""
        TorrServer.shared.setPlayerActive(true)
        // Only the first check after the start may tune the engine here: a retune for another
        // network is made by a film page, it would close the torrent prepared for this playback.
        try await TorrServer.shared.ensureRunning(retune: true)
        statusText = "Получение данных торрента…"
        let status = try await TorrServer.shared.add(link: torrent, title: request.item?.title ?? request.title, poster: request.item?.posterURL)
        try Task.checkCancellation()
        guard let h = status.hash, !h.isEmpty else {
            throw TorrServerError.server("не удалось добавить торрент")
        }
        hash = h
        engineAttached = true
        // Torrents that are not needed now (played before, prepared for another film) are freed.
        TorrentWarmup.shared.playbackStarted(hash: h)
        let all: [TorrentFile]
        if !status.files.isEmpty {
            all = status.files
            closeRacers(keeping: h)
        } else {
            all = try await waitForMetadata(of: h, link: torrent)
        }
        try Task.checkCancellation()
        allFiles = all
        let list = videoFiles(all)
        guard !list.isEmpty else { throw TorrServerError.noVideo }
        files = list

        if let id = wantedFileId, let file = list.first(where: { $0.id == id }) {
            play(file, startAt: takePendingStart())
        } else if let episode = wantedEpisode,
                  let file = EpisodeMatcher.find(in: list, season: wantedSeason, episode: episode) {
            play(file, startAt: takePendingStart())
        } else if wantedEpisode != nil {
            throw SwitchFailure.noSameFile
        } else if list.count == 1 {
            play(list[0], startAt: takePendingStart())
        } else if request.item?.kind != .series, let largest = dominantFile(list) {
            play(largest, startAt: takePendingStart())
        } else {
            chooserNote = nil
            phase = .choosing
        }
    }

    /// The file this request wants, when it is downloaded.
    private func savedFile(in saved: DownloadTorrent) -> TorrentFile? {
        let list = videoFiles(saved.files)
        let wanted: TorrentFile?
        if let id = wantedFileId {
            wanted = list.first { $0.id == id }
        } else if let episode = wantedEpisode {
            wanted = EpisodeMatcher.find(in: list, season: wantedSeason, episode: episode)
        } else if list.count == 1 {
            wanted = list.first
        } else if request.item?.kind != .series {
            wanted = dominantFile(list)
        } else {
            wanted = nil
        }
        guard let file = wanted, DownloadManager.shared.localURL(hash: saved.hash, fileId: file.id) != nil else { return nil }
        return file
    }

    private func canonicalLink(_ value: String) -> String {
        let text = value.trimmed
        return LinkInspector.kind(of: text) == .torrent ? LinkInspector.markTorrent(LinkInspector.stripMarker(text)) : text
    }

    private func release(matching value: String) -> TorrentRelease? {
        let key = canonicalLink(value)
        if let hash = LinkInspector.infoHash(of: LinkInspector.stripMarker(value))?.lowercased(),
           let match = alternatives.first(where: { $0.hash?.lowercased() == hash }) {
            return match
        }
        return alternatives.first { canonicalLink($0.link) == key }
    }

    /// Waits for the torrent data (the file list) of `primary`, which only peers send for a magnet
    /// link. Peers of Zona's apps never send it, and some releases have almost only them, so when
    /// it does not come soon, other releases of the film are added at the same time and the first
    /// one with the data plays. Nothing is dropped while waiting: every torrent keeps the peers it
    /// has found, the way a second tap on "Повторить" did before.
    private func waitForMetadata(of primary: String, link torrent: String) async throws -> [TorrentFile] {
        let racing = automaticFallback && canSwitchRelease
        // With other releases the wait ends sooner: they have been tried at the same time.
        let budget: TimeInterval = racing ? 75 : 120
        let started = Date()
        let primaryKey = primary.lowercased()
        var nextRacerAt: TimeInterval = racers.isEmpty ? 8 : 10
        var crowdChecked = false
        var readded = false
        var tick = 0
        while !Task.isCancelled && !closing {
            let elapsed = Date().timeIntervalSince(started)
            let status: TSStatus
            do {
                status = try await TorrServer.shared.get(hash: primary)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                guard !readded else { throw error }
                // The engine has closed the torrent meanwhile (it waits for the data for minutes,
                // or it was restarted): it is added again.
                readded = true
                AppDiagnostics.shared.log("torrent", "Раздача закрыта движком, добавляем снова: \(error.localizedDescription)")
                status = try await TorrServer.shared.add(link: torrent, title: request.item?.title ?? request.title,
                                                         poster: request.item?.posterURL)
            }
            try Task.checkCancellation()
            if !status.files.isEmpty {
                if elapsed > 5 {
                    AppDiagnostics.shared.log("torrent", "Данные торрента получены за \(Int(elapsed)) с")
                }
                closeRacers(keeping: primary)
                return status.files
            }
            var active = status.activePeers ?? 0
            var total = status.totalPeers ?? 0
            for (racerHash, racerRelease) in racers where racerHash != primaryKey {
                do {
                    let racer = try await TorrServer.shared.get(hash: racerHash)
                    try Task.checkCancellation()
                    if !racer.files.isEmpty {
                        if let episode = wantedEpisode,
                           EpisodeMatcher.find(in: videoFiles(racer.files), season: wantedSeason, episode: episode) == nil {
                            // It has no such episode: the others go on.
                            AppDiagnostics.shared.log("fallback", "В другой раздаче нет нужной серии: \(racerRelease.qualityText)")
                            racers[racerHash] = nil
                            Task { await TorrServer.shared.drop(hash: racerHash) }
                            continue
                        }
                        adoptRacer(racerRelease, hash: racerHash, elapsed: elapsed)
                        return racer.files
                    }
                    active += racer.activePeers ?? 0
                    total += racer.totalPeers ?? 0
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    // The engine has closed it: the others go on.
                    racers[racerHash] = nil
                }
            }
            let searched = 1 + racers.count
            statusText = elapsed < 15 ? "Подключение к пирам…" : "Ищем пиров с данными торрента…"
            detailText = "Пиры: \(active) из \(total)" + (searched > 1 ? " · раздач: \(searched)" : "")
            if elapsed >= budget {
                AppDiagnostics.shared.log("torrent", "Данные торрента не получены за \(Int(budget)) с: пиры \(active) из \(total), раздач \(searched)")
                throw TorrServerError.timeout
            }

            // Many peers connected and still no data: most likely Zona's apps, another release
            // is added at once instead of waiting.
            let crowdedButSilent = !crowdChecked && elapsed >= 4 && (status.activePeers ?? 0) >= 6
            if racing, alternativesLoaded, elapsed >= nextRacerAt || crowdedButSilent,
               racers.count + racersPending < PlayerHostView.maxRacers {
                if crowdedButSilent { crowdChecked = true }
                addRacer(besides: primaryKey, reason: crowdedButSilent
                         ? "пиров \(status.activePeers ?? 0), данных нет"
                         : "нет данных \(Int(elapsed)) с")
                nextRacerAt = elapsed + 10
            }
            tick += 1
            try await Task.sleep(nanoseconds: tick < 20 ? 250_000_000 : 500_000_000)
        }
        throw CancellationError()
    }

    /// Adds the next best release of the film to the engine, to wait for its torrent data at the
    /// same time. The engine is not waited for here: the torrents being searched are checked on.
    private func addRacer(besides primary: String, reason: String) {
        let taken = Set(racers.keys).union([primary])
        let racing = Set(racers.values.map { canonicalLink($0.link) })
        let candidates = PlaybackLearning.shared.candidates(alternatives,
                                                             preferred: effectivePreferredQuality,
                                                             season: releaseSeason,
                                                             voice: desiredVoice)
        guard let next = candidates.first(where: { candidate in
            let key = canonicalLink(candidate.link)
            if attemptedLinks.contains(key) || racing.contains(key) { return false }
            if let other = candidate.hash?.lowercased(), taken.contains(other) { return false }
            return true
        }) else { return }
        attemptedLinks.insert(canonicalLink(next.link))
        racersPending += 1
        let generation = racingGeneration
        let raw = LinkInspector.stripMarker(next.link)
        let title = request.item?.title ?? request.title
        let poster = request.item?.posterURL
        AppDiagnostics.shared.log("fallback", "Параллельно ищем другую раздачу (\(reason)): \(next.qualityText), сиды \(next.seeders)")
        Task { @MainActor in
            let status = try? await TorrServer.shared.add(link: raw, title: title, poster: poster, saveToDB: false)
            if generation == racingGeneration { racersPending = max(0, racersPending - 1) }
            guard let added = status?.hash?.lowercased(), !added.isEmpty else { return }
            guard generation == racingGeneration, !closing else {
                // The search has ended meanwhile: this torrent is not needed.
                if added != hash?.lowercased() { await TorrServer.shared.drop(hash: added) }
                return
            }
            if !taken.contains(added) { racers[added] = next }
        }
    }

    /// Another release has got its torrent data first: it plays instead of the one that opened.
    private func adoptRacer(_ winner: TorrentRelease, hash winnerHash: String, elapsed: TimeInterval) {
        // A short wait is no fault of the release that opened.
        if elapsed >= 10 { PlaybackLearning.shared.recordFailure(release(matching: link)) }
        link = LinkInspector.markTorrent(winner.link)
        attemptedLinks.insert(canonicalLink(link))
        hash = winnerHash
        wantedFileId = nil
        fallbackCount += 1
        racers[winnerHash] = nil
        if let key = request.itemKey { library.addSource(SavedSource(release: winner), for: key) }
        // The release that opened is disconnected, so this one gets all the bandwidth.
        TorrentWarmup.shared.playbackStarted(hash: winnerHash)
        closeRacers(keeping: winnerHash)
        AppDiagnostics.shared.log("fallback", "Данные торрента первой дала другая раздача за \(Int(elapsed)) с: \(winner.qualityText), сиды \(winner.seeders)")
        // Saved to the engine's database too, like the release that opens: next time it starts at once.
        let raw = LinkInspector.stripMarker(winner.link)
        let title = request.item?.title ?? request.title
        let poster = request.item?.posterURL
        Task { _ = try? await TorrServer.shared.add(link: raw, title: title, poster: poster) }
    }

    /// Disconnects the releases searched at the same time, except `keeping`.
    private func closeRacers(keeping: String? = nil) {
        racingGeneration += 1
        racersPending = 0
        guard !racers.isEmpty else { return }
        let keep = keeping?.lowercased()
        let unused = racers.keys.filter { $0 != keep && $0 != hash?.lowercased() }
        racers = [:]
        for old in unused {
            Task { await TorrServer.shared.drop(hash: old) }
        }
    }

    /// Picks the next learned, live release. After repeated stalls it first tries
    /// a lower quality, but falls back to any working candidate if necessary.
    private func selectAutomaticFallback(preferLowerQuality: Bool) async -> Bool {
        guard automaticFallback, canSwitchRelease, fallbackCount < 3 else { return false }
        await loadAlternatives()
        guard !Task.isCancelled, !closing, !alternatives.isEmpty else { return false }

        let currentQuality = release(matching: link)?.quality ?? effectivePreferredQuality
        let ceiling = preferLowerQuality ? PlaybackPolicy.lowerQuality(than: currentQuality) : nil
        let candidates = PlaybackLearning.shared.candidates(alternatives,
                                                             preferred: effectivePreferredQuality,
                                                             season: releaseSeason,
                                                             voice: desiredVoice,
                                                             ceiling: ceiling)
        guard let next = candidates.first(where: { !attemptedLinks.contains(canonicalLink($0.link)) }) else {
            return false
        }
        fallbackCount += 1
        link = LinkInspector.markTorrent(next.link)
        wantedFileId = nil
        statusText = preferLowerQuality ? "Пробуем более лёгкую раздачу…" : "Пробуем запасную раздачу…"
        detailText = next.summary
        if let key = request.itemKey { library.addSource(SavedSource(release: next), for: key) }
        AppDiagnostics.shared.log("fallback", "Автовыбор \(next.qualityText), сиды \(next.seeders), попытка \(fallbackCount)")
        return true
    }

    /// Continuing from Home does not open the film page first. Use only an
    /// already cached search result here, so mobile-network adaptation is instant
    /// and never delays playback with a new web request.
    private func adaptInitialLinkForNetworkFromCache() async {
        guard smartQuality, desiredQuality == nil,
              network.connection == .cellular || network.isConstrained || network.isExpensive,
              let item = request.item,
              let result = await TorrentSearchService.shared.cachedResult(TorrentSearchQuery(item: item))
        else { return }
        alternatives = library.allowedReleases(result.releases)
        guard let current = release(matching: link),
              current.quality > effectivePreferredQuality else { return }
        let candidates = PlaybackLearning.shared.candidates(alternatives,
                                                             preferred: effectivePreferredQuality,
                                                             season: releaseSeason,
                                                             voice: desiredVoice,
                                                             ceiling: effectivePreferredQuality)
        guard let replacement = candidates.first(where: {
            canonicalLink($0.link) != canonicalLink(link)
        }) else { return }
        link = LinkInspector.markTorrent(replacement.link)
        wantedFileId = nil
        if let key = request.itemKey { library.addSource(SavedSource(release: replacement), for: key) }
        AppDiagnostics.shared.log("network", "Мобильная сеть: \(current.qualityText) → \(replacement.qualityText)")
    }

    /// Video files of the torrent without samples, in name order.
    private func videoFiles(_ all: [TorrentFile]) -> [TorrentFile] {
        TorrentFile.playable(all)
    }

    private func takePendingStart() -> Int32? {
        let value = pendingStart
        pendingStart = nil
        return value
    }

    /// For movies: the file that takes most of the torrent (main feature vs extras).
    private func dominantFile(_ list: [TorrentFile]) -> TorrentFile? {
        TorrentFile.dominant(list)
    }

    /// `startAt`: position in the file (another release of what played); otherwise the saved one.
    private func play(_ file: TorrentFile, startAt: Int32? = nil) {
        guard let h = hash else { return }
        let local = DownloadManager.shared.localURL(hash: h, fileId: file.id)
        if local == nil && !engineAttached {
            // Opened from the saved file list: the engine is connected for a file that is not downloaded.
            wantedFileId = file.id
            if let startAt { pendingStart = startAt }
            preferEngine = true
            model.stop()
            startResolve()
            return
        }
        guard let url = local ?? TorrServer.shared.streamURL(hash: h, file: file) else { return }
        // The next episode read in advance goes on reading when it is the one that starts now.
        if nextPreparedID != file.id { preloadTask?.cancel() }
        preloadTask = nil
        if local == nil {
            // The end of the file is downloaded while the player reads its start.
            TorrentWarmup.shared.playbackWillStart(hash: h, file: file)
        }
        nextPreparedID = nil
        showNextEpisodePrompt = false
        autoNextCancelled = false
        currentFile = file
        streamKey = "\(h):\(file.id)"
        addedAudio = []
        playingLocal = local != nil
        let slaves: [(URL, VLCMediaPlaybackSlaveType)] = local != nil
            ? DownloadManager.shared.localSubtitleURLs(hash: h, fileId: file.id).map { ($0, VLCMediaPlaybackSlaveType.subtitle) }
            : subtitleSlaves(for: file)
        start(url: url, slaves: slaves, startAt: startAt)
    }

    private func baseName(_ file: TorrentFile) -> String {
        (file.name as NSString).deletingPathExtension.lowercased()
    }

    private func companions(for file: TorrentFile, extensions: Set<String>) -> [TorrentFile] {
        let base = baseName(file)
        guard base.count >= 3 else { return [] }
        return allFiles.filter { $0.id != file.id && extensions.contains($0.ext) && $0.name.lowercased().hasPrefix(base) }
    }

    private func subtitleSlaves(for file: TorrentFile) -> [(URL, VLCMediaPlaybackSlaveType)] {
        guard let h = hash else { return [] }
        return companions(for: file, extensions: PlayerHostView.subtitleExtensions)
            .prefix(8)
            .compactMap { sub in TorrServer.shared.streamURL(hash: h, file: sub).map { ($0, VLCMediaPlaybackSlaveType.subtitle) } }
    }

    /// External dubs stored next to the video (e.g. "Rus Sound/Studio/Episode.mka").
    private var externalAudio: [TorrentFile] {
        guard let file = currentFile, !playingLocal else { return [] }
        return companions(for: file, extensions: PlayerHostView.audioExtensions)
    }

    private func audioTitle(_ file: TorrentFile) -> String {
        let folder = ((file.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return folder.isEmpty ? file.name : "\(folder) (\(file.ext))"
    }

    private func start(url: URL, slaves: [(URL, VLCMediaPlaybackSlaveType)], startAt: Int32? = nil) {
        streamURL = url
        phase = .playing
        closeRacers(keeping: hash)
        // Downloads wait while a stream plays (a setting), a saved file does not need the network.
        DownloadManager.shared.playerStreaming = !url.isFileURL
        recoveryText = nil
        preferredAudioApplied = false
        preferredSubtitleApplied = false
        var position: Int32 = 0
        if !request.isLive {
            if let wanted = startAt {
                // A little earlier than where the other release stopped, to catch up.
                position = max(0, wanted - 2_000)
            } else {
                let resume = library.resumePosition(for: streamKey)
                position = resume > 10_000 ? resume - 3_000 : 0
            }
        }
        var options: [String: Any] = [:]
        if let agent = request.userAgent { options["http-user-agent"] = agent }
        if let referrer = request.referrer { options["http-referrer"] = referrer }
        if request.isLive {
            options["network-caching"] = 1500
        } else if engineAttached, !url.isFileURL, TorrServer.shared.activeProfile?.kind == .fast {
            // On Wi‑Fi the engine already keeps a big buffer ahead of the playback: a shorter one
            // in the player (3 s by default) starts the film and every seek sooner.
            options["network-caching"] = 2000
        }
        let rate: Float = (savePlayerSettings && !request.isLive) ? Float(savedRate) : 1
        let aspect: AspectMode = savePlayerSettings ? (AspectMode(rawValue: savedAspect) ?? .fit) : .fit
        model.load(url: url, startAt: position, options: options, rate: rate, aspect: aspect, slaves: slaves)
        model.enableRemoteControls(title: request.item?.title ?? request.title,
                                   subtitle: currentFile.flatMap { files.count > 1 ? fileLabel($0) : nil },
                                   isLive: request.isLive)
        lastResumeSave = Date()
        lastContinueSave = Date.distantPast
        startupWatchdogTask?.cancel()
        if automaticRecovery && !request.isLive {
            startupWatchdogTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard !Task.isCancelled, phase == .playing, !model.started, !closing else { return }
                await recoverPlayback(reason: "видео не началось")
            }
        }
        bumpControls()
    }

    /// Selects the VLC track matching the voice-over chosen on the film page.
    /// If a torrent does not label its tracks, VLC's default remains unchanged.
    private func applyPreferredAudio() {
        let preferred = desiredAudioName?.nonEmpty
            ?? desiredVoice?.title
            ?? PlaybackLearning.shared.preferredAudio(for: request.itemKey)
        guard !preferredAudioApplied, let preferred = preferred else { return }
        let names = model.audioTracks.map(\.name)
        guard let index = AudioTrackMatcher.best(in: names, preferred: preferred),
              model.audioTracks.indices.contains(index) else { return }
        preferredAudioApplied = true
        selectAudio(model.audioTracks[index], remember: true)
    }

    private func selectAudio(_ track: MediaTrack, remember: Bool) {
        model.setAudio(track.id)
        if remember {
            desiredAudioName = track.name
            PlaybackLearning.shared.rememberAudio(track.name, for: request.itemKey)
            AppDiagnostics.shared.log("audio", "Выбрана дорожка \(track.name)")
        }
    }

    private func applyPreferredSubtitle() {
        guard !preferredSubtitleApplied,
              let preferred = PlaybackLearning.shared.preferredSubtitle(for: request.itemKey),
              !model.subtitleTracks.isEmpty else { return }
        let track: MediaTrack?
        if preferred == "__OFF__" {
            track = model.subtitleTracks.first { $0.id == -1 }
        } else {
            track = model.subtitleTracks.first {
                $0.name.compare(preferred, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
        }
        guard let track = track else { return }
        preferredSubtitleApplied = true
        selectSubtitle(track, remember: false)
    }

    private func selectSubtitle(_ track: MediaTrack, remember: Bool) {
        model.setSubtitle(track.id)
        if remember {
            PlaybackLearning.shared.rememberSubtitle(track.id == -1 ? nil : track.name,
                                                      for: request.itemKey)
            AppDiagnostics.shared.log("subtitles", track.id == -1 ? "Субтитры выключены" : "Выбраны \(track.name)")
        }
    }

    private func retryPlayback() {
        recoveryAttempts = 0
        if model.timeMs > 0 && !request.isLive { pendingStart = model.timeMs }
        wantedFileId = currentFile?.id
        model.stop()
        startResolve()
    }

    private func switchTo(_ file: TorrentFile) {
        saveProgress(final: true)
        play(file)
    }

    /// The next episode by its number (not the next file name), same folder first.
    private var nextFile: TorrentFile? {
        guard let current = currentFile, files.count > 1 else { return nil }
        return EpisodeMatcher.next(after: current, in: files)
    }

    private func playbackDidStart() {
        startupWatchdogTask?.cancel()
        startupWatchdogTask = nil
        playbackBeganAt = Date()
        if !firstFrameLogged {
            firstFrameLogged = true
            let elapsed = Date().timeIntervalSince(attemptStartedAt) * 1_000
            startupMs = elapsed
            AppDiagnostics.shared.log("player", "Первый кадр за \(Int(elapsed)) мс · \(AppDiagnostics.memorySummary())")
        }
        AppDiagnostics.shared.setPlayback(request.item?.title ?? request.title)
        if model.isBuffering { scheduleRecovery(reason: "поток завис при запуске", delay: 12) }
        if let item = request.item {
            library.removeWatchLater(item)
        }
        recordPlaybackSuccessIfPossible()
        scheduleAutoSubtitles()
    }

    private func recordPlaybackSuccessIfPossible() {
        guard !playbackSuccessRecorded, let current = release(matching: link) else { return }
        playbackSuccessRecorded = true
        let startup = startupMs ?? Date().timeIntervalSince(attemptStartedAt) * 1_000
        PlaybackLearning.shared.recordSuccess(current, startupMs: startup)
        AppDiagnostics.shared.log("learning", "Успешная раздача \(current.qualityText), \(Int(startup)) мс")
    }

    private func scheduleRecovery(reason: String, delay: TimeInterval) {
        guard automaticRecovery, !request.isLive, phase == .playing, !closing else { return }
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor in
            try? await Task.sleep(seconds: delay)
            guard !Task.isCancelled, !closing, phase == .playing,
                  model.failed || model.isBuffering else { return }
            await recoverPlayback(reason: reason)
        }
    }

    private func recoverPlayback(reason: String) async {
        guard automaticRecovery, !request.isLive, !closing else { return }
        recoveryAttempts += 1
        let position = model.timeMs
        saveProgress(final: true)
        if recoveryAttempts == 1 {
            PlaybackLearning.shared.recordFailure(release(matching: link))
        }
        AppDiagnostics.shared.log("recovery", "\(reason), попытка \(recoveryAttempts), позиция \(position)")

        if !model.started, await selectAutomaticFallback(preferLowerQuality: false) {
            recoveryText = "Пробуем запасную раздачу…"
            pendingStart = position
            wantedFileId = nil
            model.stop()
            startResolve(resetAttempts: false)
            return
        }

        if recoveryAttempts <= 2 {
            recoveryText = "Восстанавливаем поток…"
            pendingStart = position
            wantedFileId = currentFile?.id
            model.stop()
            startResolve(resetAttempts: false)
            return
        }

        if await selectAutomaticFallback(preferLowerQuality: true) {
            recoveryText = "Подбираем более стабильную раздачу…"
            pendingStart = position
            wantedFileId = nil
            model.stop()
            startResolve(resetAttempts: false)
        } else {
            recoveryText = nil
        }
    }

    private func prepareNextEpisodeIfNeeded() {
        guard preloadNextEpisode, !request.isLive, model.started,
              network.connection != .cellular, network.connection != .offline,
              !network.isExpensive, !network.isConstrained,
              model.lengthMs > 0, model.lengthMs - model.timeMs < 90_000,
              let next = nextFile, nextPreparedID != next.id,
              let h = hash, engineAttached,
              DownloadManager.shared.localURL(hash: h, fileId: next.id) == nil else { return }
        nextPreparedID = next.id
        preloadTask?.cancel()
        preloadTask = Task {
            AppDiagnostics.shared.log("series", "Подготовка \(fileLabel(next))")
            await TorrentWarmup.shared.prepareNext(hash: h, file: next)
        }
    }

    private func fileLabel(_ file: TorrentFile) -> String {
        if let parsed = EpisodeMatcher.numbers(of: file) {
            if let season = parsed.season { return "\(season) сезон, \(parsed.episode) серия" }
            return "\(parsed.episode) серия"
        }
        return (file.name as NSString).deletingPathExtension
    }

    // MARK: - Progress

    private func periodicSave() {
        guard !request.isLive, model.started, !streamKey.isEmpty else { return }
        let now = Date()
        if !model.isBuffering, recoveryAttempts > 0,
           now.timeIntervalSince(playbackBeganAt) > 60 {
            recoveryAttempts = 0
        }
        if now.timeIntervalSince(lastResumeSave) >= 5 {
            lastResumeSave = now
            library.setResume(model.timeMs, for: streamKey)
        }
        if now.timeIntervalSince(lastContinueSave) >= 60 {
            lastContinueSave = now
            saveProgress(final: false)
        }
    }

    /// Season and episode of a file of a series, for the watched marks on the series page.
    private func episodeIdentity(_ file: TorrentFile?) -> (season: Int, episode: Int)? {
        guard request.item?.kind == .series, let file = file,
              let numbers = EpisodeMatcher.numbers(of: file) else { return nil }
        if let season = numbers.season { return (season, numbers.episode) }
        if let season = wantedSeason { return (season, numbers.episode) }
        if let seasons = release(matching: link)?.seasons, seasons.count == 1 { return (seasons[0], numbers.episode) }
        return (1, numbers.episode)
    }

    private func isWatchedEpisode(_ file: TorrentFile) -> Bool {
        guard let key = request.itemKey, let episode = episodeIdentity(file) else { return false }
        return library.isEpisodeWatched(key, season: episode.season, episode: episode.episode)
    }

    /// Files are played one after another (episodes, parts of a film). A film with extras
    /// is still one film: its main file takes most of the torrent.
    private var playsSequence: Bool {
        guard let kind = request.item?.kind else { return files.count > 1 }
        if kind == .series { return true }
        guard files.count > 1, let file = currentFile else { return false }
        return dominantFile(files)?.id != file.id
    }

    private func saveProgress(final: Bool) {
        guard !request.isLive, model.started, !streamKey.isEmpty else { return }
        let time = model.timeMs
        let length = model.lengthMs
        let fraction = length > 0 ? Double(time) / Double(length) : 0
        let finished = model.ended || fraction > 0.95
        library.setResume(finished ? 0 : time, for: streamKey)

        if let key = request.itemKey {
            // The end credits are often skipped: 90% counts as a watched episode.
            if model.ended || fraction >= 0.9, let episode = episodeIdentity(currentFile) {
                library.setEpisodeWatched(key, season: episode.season, episode: episode.episode, watched: true)
            }
            let isSeries = playsSequence
            let title = request.item?.title ?? request.title
            if finished && !isSeries {
                library.removeContinue(key)
                if let item = request.item { library.markWatched(item) }
            } else if finished && nextFile == nil {
                // The last episode of the release: the series page offers the next one
                // (another season) instead of restarting this one.
                library.removeContinue(key)
            } else if finished, let next = nextFile {
                let numbers = isSeries ? EpisodeMatcher.numbers(of: next) : nil
                library.updateContinue(ContinueEntry(itemKey: key, item: request.item, title: title,
                                                     subtitle: "Далее: " + fileLabel(next), link: link,
                                                     fileId: next.id, position: 0, updated: Date(),
                                                     season: numbers.flatMap { $0.season ?? wantedSeason },
                                                     episode: numbers?.episode, time: 0))
            } else {
                var subtitle: String?
                if let file = currentFile, files.count > 1, isSeries {
                    subtitle = fileLabel(file)
                } else if fraction > 0 {
                    subtitle = "Просмотрено \(Int(fraction * 100))%"
                }
                let numbers = isSeries ? currentFile.flatMap { EpisodeMatcher.numbers(of: $0) } : nil
                library.updateContinue(ContinueEntry(itemKey: key, item: request.item, title: title,
                                                     subtitle: subtitle, link: link,
                                                     fileId: currentFile?.id, position: fraction, updated: Date(),
                                                     season: numbers.flatMap { $0.season ?? wantedSeason },
                                                     episode: numbers?.episode, time: time))
            }
        }
        if final { library.persist() }
    }

    private func handleEnded() {
        cancelSwitch()
        recoveryTask?.cancel()
        startupWatchdogTask?.cancel()
        preloadTask?.cancel()
        saveProgress(final: true)
        if request.isLive { return }
        if sleepChoice == .endOfVideo {
            cancelSleepTimer()
            close()
            return
        }
        if autoNext, !autoNextCancelled, let next = nextFile {
            play(next)
        } else {
            close()
        }
    }

    private func close() {
        if !closing {
            closing = true
            pendingTap?.cancel()
            recoveryTask?.cancel()
            startupWatchdogTask?.cancel()
            preloadTask?.cancel()
            cancelSleepTimer()
            saveProgress(final: true)
            model.shutdown()
            AppDiagnostics.shared.setPlayback(nil)
            TorrServer.shared.setPlayerActive(false)
            DownloadManager.shared.playerStreaming = false
            OrientationLock.unlock()
        }
        closeRacers()
        // Always: a second tap on the cross must close the player even if the first one stopped it.
        coordinator.close(request.id)
    }

    private func finish() {
        resolveTask?.cancel()
        switchTask?.cancel()
        closeRacers()
        recoveryTask?.cancel()
        startupWatchdogTask?.cancel()
        preloadTask?.cancel()
        cancelSleepTimer()
        if !closing {
            closing = true
            saveProgress(final: true)
        }
        // Final: the VLC player is released off the main thread once it has stopped.
        model.shutdown()
        OrientationLock.unlock()
        // Another video may already be open (chosen while this one was in Picture in Picture).
        guard coordinator.request == nil || coordinator.request?.id == request.id else { return }
        AppDiagnostics.shared.setPlayback(nil)
        TorrServer.shared.setPlayerActive(false)
        DownloadManager.shared.playerStreaming = false
        IdleTimer.set("player", active: false)
        // The torrent is not dropped here: TorrServer keeps it for a few minutes
        // (reopening or the next episode starts without reconnecting) and closes it itself.
        if OrientationHelper.isPhone {
            OrientationHelper.set(landscape: false)
        }
    }

    private func loadArtwork() async {
        guard let url = request.item?.poster else { return }
        if let image = await ImageCache.shared.load(url), !Task.isCancelled {
            model.setNowPlayingArtwork(image)
        }
    }

    private func pollTorrentStats() async {
        guard let h = hash else { return }
        while !Task.isCancelled {
            if phase == .playing && model.isBuffering && !playingLocal, let s = try? await TorrServer.shared.get(hash: h) {
                bufferInfo = "\(s.speedText) · \(s.peersText)"
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    // MARK: - Controls visibility

    private func bumpControls() {
        guard !controlsLocked else { return }
        withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
        hideToken += 1
        let token = hideToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard token == hideToken, model.isPlaying, !scrubbing, !showFiles, !showOptions else { return }
            withAnimation(.easeInOut(duration: 0.3)) { showControls = false }
        }
    }

    private func toggleControls() {
        guard !controlsLocked else { return }
        if showControls {
            hideToken += 1
            withAnimation(.easeInOut(duration: 0.2)) { showControls = false }
        } else {
            bumpControls()
        }
    }

    private func setSleepTimer(_ choice: SleepChoice) {
        sleepTask?.cancel()
        sleepTask = nil
        sleepChoice = choice
        sleepDeadline = nil
        guard choice.rawValue > 0 else { return }
        let seconds = TimeInterval(choice.rawValue * 60)
        sleepDeadline = Date().addingTimeInterval(seconds)
        sleepTask = Task { @MainActor in
            try? await Task.sleep(seconds: seconds)
            guard !Task.isCancelled, !closing else { return }
            sleepChoice = .off
            sleepDeadline = nil
            sleepTask = nil
            model.pause()
            IdleTimer.set("player", active: false)
            showNotice("Таймер сна остановил воспроизведение")
        }
    }

    private func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepChoice = .off
        sleepDeadline = nil
    }

    private var sleepStatusText: String? {
        if sleepChoice == .endOfVideo { return "до конца" }
        guard let deadline = sleepDeadline else { return nil }
        let minutes = max(1, Int(ceil(deadline.timeIntervalSinceNow / 60)))
        return "\(minutes) мин"
    }

    private func showNotice(_ text: String) {
        playerNotice = text
        noticeToken += 1
        let token = noticeToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard token == noticeToken else { return }
            withAnimation { playerNotice = nil }
        }
    }

    private func updateNextEpisodePrompt() {
        let remaining = model.lengthMs - model.timeMs
        let shouldShow = autoNext && !autoNextCancelled && model.started &&
            model.lengthMs > 0 && remaining > 0 && remaining <= 15_000 && nextFile != nil
        guard shouldShow != showNextEpisodePrompt else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            showNextEpisodePrompt = shouldShow
        }
    }

    private var nextEpisodeCountdown: Int {
        max(1, Int(ceil(Double(max(0, model.lengthMs - model.timeMs)) / 1_000)))
    }

    // MARK: - Screens

    /// The blurred poster is shown until the video plays.
    private var showsBackdrop: Bool {
        if case .playing = phase { return false }
        return true
    }

    private var resolvingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text(statusText)
                .font(.headline)
            if !detailText.isEmpty {
                Text(detailText)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
            }
            Text(request.title)
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Отмена") { close() }
                    .secondaryActionStyle()
                    .tint(.white)
                if hasOtherReleases {
                    Button("Другая раздача") { showQuality = true }
                        .secondaryActionStyle()
                        .tint(.white)
                }
            }
            .padding(.top, 10)
        }
        .foregroundStyle(.white)
        .padding(28)
        .frame(maxWidth: 460)
        .glassSurface(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .padding(24)
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.yellow)
            Text("Не удалось открыть видео")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Повторить") { startResolve() }
                    .prominentButtonStyle()
                if hasOtherReleases {
                    Button("Другая раздача") { showQuality = true }
                        .secondaryActionStyle()
                        .tint(.white)
                }
                Button("Закрыть") { close() }
                    .secondaryActionStyle()
                    .tint(.white)
            }
            .padding(.top, 8)
        }
        .foregroundStyle(.white)
        .padding(28)
        .frame(maxWidth: 460)
        .glassSurface(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .padding(24)
    }

    private var chooserView: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .glassButton(Circle())
                .accessibilityLabel("Закрыть")
                Spacer()
                Text("Выберите файл")
                    .font(.headline)
                Spacer()
                if hasOtherReleases {
                    Button {
                        showQuality = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.title3.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .glassButton(Circle())
                    .accessibilityLabel("Другая раздача")
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }
            }
            .padding()
            if let note = chooserNote {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
            List(files) { file in
                Button {
                    play(file)
                } label: {
                    FileRow(file: file, title: fileLabel(file), selected: false, watched: isWatchedEpisode(file))
                }
                .listRowBackground(Theme.card)
            }
            .scrollContentBackground(.hidden)
        }
        .foregroundStyle(.white)
    }

    private var playerView: some View {
        GeometryReader { proxy in
            ZStack {
                VLCVideoView(model: model)
                    .ignoresSafeArea()
                if controlsLocked {
                    // Touches do nothing while locked; a tap shows the lock that undoes it.
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture { showLockHint() }
                } else if playerGestures {
                    playerGestureLayer(size: proxy.size)
                } else {
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture { toggleControls() }
                }
                if model.failed {
                    playbackFailedOverlay
                } else if model.isBuffering {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                        if hash != nil && !bufferInfo.isEmpty {
                            Text(bufferInfo)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .allowsHitTesting(false)
                }
                if !gestureText.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: gestureIcon)
                            .font(.title2.weight(.semibold))
                        Text(gestureText)
                            .font(.headline.monospacedDigit())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .allowsHitTesting(false)
                }
                if showControls && !controlsLocked && !model.failed {
                    controls
                        .transition(.opacity)
                }
                if controlsLocked && lockHintVisible {
                    lockOverlay
                        .transition(.opacity)
                }
                if let release = switching {
                    VStack {
                        switchBanner(release)
                        Spacer()
                    }
                    .padding(.top, showControls && !controlsLocked ? 72 : 16)
                    .padding(.horizontal, 20)
                    .transition(.opacity)
                }
                if let recoveryText = recoveryText, switching == nil {
                    VStack {
                        HStack(spacing: 10) {
                            ProgressView().tint(.white)
                            Text(recoveryText)
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassSurface(Capsule())
                        Spacer()
                    }
                    .padding(.top, showControls && !controlsLocked ? 72 : 16)
                    .padding(.horizontal, 20)
                }
                if let playerNotice = playerNotice {
                    VStack {
                        Spacer()
                        Text(playerNotice)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .glassSurface(Capsule())
                    }
                    .padding(.bottom, 24)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }
                if showNextEpisodePrompt, let next = nextFile, !controlsLocked {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            VStack(alignment: .leading, spacing: 7) {
                                Text("Следующая серия через \(nextEpisodeCountdown) сек.")
                                    .font(.headline)
                                Text(fileLabel(next))
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.75))
                                HStack(spacing: 10) {
                                    Button("Сейчас") {
                                        showNextEpisodePrompt = false
                                        switchTo(next)
                                    }
                                    .prominentButtonStyle()
                                    Button("Отмена") {
                                        autoNextCancelled = true
                                        showNextEpisodePrompt = false
                                    }
                                    .secondaryActionStyle()
                                    .tint(.white)
                                }
                            }
                            .foregroundStyle(.white)
                            .padding(16)
                            .glassSurface(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, showControls ? 124 : 22)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }

    private func playerGestureLayer(size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .ignoresSafeArea()
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in
                        handleTap(at: value.location, width: size.width)
                    }
            )
            .gesture(
                DragGesture(minimumDistance: 18, coordinateSpace: .local)
                    .onChanged { value in
                        updatePlayerGesture(value, size: size)
                    }
                    .onEnded { _ in
                        finishPlayerGesture()
                    }
            )
    }

    /// A tap in the middle shows or hides the controls at once. On the sides the first tap
    /// waits a moment: a second one seeks 10 seconds back or forward instead (like YouTube).
    private func handleTap(at location: CGPoint, width: CGFloat) {
        let side = location.x < width * 0.38 ? -1 : (location.x > width * 0.62 ? 1 : 0)
        let now = Date()
        let canSeek = side != 0 && !request.isLive && model.isSeekable && model.started
        let interval = now.timeIntervalSince(lastTapAt)
        lastTapAt = now
        if canSeek, seekStreakSide == side, interval < 0.7 {
            seekByTap(side)
            return
        }
        if canSeek, pendingTap != nil, lastTapSide == side, interval < 0.3 {
            pendingTap?.cancel()
            pendingTap = nil
            seekStreakSide = side
            seekStreakSeconds = 0
            seekByTap(side)
            return
        }
        lastTapSide = side
        seekStreakSide = 0
        pendingTap?.cancel()
        pendingTap = nil
        guard canSeek else {
            toggleControls()
            return
        }
        pendingTap = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard !Task.isCancelled else { return }
            pendingTap = nil
            toggleControls()
        }
    }

    private func seekByTap(_ side: Int) {
        seekStreakSeconds += 10
        model.jump(Int32(10 * side))
        gestureIcon = side > 0 ? "goforward" : "gobackward"
        gestureText = "\(side > 0 ? "+" : "−")\(seekStreakSeconds) с · \(TimeFormat.string(ms: model.timeMs))"
        gestureHUDToken += 1
        let token = gestureHUDToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard token == gestureHUDToken, gestureMode == nil else { return }
            seekStreakSide = 0
            withAnimation {
                gestureText = ""
                gestureIcon = ""
            }
        }
    }

    private func updatePlayerGesture(_ value: DragGesture.Value, size: CGSize) {
        guard !controlsLocked, size.width > 0, size.height > 0 else { return }
        let horizontal = abs(value.translation.width)
        let vertical = abs(value.translation.height)
        if gestureMode == nil {
            if horizontal > vertical * 1.15, !request.isLive, model.isSeekable {
                gestureMode = .seek
                gestureStartTime = model.timeMs
            } else if vertical > horizontal * 1.15 {
                if value.startLocation.x < size.width / 2 {
                    gestureMode = .brightness
                    gestureStartLevel = UIScreen.main.brightness
                } else {
                    gestureMode = .volume
                    gestureStartLevel = CGFloat(SystemVolumeController.shared.volume)
                }
            } else {
                return
            }
            hideToken += 1
            withAnimation(.easeInOut(duration: 0.15)) { showControls = false }
        }

        switch gestureMode {
        case .seek:
            let duration = max(1, Double(model.lengthMs))
            let range = min(max(duration * 0.18, 180_000), 900_000)
            let delta = Double(value.translation.width / size.width) * range
            let raw = Double(gestureStartTime) + delta
            let maximum = model.lengthMs > 0 ? Double(model.lengthMs) * 0.995 : Double(Int32.max)
            let target = Int32(min(max(raw, 0), maximum))
            gestureTargetTime = target
            let difference = abs(Int64(target) - Int64(gestureStartTime))
            let amount = TimeFormat.string(ms: Int32(min(difference, Int64(Int32.max))))
            gestureIcon = delta >= 0 ? "goforward" : "gobackward"
            gestureText = "\(delta >= 0 ? "+" : "−")\(amount) · \(TimeFormat.string(ms: target))"
        case .brightness:
            let level = min(1, max(0, gestureStartLevel - value.translation.height / size.height))
            UIScreen.main.brightness = level
            gestureIcon = "sun.max.fill"
            gestureText = "Яркость \(Int((level * 100).rounded()))%"
        case .volume:
            let level = min(1, max(0, gestureStartLevel - value.translation.height / size.height))
            SystemVolumeController.shared.setVolume(Float(level))
            gestureIcon = level == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"
            gestureText = "Громкость \(Int((level * 100).rounded()))%"
        case nil:
            break
        }
    }

    private func finishPlayerGesture() {
        if gestureMode == .seek, let target = gestureTargetTime {
            model.seek(ms: target)
        }
        gestureMode = nil
        gestureTargetTime = nil
        gestureHUDToken += 1
        let token = gestureHUDToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard token == gestureHUDToken, gestureMode == nil else { return }
            withAnimation {
                gestureText = ""
                gestureIcon = ""
            }
        }
    }

    private func switchBanner(_ release: TorrentRelease) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Переключаем на " + (release.qualityText.isEmpty ? "другую раздачу" : release.qualityText) + "…")
                    .font(.subheadline.weight(.semibold))
                if !switchStatus.isEmpty {
                    Text(switchStatus)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            Button("Отмена") { cancelSwitch() }
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassSurface(Capsule())
    }

    private var playbackFailedOverlay: some View {
        VStack(spacing: 12) {
            Text("Ошибка воспроизведения")
                .font(.headline)
            Text(request.isLive ? "Канал недоступен или формат потока не поддерживается." : "Поток прервался или формат не поддерживается.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Повторить") { retryPlayback() }
                    .prominentButtonStyle()
                if hasOtherReleases {
                    Button("Другая раздача") { showQuality = true }
                        .secondaryActionStyle()
                        .tint(.white)
                }
                Button("Закрыть") { close() }
                    .secondaryActionStyle()
                    .tint(.white)
            }
        }
        .foregroundStyle(.white)
        .padding(24)
        .glassSurface(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(24)
    }

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [Color.black.opacity(0.6), .clear, .clear, Color.black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                centerButtons
                Spacer(minLength: 0)
                bottomBar
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }

    private var topBar: some View {
        GlassGroup(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                }
                .glassButton(Circle())
                .accessibilityLabel("Закрыть")
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.item?.title ?? request.title)
                        .font(.headline)
                        .lineLimit(1)
                    if let file = currentFile, files.count > 1 {
                        Text(fileLabel(file))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                }
                .shadow(color: .black.opacity(0.45), radius: 4)
                Spacer(minLength: 8)
                if let sleepStatusText = sleepStatusText {
                    Button {
                        optionsPath = [.sleep]
                        showOptions = true
                    } label: {
                        Label(sleepStatusText, systemImage: "moon.zzz.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 14)
                            .frame(height: 44)
                    }
                    .glassButton(Capsule())
                }
                // The actions of the player in one glass capsule, like a system toolbar.
                HStack(spacing: 0) {
                    if files.count > 1 {
                        topBarButton("list.bullet", label: "Серии и файлы") {
                            showFiles = true
                        }
                    }
                    topBarButton("slider.horizontal.3", label: "Настройки плеера") {
                        showOptions = true
                    }
                    if model.pipSupported {
                        pipButton
                    }
                    topBarButton("lock.fill", label: "Заблокировать экран") {
                        lockControls()
                    }
                    if OrientationHelper.isPhone {
                        topBarButton("rotate.right", label: "Повернуть экран") {
                            OrientationHelper.toggle()
                            bumpControls()
                        }
                    }
                }
                .padding(.horizontal, 4)
                .glassSurface(Capsule())
            }
        }
        .font(.title3.weight(.semibold))
        .foregroundStyle(.white)
        .buttonStyle(.plain)
    }

    private func topBarButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    private var centerButtons: some View {
        GlassGroup(spacing: 24) {
            HStack(spacing: 36) {
                if !request.isLive {
                    Button {
                        model.jump(-10)
                        bumpControls()
                    } label: {
                        Image(systemName: "gobackward.10")
                            .font(.system(size: 26, weight: .semibold))
                            .frame(width: 64, height: 64)
                    }
                    .glassButton(Circle())
                    .accessibilityLabel("Назад на 10 секунд")
                }
                Button {
                    model.togglePlay()
                    bumpControls()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 36, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 88, height: 88)
                }
                .glassButton(Circle())
                .accessibilityLabel(model.isPlaying ? "Пауза" : "Смотреть")
                if !request.isLive {
                    Button {
                        model.jump(10)
                        bumpControls()
                    } label: {
                        Image(systemName: "goforward.10")
                            .font(.system(size: 26, weight: .semibold))
                            .frame(width: 64, height: 64)
                    }
                    .glassButton(Circle())
                    .accessibilityLabel("Вперёд на 10 секунд")
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    /// The length of the video, or the time left ("−12:34") after a tap on it.
    private var durationLabel: String {
        guard showRemaining, model.lengthMs > 0 else { return TimeFormat.string(ms: model.lengthMs) }
        let left = max(Int32(0), model.lengthMs - displayedTime)
        return "−" + TimeFormat.string(ms: left)
    }

    private var displayedTime: Int32 {
        guard scrubbing else { return model.timeMs }
        let fraction = scrubValue.isFinite ? min(max(scrubValue, 0), 1) : 0
        return Int32(fraction * Double(max(0, model.lengthMs)))
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack {
                if request.isLive {
                    Label("Прямой эфир", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .glassSurface(Capsule(), tint: Color.red.opacity(0.45))
                } else if abs(model.rate - 1) > 0.01 {
                    Text(String(format: "Скорость %.2g×", Double(model.rate)))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .glassSurface(Capsule())
                }
                Spacer()
                if let next = nextFile {
                    Button {
                        switchTo(next)
                    } label: {
                        Label("Следующая серия", systemImage: "forward.end.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                    .glassButton(Capsule())
                }
            }
            if !request.isLive {
                // The timeline in a glass capsule at the bottom, where the thumb reaches it.
                HStack(spacing: 12) {
                    Text(TimeFormat.string(ms: displayedTime))
                    Slider(value: Binding(get: { scrubbing ? scrubValue : model.progress },
                                          set: { scrubValue = $0 }),
                           in: 0...1,
                           onEditingChanged: { editing in
                               if editing {
                                   scrubValue = model.progress
                                   scrubbing = true
                               } else {
                                   model.seek(fraction: scrubValue)
                                   scrubbing = false
                                   bumpControls()
                               }
                           })
                        .tint(Theme.accent)
                    Button {
                        showRemaining.toggle()
                        bumpControls()
                    } label: {
                        Text(durationLabel)
                    }
                    .buttonStyle(.plain)
                }
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .glassSurface(Capsule())
            }
        }
        .foregroundStyle(.white)
    }

    // MARK: - Sheets

    private var filesSheet: some View {
        NavigationStack {
            List(files) { file in
                Button {
                    showFiles = false
                    if file != currentFile { switchTo(file) }
                } label: {
                    FileRow(file: file, title: fileLabel(file), selected: file == currentFile,
                            watched: isWatchedEpisode(file))
                }
            }
            .navigationTitle("Серии и файлы")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { showFiles = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private var optionsSheet: some View {
        NavigationStack(path: $optionsPath) {
            List {
                Section {
                    if canSwitchRelease {
                        menuRow("Раздача", icon: "square.stack.3d.up", value: currentReleaseText, page: .release)
                    }
                    menuRow("Озвучка", icon: "waveform", value: currentAudioText, page: .audio)
                    menuRow("Субтитры", icon: "captions.bubble", value: currentSubtitleText, page: .subtitles)
                }
                Section {
                    if !request.isLive {
                        menuRow("Скорость", icon: "speedometer", value: currentRateText, page: .speed)
                    }
                    menuRow("Пропорции", icon: "aspectratio", value: model.aspect.title, page: .aspect)
                    if !request.isLive {
                        menuRow("Синхронизация", icon: "metronome", value: syncText, page: .sync)
                    }
                    menuRow("Таймер сна", icon: "moon.zzz", value: sleepText, page: .sleep)
                }
                Section {
                    if model.pipSupported && phase == .playing {
                        Button {
                            showOptions = false
                            Task { @MainActor in
                                // The sheet closes first: the window starts from the visible video.
                                try? await Task.sleep(nanoseconds: 450_000_000)
                                togglePictureInPicture()
                            }
                        } label: {
                            optionLabel(model.pipActive ? "Вернуть в плеер" : "Картинка в картинке",
                                        icon: model.pipActive ? "pip.exit" : "pip.enter", value: nil)
                        }
                    }
                    if canDownload {
                        menuRow("Скачать", icon: "arrow.down.circle", value: downloadText, page: .download)
                    }
                    if hash != nil && !request.isLive && !playingLocal {
                        menuRow("Торрент", icon: "antenna.radiowaves.left.and.right", value: nil, page: .torrent)
                    }
                }
            }
            .navigationTitle("Настройки плеера")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { showOptions = false }
                }
            }
            .navigationDestination(for: OptionsPage.self) { page in
                optionsPage(page)
                    .navigationBarTitleDisplayMode(.inline)
            }
            .onAppear { model.refreshTracks() }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private func optionLabel(_ title: String, icon: String, value: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Theme.accent)
                .frame(width: 26)
            Text(title)
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            if let value, !value.isEmpty {
                Text(value)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    private func menuRow(_ title: String, icon: String, value: String?, page: OptionsPage) -> some View {
        NavigationLink(value: page) {
            optionLabel(title, icon: icon, value: value)
        }
    }

    /// Back to the menu after a choice.
    private func popOptions() {
        if !optionsPath.isEmpty { optionsPath.removeLast() }
    }

    private var currentReleaseText: String? {
        guard let current = release(matching: link) else { return nil }
        return current.qualityText.isEmpty ? nil : current.qualityText
    }

    private var currentAudioText: String? {
        model.audioTracks.first { $0.id == model.currentAudio }?.name
    }

    private var currentSubtitleText: String {
        if model.subtitleTracks.isEmpty { return "нет" }
        return model.subtitleTracks.first { $0.id == model.currentSubtitle }?.name ?? "выключены"
    }

    private var currentRateText: String {
        PlaybackRates.all.first { abs($0.value - model.rate) < 0.01 }?.title ?? String(format: "%.2g×", Double(model.rate))
    }

    private var syncText: String? {
        var parts: [String] = []
        if model.audioDelayMs != 0 { parts.append("звук " + PlayerHostView.delayText(model.audioDelayMs)) }
        if model.subtitleDelayMs != 0 { parts.append("субт. " + PlayerHostView.delayText(model.subtitleDelayMs)) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private var sleepText: String {
        sleepChoice == .off ? "выключен" : (sleepStatusText ?? sleepChoice.title)
    }

    private var canDownload: Bool {
        !request.isLive && hash != nil && !files.isEmpty && LinkInspector.kind(of: link) == .torrent
    }

    private var downloadText: String? {
        guard let h = hash, let file = currentFile, let item = DownloadManager.shared.item(hash: h, fileId: file.id) else { return nil }
        switch item.state {
        case .completed: return "скачано"
        case .failed: return "ошибка"
        case .paused: return "пауза"
        case .queued, .downloading: return "\(Int(item.progress * 100))%"
        }
    }

    @ViewBuilder
    private func optionsPage(_ page: OptionsPage) -> some View {
        switch page {
        case .release:
            List { qualitySection }
                .navigationTitle("Раздача")
        case .audio:
            audioPage
        case .subtitles:
            subtitlesPage
        case .subtitleSearch:
            SubtitleSearchList(query: { await subtitleQuery() },
                               onPick: { url, candidate in addFoundSubtitles(url, candidate) })
        case .speed:
            List {
                Section {
                    ForEach(PlaybackRates.all) { option in
                        checkRow(option.title, selected: abs(option.value - model.rate) < 0.01) {
                            model.setRate(option.value)
                            if savePlayerSettings { savedRate = Double(option.value) }
                            popOptions()
                        }
                    }
                }
            }
            .navigationTitle("Скорость")
        case .aspect:
            List {
                Section {
                    ForEach(AspectMode.allCases) { mode in
                        checkRow(mode.title, selected: mode == model.aspect) {
                            model.setAspect(mode)
                            if savePlayerSettings { savedAspect = mode.rawValue }
                            popOptions()
                        }
                    }
                }
            }
            .navigationTitle("Пропорции")
        case .sync:
            List {
                Section {
                    delayRow("Звук", value: model.audioDelayMs, step: 100) { model.setAudioDelay(ms: $0) }
                    if model.subtitleTracks.count > 1 {
                        delayRow("Субтитры", value: model.subtitleDelayMs, step: 500) { model.setSubtitleDelay(ms: $0) }
                    }
                } footer: {
                    Text("Голос не совпадает с губами — сдвиньте звук: «+» — позже, «−» — раньше. Сдвиг действует до закрытия плеера.")
                }
            }
            .navigationTitle("Синхронизация")
        case .sleep:
            List {
                Section {
                    ForEach(SleepChoice.allCases.filter { !request.isLive || $0 != .endOfVideo }) { choice in
                        checkRow(choice.title, selected: sleepChoice == choice) {
                            setSleepTimer(choice)
                            popOptions()
                        }
                    }
                }
            }
            .navigationTitle("Таймер сна")
        case .download:
            if let h = hash {
                PlayerDownloadPage(hash: h, current: currentFile,
                                   isSeries: request.item?.kind == .series || files.count > 1,
                                   season: releaseSeason ?? wantedSeason,
                                   seasonFiles: seasonFilesForDownload,
                                   allVideos: files) { selection in
                    enqueueDownload(selection)
                }
            }
        case .torrent:
            if let h = hash {
                List { TorrentStatsSection(hash: h) }
                    .navigationTitle("Торрент")
            }
        }
    }

    private var audioPage: some View {
        List {
            Section {
                if model.audioTracks.isEmpty {
                    Text("Дорожки появятся после начала воспроизведения")
                        .foregroundStyle(Theme.secondary)
                }
                ForEach(model.audioTracks) { track in
                    checkRow(track.name, selected: track.id == model.currentAudio) {
                        selectAudio(track, remember: true)
                        popOptions()
                    }
                }
            }
            if !externalAudio.isEmpty {
                Section {
                    ForEach(externalAudio) { file in
                        checkRow(audioTitle(file), selected: addedAudio.contains(file.id)) {
                            addExternalAudio(file)
                        }
                    }
                } header: {
                    Text("Внешние озвучки")
                } footer: {
                    Text("Отдельные дорожки из раздачи. После подключения выберите её выше, если она не включилась сама.")
                }
            }
        }
        .navigationTitle("Озвучка")
    }

    private var subtitlesPage: some View {
        List {
            Section {
                if model.subtitleTracks.isEmpty {
                    Text("В видео нет субтитров")
                        .foregroundStyle(Theme.secondary)
                }
                ForEach(model.subtitleTracks) { track in
                    checkRow(track.name, selected: track.id == model.currentSubtitle) {
                        selectSubtitle(track, remember: true)
                        popOptions()
                    }
                }
            }
            if !request.isLive {
                Section {
                    NavigationLink(value: OptionsPage.subtitleSearch) {
                        optionLabel("Найти в интернете", icon: "magnifyingglass", value: nil)
                    }
                } footer: {
                    Text("OpenSubtitles.com: субтитры под этот файл на языке из настроек.")
                }
            }
            if model.subtitleTracks.count > 1 {
                Section("Сдвиг") {
                    delayRow("Субтитры", value: model.subtitleDelayMs, step: 500) { model.setSubtitleDelay(ms: $0) }
                }
            }
        }
        .navigationTitle("Субтитры")
    }

    private var seasonFilesForDownload: [TorrentFile] {
        guard request.item?.kind == .series || files.count > 1,
              let season = releaseSeason ?? wantedSeason else { return [] }
        return DownloadSelection.files(allFiles, isSeries: true, season: season, episode: nil)
    }

    private func enqueueDownload(_ selection: [TorrentFile]) {
        guard let h = hash, !selection.isEmpty else { return }
        let count = DownloadManager.shared.enqueue(files: selection, all: allFiles, hash: h, link: link,
                                                   title: request.item?.title ?? request.title,
                                                   item: request.item, itemKey: request.itemKey,
                                                   season: releaseSeason ?? wantedSeason)
        showOptions = false
        showNotice(count > 0 ? "Добавлено в загрузки: \(count)" : "Уже в загрузках")
    }

    // MARK: - Subtitles from the internet

    private func subtitleQuery() async -> SubtitleService.Query {
        let item = request.item
        var query = SubtitleService.Query(title: item?.title ?? request.title, originalTitle: item?.originalTitle,
                                          year: item?.year, imdbId: nil, isSeries: item?.kind == .series,
                                          season: nil, episode: nil, movieHash: nil, releaseName: currentFile?.name)
        if query.isSeries, let identity = episodeIdentity(currentFile) {
            query.season = identity.season
            query.episode = identity.episode
        }
        if let id = item?.id, id > 0 {
            let lookup = Task { try await KPClient.shared.film(id).imdbId }
            if case .success(let imdb)? = await TaskWait.result(of: lookup, within: 6) {
                query.imdbId = imdb
            }
        }
        if let url = streamURL, let file = currentFile {
            query.movieHash = await SubtitleService.movieHash(of: url, size: file.length)
        }
        return query
    }

    private func addFoundSubtitles(_ url: URL, _ candidate: SubtitleCandidate) {
        model.addSubtitleSlave(url, select: true)
        showOptions = false
        showNotice("Субтитры подключены: " + SubtitleService.languageTitle(candidate.language).lowercased())
        AppDiagnostics.shared.log("subtitles", "Подключены найденные субтитры \(candidate.language)")
    }

    /// A foreign film without a Russian dub or subtitles gets subtitles from OpenSubtitles (a setting).
    private func scheduleAutoSubtitles() {
        guard subtitleAuto, !openSubtitlesKey.trimmed.isEmpty, !request.isLive, !streamKey.isEmpty,
              !autoSubtitleTried.contains(streamKey) else { return }
        let key = streamKey
        Task { @MainActor in
            // The tracks of the stream are known a few seconds after the start.
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !closing, streamKey == key, model.started, !autoSubtitleTried.contains(key) else { return }
            model.refreshTracks()
            let audio = model.audioTracks.map(\.name)
            let subtitles = model.subtitleTracks.filter { $0.id >= 0 }.map(\.name)
            guard TrackLanguage.needsSubtitles(audio: audio, subtitles: subtitles) else { return }
            autoSubtitleTried.insert(key)
            do {
                let query = await subtitleQuery()
                let found = try await SubtitleService.shared.search(query)
                guard let best = found.first(where: { !$0.machineTranslated }) ?? found.first,
                      streamKey == key, !closing else { return }
                let url = try await SubtitleService.shared.download(best)
                guard streamKey == key, !closing else { return }
                model.addSubtitleSlave(url, select: true)
                showNotice("Включены субтитры: " + SubtitleService.languageTitle(best.language).lowercased())
            } catch {
                AppDiagnostics.shared.log("subtitles", "Автопоиск субтитров: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Lock and Picture in Picture

    private func lockControls() {
        hideToken += 1
        controlsLocked = true
        withAnimation(.easeInOut(duration: 0.2)) { showControls = false }
        OrientationLock.lockCurrent()
        showLockHint()
    }

    private func unlockControls() {
        controlsLocked = false
        lockHintToken += 1
        lockHintVisible = false
        OrientationLock.unlock()
        bumpControls()
    }

    private func showLockHint() {
        lockHintToken += 1
        let token = lockHintToken
        withAnimation(.easeInOut(duration: 0.2)) { lockHintVisible = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard token == lockHintToken else { return }
            withAnimation(.easeInOut(duration: 0.3)) { lockHintVisible = false }
        }
    }

    /// Shown for a moment after a tap on the locked screen: the lock in the middle unlocks.
    private var lockOverlay: some View {
        VStack(spacing: 14) {
            Spacer()
            Button {
                unlockControls()
            } label: {
                Image(systemName: "lock.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .frame(width: 80, height: 80)
            }
            .glassButton(Circle())
            .accessibilityLabel("Разблокировать")
            VStack(spacing: 4) {
                Text("Экран заблокирован")
                    .font(.headline)
                Text("Нажмите на замок, чтобы разблокировать")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .shadow(color: .black.opacity(0.6), radius: 4)
            Spacer()
            if !request.isLive, model.lengthMs > 0 {
                Text("\(TimeFormat.string(ms: model.timeMs)) / \(TimeFormat.string(ms: model.lengthMs))")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassSurface(Capsule())
                    .padding(.bottom, 18)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pipButton: some View {
        Button {
            togglePictureInPicture()
        } label: {
            ZStack {
                if model.preparingPiP {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: model.pipActive ? "pip.exit" : "pip.enter")
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .disabled(phase != .playing)
        .accessibilityLabel("Картинка в картинке")
    }

    private func togglePictureInPicture() {
        if model.pipActive {
            model.exitPictureInPicture()
        } else if !model.preparingPiP {
            if model.renderMode == .native { showNotice("Готовим картинку в картинке…") }
            model.enterPictureInPicture()
        }
        bumpControls()
    }

    /// The video went to the floating window: the app is usable meanwhile.
    private func pictureInPictureStarted() {
        // Started by iOS when the app was closed: the player stays as it is.
        guard !model.pipStartedAutomatically else { return }
        showOptions = false
        showFiles = false
        showQuality = false
        if controlsLocked { unlockControls() }
        OrientationLock.unlock()
        coordinator.minimized = true
        if OrientationHelper.isPhone { OrientationHelper.set(landscape: false) }
    }

    /// The button of the floating window that brings the video back to the player.
    private func restoreFromPictureInPicture() {
        let wasMinimized = coordinator.minimized
        coordinator.minimized = false
        if wasMinimized, OrientationHelper.isPhone { OrientationHelper.set(landscape: true) }
        bumpControls()
    }

    /// The cross of the floating window.
    private func pictureInPictureClosed() {
        if coordinator.minimized {
            close()
        } else {
            model.pause()
        }
    }

    private func enteredBackgroundWithoutWindow() {
        if backgroundAudio && phase == .playing {
            // Keep the sound playing (lock screen, other apps); the picture is not needed.
            model.setVideoEnabled(false)
        } else {
            model.pause()
        }
    }

    private var qualitySheet: some View {
        NavigationStack {
            List {
                qualitySection
            }
            .navigationTitle("Другая раздача")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { showQuality = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    // MARK: - Quality (another release of the same film)

    private var canSwitchRelease: Bool {
        !request.isLive && request.item != nil && request.itemKey != nil
    }

    private func loadAlternatives() async {
        guard canSwitchRelease, !alternativesLoaded, let item = request.item else { return }
        // Usually instant: the film page has searched already.
        if let result = try? await TorrentSearchService.shared.search(TorrentSearchQuery(item: item)) {
            alternatives = library.allowedReleases(result.releases)
            AppDiagnostics.shared.log("search", "Для плеера доступно раздач: \(alternatives.count)")
            if model.started { recordPlaybackSuccessIfPossible() }
        }
        alternativesLoaded = true
    }

    /// Season of what plays (series): releases of other seasons are not offered.
    private var releaseSeason: Int? {
        guard request.item?.kind == .series else { return nil }
        if let file = currentFile, let season = EpisodeMatcher.numbers(of: file)?.season { return season }
        return wantedSeason
    }

    private func isCurrent(_ release: TorrentRelease) -> Bool {
        if let playing = hash?.lowercased(), let other = release.hash?.lowercased(), playing == other { return true }
        return LinkInspector.markTorrent(release.link) == link
    }

    /// The best release of every quality (the one that plays stays for its own quality).
    private var qualityChoices: [TorrentRelease] {
        ReleaseRanking.perQuality(alternatives, season: releaseSeason, current: alternatives.first { isCurrent($0) })
    }

    private var hasOtherReleases: Bool {
        canSwitchRelease && qualityChoices.contains { !isCurrent($0) }
    }

    @ViewBuilder
    private var qualitySection: some View {
        if canSwitchRelease {
            Section {
                let choices = qualityChoices
                if !alternativesLoaded {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Ищем раздачи…")
                            .foregroundStyle(Theme.secondary)
                    }
                } else if choices.isEmpty {
                    Text("Других раздач не найдено")
                        .foregroundStyle(Theme.secondary)
                }
                ForEach(choices) { release in
                    releaseChoiceRow(release)
                }
            } header: {
                Text("Качество")
            } footer: {
                Text(phase == .playing
                     ? "Раздача сменится, а просмотр продолжится с того же места."
                     : "Вместо текущей откроется выбранная раздача.")
            }
        }
    }

    private func releaseChoiceRow(_ release: TorrentRelease) -> some View {
        let selected = isCurrent(release)
        return Button {
            if !selected { switchRelease(to: release) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(release.qualityText.isEmpty ? "Другое качество" : release.qualityText)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(choiceDetails(release))
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if switching == release {
                    ProgressView()
                } else if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .contextMenu {
            if !selected {
                Button(role: .destructive) {
                    library.blockRelease(release)
                    alternatives.removeAll { $0.id == release.id }
                } label: {
                    Label("Не предлагать эту раздачу", systemImage: "hand.thumbsdown")
                }
            }
        }
    }

    private func choiceDetails(_ release: TorrentRelease) -> String {
        var parts: [String] = []
        if !release.sizeText.isEmpty { parts.append(release.sizeText) }
        if let voice = release.voices.first { parts.append(voice) }
        parts.append("сиды: \(release.seeders)")
        return parts.joined(separator: " · ")
    }

    private func switchRelease(to release: TorrentRelease) {
        let newLink = LinkInspector.markTorrent(release.link)
        showOptions = false
        showQuality = false
        guard newLink != link else { return }
        desiredQuality = release.quality
        if phase == .playing {
            hotSwitch(to: release, link: newLink)
        } else {
            // Nothing plays yet: open the other release instead of this one.
            cancelSwitch()
            if let key = request.itemKey { library.addSource(SavedSource(release: release), for: key) }
            link = newLink
            wantedFileId = nil
            startResolve()
        }
    }

    /// Opens the other release while the current one keeps playing, then goes on from the same place.
    private func hotSwitch(to release: TorrentRelease, link newLink: String) {
        cancelSwitch()
        switching = release
        switchStatus = "Подключение…"
        attemptStartedAt = Date()
        playbackSuccessRecorded = false
        firstFrameLogged = false
        startupMs = nil
        let title = request.item?.title ?? request.title
        let poster = request.item?.posterURL
        let target: (season: Int?, episode: Int)?
        if let parsed = currentFile.flatMap({ EpisodeMatcher.numbers(of: $0) }) {
            target = parsed
        } else if let episode = wantedEpisode {
            target = (season: wantedSeason, episode: episode)
        } else {
            target = nil
        }
        // A film with extras is matched by its main file, not by an episode number.
        let isEpisode = request.item?.kind == .series || (playsSequence && target != nil)
        switchTask = Task {
            do {
                try await TorrServer.shared.ensureRunning()
                let status = try await TorrServer.shared.add(link: LinkInspector.stripMarker(newLink), title: title, poster: poster)
                guard let h = status.hash, !h.isEmpty else {
                    throw TorrServerError.server("не удалось добавить торрент")
                }
                let all = try await TorrServer.shared.waitForFiles(hash: h, timeout: 90) { s in
                    if switching == release { switchStatus = s.peersText }
                }
                try Task.checkCancellation()
                let list = videoFiles(all)
                var file: TorrentFile?
                if isEpisode {
                    if let target = target {
                        file = EpisodeMatcher.find(in: list, season: target.season, episode: target.episode)
                    }
                } else {
                    file = list.count == 1 ? list.first : dominantFile(list)
                }
                guard let chosen = file else { throw SwitchFailure.noSameFile }
                guard !closing, switching == release else { return }
                let position = model.timeMs
                saveProgress(final: true)
                if let key = request.itemKey { library.addSource(SavedSource(release: release), for: key) }
                link = newLink
                attemptedLinks.insert(canonicalLink(newLink))
                wantedFileId = nil
                if let target = target {
                    wantedSeason = target.season ?? wantedSeason
                    wantedEpisode = target.episode
                }
                hash = h
                allFiles = all
                files = list
                switching = nil
                play(chosen, startAt: position)
                TorrentWarmup.shared.playbackStarted(hash: h)
            } catch {
                guard !Task.isCancelled, !closing, switching == release else { return }
                PlaybackLearning.shared.recordFailure(release)
                AppDiagnostics.shared.log("switch", "Смена раздачи не удалась: \(error.localizedDescription)")
                switching = nil
                switchError = error.localizedDescription
            }
        }
    }

    private func cancelSwitch() {
        switchTask?.cancel()
        switchTask = nil
        switching = nil
    }

    private func addExternalAudio(_ file: TorrentFile) {
        guard !addedAudio.contains(file.id), let h = hash,
              let url = TorrServer.shared.streamURL(hash: h, file: file) else { return }
        addedAudio.insert(file.id)
        model.addAudioSlave(url)
    }

    private func delayRow(_ title: String, value: Int, step: Int, change: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 8)
            if value != 0 {
                Button("Сброс") { change(0) }
                    .buttonStyle(.borderless)
                    .font(.subheadline)
            }
            Button {
                change(value - step)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            Text(PlayerHostView.delayText(value))
                .font(.body.monospacedDigit())
                .frame(minWidth: 64)
            Button {
                change(value + step)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
        }
    }

    private static func delayText(_ ms: Int) -> String {
        guard ms != 0 else { return "0 с" }
        let text = String(format: "%.1f", Double(abs(ms)) / 1_000).replacingOccurrences(of: ".", with: ",")
        return (ms > 0 ? "+" : "−") + text + " с"
    }

    private func checkRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(.white)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.accent)
                }
            }
            .contentShape(Rectangle())
        }
    }
}

struct FileRow: View {
    let file: TorrentFile
    let title: String
    let selected: Bool
    var watched = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "play.circle.fill" : (watched ? "checkmark.circle.fill" : "film"))
                .foregroundStyle(selected || watched ? Theme.accent : Theme.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text("\(file.sizeText) · \(file.path)")
                    .font(.caption2)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

private enum SwitchFailure: LocalizedError {
    case noSameFile

    var errorDescription: String? {
        "В этой раздаче не удалось найти тот же фильм или серию автоматически. Её можно открыть из «Раздач» на странице фильма."
    }
}
