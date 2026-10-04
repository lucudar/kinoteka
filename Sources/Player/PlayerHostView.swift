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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
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
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
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
            UIApplication.shared.isIdleTimerDisabled = true
            if OrientationHelper.isPhone {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    OrientationHelper.set(landscape: true)
                }
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            finish()
        }
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
                UIApplication.shared.isIdleTimerDisabled = true
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
            if !open { bumpControls() }
        }
        .onChange(of: showFiles) { _, open in
            if !open { bumpControls() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                model.setVideoEnabled(true)
            case .background:
                recoveryTask?.cancel()
                startupWatchdogTask?.cancel()
                saveProgress(final: true)
                if backgroundAudio && phase == .playing {
                    // Keep the sound playing (lock screen, other apps); the picture is not needed.
                    model.setVideoEnabled(false)
                } else {
                    model.pause()
                }
            default:
                saveProgress(final: true)
            }
        }
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
                PlaybackLearning.shared.recordFailure(release)
                AppDiagnostics.shared.log("player", "Запуск не удался: \(error.localizedDescription)")
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
        phase = .resolving
        statusText = fallbackCount > 0 ? "Пробуем запасную раздачу…" : "Запуск торрент-движка…"
        detailText = ""
        try await TorrServer.shared.ensureRunning()
        statusText = "Получение данных торрента…"
        let status = try await TorrServer.shared.add(link: torrent, title: request.item?.title ?? request.title, poster: request.item?.posterURL)
        try Task.checkCancellation()
        guard let h = status.hash, !h.isEmpty else {
            throw TorrServerError.server("не удалось добавить торрент")
        }
        hash = h
        // Torrents that are not needed now (played before, prepared for another film) are freed.
        TorrentWarmup.shared.playbackStarted(hash: h)
        let timeout: TimeInterval = automaticFallback && canSwitchRelease ? (fallbackCount == 0 ? 10 : 18) : 120
        let all: [TorrentFile]
        if !status.files.isEmpty {
            all = status.files
        } else {
            all = try await TorrServer.shared.waitForFiles(hash: h, timeout: timeout) { s in
                statusText = "Подключение к пирам…"
                detailText = s.peersText
            }
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
        let videos = EpisodeMatcher.sorted(all.filter { $0.isVideo })
        let main = videos.filter { !($0.name.lowercased().contains("sample") && $0.length < 300_000_000) }
        return main.isEmpty ? videos : main
    }

    private func takePendingStart() -> Int32? {
        let value = pendingStart
        pendingStart = nil
        return value
    }

    /// For movies: the file that takes most of the torrent (main feature vs extras).
    private func dominantFile(_ list: [TorrentFile]) -> TorrentFile? {
        let total = list.reduce(Int64(0)) { $0 + $1.length }
        guard total > 0, let largest = list.max(by: { $0.length < $1.length }) else { return nil }
        return Double(largest.length) >= Double(total) * 0.7 ? largest : nil
    }

    /// `startAt`: position in the file (another release of what played); otherwise the saved one.
    private func play(_ file: TorrentFile, startAt: Int32? = nil) {
        guard let h = hash, let url = TorrServer.shared.streamURL(hash: h, file: file) else { return }
        preloadTask?.cancel()
        preloadTask = nil
        nextPreparedID = nil
        showNextEpisodePrompt = false
        autoNextCancelled = false
        currentFile = file
        streamKey = "\(h):\(file.id)"
        addedAudio = []
        start(url: url, slaves: subtitleSlaves(for: file), startAt: startAt)
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
        guard let file = currentFile else { return [] }
        return companions(for: file, extensions: PlayerHostView.audioExtensions)
    }

    private func audioTitle(_ file: TorrentFile) -> String {
        let folder = ((file.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return folder.isEmpty ? file.name : "\(folder) (\(file.ext))"
    }

    private func start(url: URL, slaves: [(URL, VLCMediaPlaybackSlaveType)], startAt: Int32? = nil) {
        streamURL = url
        phase = .playing
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
        if request.isLive { options["network-caching"] = 1500 }
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
              let h = hash else { return }
        nextPreparedID = next.id
        preloadTask?.cancel()
        preloadTask = Task {
            AppDiagnostics.shared.log("series", "Подготовка \(fileLabel(next))")
            await TorrServer.shared.prefetch(hash: h, file: next)
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
        guard !closing else { return }
        closing = true
        pendingTap?.cancel()
        recoveryTask?.cancel()
        startupWatchdogTask?.cancel()
        preloadTask?.cancel()
        cancelSleepTimer()
        saveProgress(final: true)
        model.shutdown()
        AppDiagnostics.shared.setPlayback(nil)
        coordinator.request = nil
    }

    private func finish() {
        resolveTask?.cancel()
        switchTask?.cancel()
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
        AppDiagnostics.shared.setPlayback(nil)
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
            if phase == .playing && model.isBuffering, let s = try? await TorrServer.shared.get(hash: h) {
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
            UIApplication.shared.isIdleTimerDisabled = false
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
                    .buttonStyle(.bordered)
                    .tint(.white)
                if hasOtherReleases {
                    Button("Другая раздача") { showQuality = true }
                        .buttonStyle(.bordered)
                        .tint(.white)
                }
            }
            .padding(.top, 10)
        }
        .foregroundStyle(.white)
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
                    .buttonStyle(.borderedProminent)
                if hasOtherReleases {
                    Button("Другая раздача") { showQuality = true }
                        .buttonStyle(.bordered)
                        .tint(.white)
                }
                Button("Закрыть") { close() }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
            .padding(.top, 8)
        }
        .foregroundStyle(.white)
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
                }
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
                    }
                } else {
                    Color.clear.frame(width: 24, height: 24)
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
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
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
                    .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .allowsHitTesting(false)
                }
                if showControls && !controlsLocked && !model.failed {
                    controls
                        .transition(.opacity)
                }
                if controlsLocked {
                    VStack {
                        HStack {
                            Spacer()
                            Button {
                                controlsLocked = false
                                bumpControls()
                            } label: {
                                Label("Разблокировать", systemImage: "lock.open.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .background(Color.black.opacity(0.68), in: Capsule())
                            }
                        }
                        Spacer()
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
                if let release = switching {
                    VStack {
                        switchBanner(release)
                        Spacer()
                    }
                    .padding(.top, showControls && !controlsLocked ? 64 : 16)
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
                        .background(Color.black.opacity(0.75), in: Capsule())
                        Spacer()
                    }
                    .padding(.top, showControls && !controlsLocked ? 64 : 16)
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
                            .background(Color.black.opacity(0.75), in: Capsule())
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
                                    .buttonStyle(.borderedProminent)
                                    Button("Отмена") {
                                        autoNextCancelled = true
                                        showNextEpisodePrompt = false
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.white)
                                }
                            }
                            .foregroundStyle(.white)
                            .padding(16)
                            .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, showControls ? 72 : 22)
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
        .background(Color.black.opacity(0.75), in: Capsule())
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
                    .buttonStyle(.borderedProminent)
                if hasOtherReleases {
                    Button("Другая раздача") { showQuality = true }
                        .buttonStyle(.bordered)
                        .tint(.white)
                }
                Button("Закрыть") { close() }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
        }
        .foregroundStyle(.white)
        .padding(24)
        .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(24)
    }

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [Color.black.opacity(0.75), .clear, .clear, Color.black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
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
        HStack(spacing: 22) {
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
            }
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
            Spacer(minLength: 8)
            if let sleepStatusText = sleepStatusText {
                Button {
                    showOptions = true
                } label: {
                    Label(sleepStatusText, systemImage: "moon.zzz.fill")
                        .font(.caption.weight(.semibold))
                }
            }
            if files.count > 1 {
                Button {
                    showFiles = true
                } label: {
                    Image(systemName: "list.bullet")
                }
            }
            Button {
                showOptions = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            Button {
                hideToken += 1
                controlsLocked = true
                withAnimation(.easeInOut(duration: 0.2)) { showControls = false }
            } label: {
                Image(systemName: "lock.fill")
            }
            if OrientationHelper.isPhone {
                Button {
                    OrientationHelper.toggle()
                    bumpControls()
                } label: {
                    Image(systemName: "rotate.right")
                }
            }
        }
        .font(.title3.weight(.semibold))
        .foregroundStyle(.white)
    }

    private var centerButtons: some View {
        HStack(spacing: 60) {
            if !request.isLive {
                Button {
                    model.jump(-10)
                    bumpControls()
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 32, weight: .medium))
                }
            }
            Button {
                model.togglePlay()
                bumpControls()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44, weight: .bold))
                    .frame(width: 64, height: 64)
            }
            if !request.isLive {
                Button {
                    model.jump(10)
                    bumpControls()
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 32, weight: .medium))
                }
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 6)
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
        VStack(spacing: 6) {
            if !request.isLive {
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
            }
            HStack {
                if request.isLive {
                    Label("Прямой эфир", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption.weight(.semibold))
                } else if abs(model.rate - 1) > 0.01 {
                    Text(String(format: "Скорость %.2g×", Double(model.rate)))
                        .font(.caption.weight(.semibold))
                }
                Spacer()
                if let next = nextFile {
                    Button {
                        switchTo(next)
                    } label: {
                        Label("Следующая серия", systemImage: "forward.end.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                }
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
        NavigationStack {
            List {
                qualitySection

                Section("Озвучка") {
                    if model.audioTracks.isEmpty {
                        Text("Дорожки появятся после начала воспроизведения")
                            .foregroundStyle(Theme.secondary)
                    }
                    ForEach(model.audioTracks) { track in
                        checkRow(track.name, selected: track.id == model.currentAudio) {
                            selectAudio(track, remember: true)
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
                        Text("Отдельные звуковые дорожки из раздачи. После подключения выберите её в списке «Озвучка», если она не включилась сама.")
                    }
                }

                if model.subtitleTracks.count > 1 {
                    Section("Субтитры") {
                        ForEach(model.subtitleTracks) { track in
                            checkRow(track.name, selected: track.id == model.currentSubtitle) {
                                selectSubtitle(track, remember: true)
                            }
                        }
                    }
                }

                if !request.isLive {
                    Section {
                        delayRow("Звук", value: model.audioDelayMs, step: 100) { model.setAudioDelay(ms: $0) }
                        if model.subtitleTracks.count > 1 {
                            delayRow("Субтитры", value: model.subtitleDelayMs, step: 500) { model.setSubtitleDelay(ms: $0) }
                        }
                    } header: {
                        Text("Синхронизация")
                    } footer: {
                        Text("Если голос не совпадает с губами (бывает у отдельных озвучек), сдвиньте звук: «+» — позже, «−» — раньше. Сдвиг сохраняется до закрытия плеера.")
                    }
                }

                Section("Таймер сна") {
                    ForEach(SleepChoice.allCases.filter { !request.isLive || $0 != .endOfVideo }) { choice in
                        checkRow(choice.title, selected: sleepChoice == choice) {
                            setSleepTimer(choice)
                        }
                    }
                }

                if !request.isLive {
                    Section("Скорость") {
                        ForEach(PlaybackRates.all) { option in
                            checkRow(option.title, selected: abs(option.value - model.rate) < 0.01) {
                                model.setRate(option.value)
                                if savePlayerSettings { savedRate = Double(option.value) }
                            }
                        }
                    }
                }

                Section("Пропорции") {
                    ForEach(AspectMode.allCases) { mode in
                        checkRow(mode.title, selected: mode == model.aspect) {
                            model.setAspect(mode)
                            if savePlayerSettings { savedAspect = mode.rawValue }
                        }
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
            .onAppear { model.refreshTracks() }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
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
