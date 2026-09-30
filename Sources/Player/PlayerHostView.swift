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
        .task { await resolve() }
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
    }

    // MARK: - Resolving the link

    private func resolve() async {
        let link = request.link.trimmed
        switch LinkInspector.kind(of: link) {
        case .direct:
            guard let url = URL(string: link) else {
                phase = .failed("Некорректная ссылка.")
                return
            }
            streamKey = link
            start(url: url, slaves: [])
        case .torrent:
            await resolveTorrent(LinkInspector.stripMarker(link))
        }
    }

    private func resolveTorrent(_ link: String) async {
        phase = .resolving
        do {
            statusText = "Запуск торрент-движка…"
            detailText = ""
            try await TorrServer.shared.ensureRunning()
            statusText = "Получение данных торрента…"
            let status = try await TorrServer.shared.add(link: link, title: request.item?.title ?? request.title, poster: request.item?.posterURL)
            guard let h = status.hash, !h.isEmpty else {
                throw TorrServerError.server("не удалось добавить торрент")
            }
            hash = h
            // The previous torrent stays connected after its player closes; free it for the new one.
            if let previous = coordinator.lastTorrentHash, previous.lowercased() != h.lowercased() {
                Task { await TorrServer.shared.drop(hash: previous) }
            }
            coordinator.lastTorrentHash = h
            let all = try await TorrServer.shared.waitForFiles(hash: h) { s in
                statusText = "Подключение к пирам…"
                detailText = s.peersText
            }
            allFiles = all
            let videos = EpisodeMatcher.sorted(all.filter { $0.isVideo })
            let main = videos.filter { !($0.name.lowercased().contains("sample") && $0.length < 300_000_000) }
            let list = main.isEmpty ? videos : main
            guard !list.isEmpty else { throw TorrServerError.noVideo }
            files = list

            if let id = request.preferredFileId, let file = list.first(where: { $0.id == id }) {
                play(file)
            } else if let episode = request.episode, let file = EpisodeMatcher.find(in: list, season: request.season, episode: episode) {
                play(file)
            } else if list.count == 1 {
                play(list[0])
            } else if request.episode == nil, request.item?.kind != .series, let largest = dominantFile(list) {
                play(largest)
            } else {
                chooserNote = request.episode != nil ? "Не удалось найти серию автоматически — выберите файл." : nil
                phase = .choosing
            }
        } catch {
            if Task.isCancelled || closing { return }
            phase = .failed(error.localizedDescription)
        }
    }

    /// For movies: the file that takes most of the torrent (main feature vs extras).
    private func dominantFile(_ list: [TorrentFile]) -> TorrentFile? {
        let total = list.reduce(Int64(0)) { $0 + $1.length }
        guard total > 0, let largest = list.max(by: { $0.length < $1.length }) else { return nil }
        return Double(largest.length) >= Double(total) * 0.7 ? largest : nil
    }

    private func play(_ file: TorrentFile) {
        guard let h = hash, let url = TorrServer.shared.streamURL(hash: h, file: file) else { return }
        currentFile = file
        streamKey = "\(h):\(file.id)"
        addedAudio = []
        start(url: url, slaves: subtitleSlaves(for: file))
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

    private func start(url: URL, slaves: [(URL, VLCMediaPlaybackSlaveType)]) {
        streamURL = url
        phase = .playing
        let resume: Int32 = request.isLive ? 0 : library.resumePosition(for: streamKey)
        var options: [String: Any] = [:]
        if let agent = request.userAgent { options["http-user-agent"] = agent }
        if let referrer = request.referrer { options["http-referrer"] = referrer }
        if request.isLive { options["network-caching"] = 1500 }
        let rate: Float = (savePlayerSettings && !request.isLive) ? Float(savedRate) : 1
        let aspect: AspectMode = savePlayerSettings ? (AspectMode(rawValue: savedAspect) ?? .fit) : .fit
        model.load(url: url, startAt: resume > 10_000 ? resume - 3_000 : 0, options: options, rate: rate, aspect: aspect, slaves: slaves)
        model.enableRemoteControls(title: request.item?.title ?? request.title,
                                   subtitle: currentFile.flatMap { files.count > 1 ? fileLabel($0) : nil },
                                   isLive: request.isLive)
        lastResumeSave = Date()
        lastContinueSave = Date.distantPast
        bumpControls()
    }

    private func retryPlayback() {
        guard let url = streamURL else {
            Task { await resolve() }
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
                library.updateContinue(ContinueEntry(itemKey: key, item: request.item, title: title,
                                                     subtitle: "Далее: " + fileLabel(next), link: request.link,
                                                     fileId: next.id, position: 0, updated: Date()))
            } else {
                var subtitle: String?
                if let file = currentFile, files.count > 1 {
                    subtitle = fileLabel(file)
                } else if fraction > 0 {
                    subtitle = "Просмотрено \(Int(fraction * 100))%"
                }
                library.updateContinue(ContinueEntry(itemKey: key, item: request.item, title: title,
                                                     subtitle: subtitle, link: request.link,
                                                     fileId: currentFile?.id, position: fraction, updated: Date()))
            }
        }
        if final { library.persist() }
    }

    private func handleEnded() {
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
            Button("Отмена") { close() }
                .buttonStyle(.bordered)
                .tint(.white)
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
                Button("Повторить") { Task { await resolve() } }
                    .buttonStyle(.borderedProminent)
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
                Color.clear.frame(width: 24, height: 24)
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
        }
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
