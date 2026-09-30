import SwiftUI
import UIKit
import VLCKitSPM

struct PlayerHostView: View {
    let request: PlayRequest

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = VLCPlayerModel()

    @AppStorage(SettingsKeys.autoNext) private var autoNext = true
    @AppStorage(SettingsKeys.savePlayerSettings) private var savePlayerSettings = true
    @AppStorage(SettingsKeys.playerRate) private var savedRate = 1.0
    @AppStorage(SettingsKeys.playerAspect) private var savedAspect = AspectMode.fit.rawValue
    @AppStorage(SettingsKeys.backgroundAudio) private var backgroundAudio = true

    enum Phase: Equatable {
        case resolving
        case choosing
        case playing
        case failed(String)
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
    /// The link that plays: the requested one, or another release picked in "Качество".
    @State private var link: String
    @State private var wantedFileId: Int?
    @State private var wantedSeason: Int?
    @State private var wantedEpisode: Int?
    /// Where to start the first file (continuing in another release).
    @State private var pendingStart: Int32?
    @State private var resolveTask: Task<Void, Never>?
    /// Releases found for the film: the choices of "Качество".
    @State private var alternatives: [TorrentRelease] = []
    @State private var alternativesLoaded = false
    @State private var switching: TorrentRelease?
    @State private var switchStatus = ""
    @State private var switchTask: Task<Void, Never>?
    @State private var switchError: String?
    @State private var showQuality = false

    init(request: PlayRequest) {
        self.request = request
        _link = State(initialValue: request.link)
        _wantedFileId = State(initialValue: request.preferredFileId)
        _wantedSeason = State(initialValue: request.season)
        _wantedEpisode = State(initialValue: request.episode)
        _pendingStart = State(initialValue: request.startTime)
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
            if resolveTask == nil { startResolve() }
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
        }
        .onChange(of: model.ended) { _, ended in
            if ended { handleEnded() }
        }
        .onChange(of: model.isPlaying) { _, playing in
            if playing { bumpControls() } else { withAnimation { showControls = true } }
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

    private func startResolve() {
        resolveTask?.cancel()
        resolveTask = Task { await resolve() }
    }

    private func resolve() async {
        let target = link.trimmed
        switch LinkInspector.kind(of: target) {
        case .direct:
            guard let url = URL(string: target) else {
                phase = .failed("Некорректная ссылка.")
                return
            }
            streamKey = target
            start(url: url, slaves: [])
        case .torrent:
            await resolveTorrent(LinkInspector.stripMarker(target))
        }
    }

    private func resolveTorrent(_ torrent: String) async {
        phase = .resolving
        do {
            statusText = "Запуск торрент-движка…"
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
            let all = try await TorrServer.shared.waitForFiles(hash: h) { s in
                statusText = "Подключение к пирам…"
                detailText = s.peersText
            }
            try Task.checkCancellation()
            allFiles = all
            let list = videoFiles(all)
            guard !list.isEmpty else { throw TorrServerError.noVideo }
            files = list

            if let id = wantedFileId, let file = list.first(where: { $0.id == id }) {
                play(file, startAt: takePendingStart())
            } else if let episode = wantedEpisode, let file = EpisodeMatcher.find(in: list, season: wantedSeason, episode: episode) {
                play(file, startAt: takePendingStart())
            } else if list.count == 1 {
                play(list[0], startAt: takePendingStart())
            } else if wantedEpisode == nil, request.item?.kind != .series, let largest = dominantFile(list) {
                play(largest, startAt: takePendingStart())
            } else {
                chooserNote = wantedEpisode != nil ? "Не удалось найти серию автоматически — выберите файл." : nil
                phase = .choosing
            }
        } catch {
            if Task.isCancelled || closing { return }
            phase = .failed(error.localizedDescription)
        }
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
        bumpControls()
    }

    private func retryPlayback() {
        guard let url = streamURL else {
            startResolve()
            return
        }
        if model.timeMs > 0 && !request.isLive {
            library.setResume(model.timeMs, for: streamKey)
        }
        start(url: url, slaves: currentFile.map { subtitleSlaves(for: $0) } ?? [])
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
        if now.timeIntervalSince(lastResumeSave) >= 5 {
            lastResumeSave = now
            library.setResume(model.timeMs, for: streamKey)
        }
        if now.timeIntervalSince(lastContinueSave) >= 60 {
            lastContinueSave = now
            saveProgress(final: false)
        }
    }

    private func saveProgress(final: Bool) {
        guard !request.isLive, model.started, !streamKey.isEmpty else { return }
        let time = model.timeMs
        let length = model.lengthMs
        let fraction = length > 0 ? Double(time) / Double(length) : 0
        let finished = model.ended || fraction > 0.95
        library.setResume(finished ? 0 : time, for: streamKey)

        if let key = request.itemKey {
            let isSeries = request.item?.kind == .series || files.count > 1
            let title = request.item?.title ?? request.title
            if finished && !isSeries {
                library.removeContinue(key)
                if let item = request.item { library.markWatched(item) }
            } else if finished, let next = nextFile {
                let numbers = isSeries ? EpisodeMatcher.numbers(of: next) : nil
                library.updateContinue(ContinueEntry(itemKey: key, item: request.item, title: title,
                                                     subtitle: "Далее: " + fileLabel(next), link: link,
                                                     fileId: next.id, position: 0, updated: Date(),
                                                     season: numbers.flatMap { $0.season ?? wantedSeason },
                                                     episode: numbers?.episode, time: 0))
            } else {
                var subtitle: String?
                if let file = currentFile, files.count > 1 {
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
        saveProgress(final: true)
        if request.isLive { return }
        if autoNext, let next = nextFile {
            play(next)
        } else {
            close()
        }
    }

    private func close() {
        guard !closing else { return }
        closing = true
        saveProgress(final: true)
        model.stop()
        coordinator.request = nil
    }

    private func finish() {
        resolveTask?.cancel()
        switchTask?.cancel()
        if !closing {
            closing = true
            saveProgress(final: true)
            model.stop()
        }
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
        if showControls {
            hideToken += 1
            withAnimation(.easeInOut(duration: 0.2)) { showControls = false }
        } else {
            bumpControls()
        }
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
                    FileRow(file: file, title: fileLabel(file), selected: false)
                }
                .listRowBackground(Theme.card)
            }
            .scrollContentBackground(.hidden)
        }
        .foregroundStyle(.white)
    }

    private var playerView: some View {
        ZStack {
            VLCVideoView(model: model)
                .ignoresSafeArea()
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { toggleControls() }
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
            if showControls && !model.failed {
                controls
                    .transition(.opacity)
            }
            if let release = switching {
                VStack {
                    switchBanner(release)
                    Spacer()
                }
                .padding(.top, showControls ? 64 : 16)
                .padding(.horizontal, 20)
                .transition(.opacity)
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

    private var displayedTime: Int32 {
        scrubbing ? Int32(scrubValue * Double(model.lengthMs)) : model.timeMs
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
                    Text(TimeFormat.string(ms: model.lengthMs))
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
                    FileRow(file: file, title: fileLabel(file), selected: file == currentFile)
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
                            model.setAudio(track.id)
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
                                model.setSubtitle(track.id)
                            }
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
            .navigationTitle("Качество и озвучка")
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
            alternatives = result.releases
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
        let title = request.item?.title ?? request.title
        let poster = request.item?.posterURL
        let isEpisode = request.item?.kind == .series || files.count > 1
        let target: (season: Int?, episode: Int)?
        if let parsed = currentFile.flatMap({ EpisodeMatcher.numbers(of: $0) }) {
            target = parsed
        } else if let episode = wantedEpisode {
            target = (season: wantedSeason, episode: episode)
        } else {
            target = nil
        }
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "play.circle.fill" : "film")
                .foregroundStyle(selected ? Theme.accent : Theme.secondary)
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
