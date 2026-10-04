import SwiftUI
import UIKit
import AVFoundation
import MediaPlayer
import VLCKitSPM

enum AspectMode: String, CaseIterable, Identifiable {
    case fit
    case fill
    case stretch
    case ratio16x9
    case ratio4x3

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit: return "100% размер"
        case .fill: return "По сторонам (обрезать)"
        case .stretch: return "Растянуть на экран"
        case .ratio16x9: return "16:9"
        case .ratio4x3: return "4:3"
        }
    }
}

struct MediaTrack: Identifiable, Hashable {
    let id: Int32
    let name: String
}

struct RateOption: Identifiable {
    let value: Float
    let title: String
    var id: Float { value }
}

enum PlaybackRates {
    static let all: [RateOption] = [
        RateOption(value: 0.5, title: "0.5× — замедленная"),
        RateOption(value: 0.75, title: "0.75×"),
        RateOption(value: 1.0, title: "Обычная"),
        RateOption(value: 1.25, title: "1.25×"),
        RateOption(value: 1.5, title: "1.5× — ускоренная"),
        RateOption(value: 2.0, title: "2×")
    ]
}

/// Uses the system volume slider, so the gesture changes the same level as the
/// physical volume buttons and other media apps.
@MainActor
final class SystemVolumeController {
    static let shared = SystemVolumeController()

    private let volumeView = MPVolumeView(frame: .zero)

    private init() {
        volumeView.showsRouteButton = false
        volumeView.showsVolumeSlider = true
        volumeView.layoutIfNeeded()
    }

    private var slider: UISlider? {
        volumeView.subviews.compactMap { $0 as? UISlider }.first
    }

    var volume: Float {
        AVAudioSession.sharedInstance().outputVolume
    }

    func setVolume(_ value: Float) {
        guard let slider = slider else { return }
        slider.value = min(1, max(0, value))
        slider.sendActions(for: .valueChanged)
    }
}

/// UIView used as VLC drawable; reports size changes so the aspect mode can be re-applied.
final class VideoSurfaceView: UIView {
    var onResize: ((CGSize) -> Void)?
    private var lastSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastSize {
            lastSize = bounds.size
            onResize?(bounds.size)
        }
    }
}

/// Holds a stopped VLC player until libvlc has finished closing its stream, then
/// releases it on a background queue.
///
/// The iOS video output of libvlc creates and removes its view with
/// `performSelectorOnMainThread:…waitUntilDone:YES`, and releasing a player waits
/// for libvlc's worker thread that closes the stream. Releasing a player on the
/// main thread while its stream is still closing can therefore freeze the app
/// until iOS terminates it. The video view is released on the main thread afterwards.
enum VLCPlayerGraveyard {
    private final class Remains: @unchecked Sendable {
        var player: VLCMediaPlayer?
        var view: UIView?

        init(player: VLCMediaPlayer, view: UIView) {
            self.player = player
            self.view = view
        }
    }

    private static let queue = DispatchQueue(label: "kinoteka.vlc.release", qos: .utility)

    /// Call on the main thread.
    static func bury(_ player: VLCMediaPlayer, view: UIView) {
        if player.state != .stopped {
            player.stop()
        }
        VLCPlayerGraveyard.waitForStop(Remains(player: player, view: view), checks: 0)
    }

    private static func waitForStop(_ remains: Remains, checks: Int) {
        let stopped = remains.player?.state == .stopped
        if !stopped && checks < 40 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                VLCPlayerGraveyard.waitForStop(remains, checks: checks + 1)
            }
            return
        }
        if !stopped {
            AppDiagnostics.shared.log("player", "VLC не остановился за 10 с, освобождается принудительно")
        }
        // The callbacks VLCKit has already queued on the main thread run first.
        VLCPlayerGraveyard.queue.asyncAfter(deadline: .now() + 1) {
            remains.player = nil
            DispatchQueue.main.async {
                remains.view = nil
            }
        }
    }
}

/// Lets the non-isolated `deinit` of the model reach its player.
private final class VLCPlayerSlot: @unchecked Sendable {
    var player: VLCMediaPlayer?
    var view: UIView?
}

@MainActor
final class VLCPlayerModel: ObservableObject {
    /// libvlc calls that may wait for the video output (aspect ratio, crop) run on
    /// this queue: while the video output is being created it waits for the main thread.
    private static let controlQueue = DispatchQueue(label: "kinoteka.vlc.control", qos: .userInitiated)

    private let slot = VLCPlayerSlot()
    let videoView = VideoSurfaceView()

    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = true
    @Published private(set) var timeMs: Int32 = 0
    @Published private(set) var lengthMs: Int32 = 0
    @Published private(set) var ended = false
    @Published private(set) var failed = false
    @Published private(set) var started = false
    @Published private(set) var audioTracks: [MediaTrack] = []
    @Published private(set) var subtitleTracks: [MediaTrack] = []
    @Published private(set) var currentAudio: Int32 = -1
    @Published private(set) var currentSubtitle: Int32 = -1
    @Published private(set) var rate: Float = 1
    @Published private(set) var aspect: AspectMode = .fit
    /// Shift of the sound and of the subtitles against the picture (ms, "+" = later).
    @Published private(set) var audioDelayMs = 0
    @Published private(set) var subtitleDelayMs = 0

    private var timer: Timer?
    private var aspectTask: Task<Void, Never>?
    private var lastTime: Int32 = -1
    private var stallTicks = 0
    private var tickCount = 0
    private var appliedAspectKey = ""
    private var pendingSlaves: [(URL, VLCMediaPlaybackSlaveType)] = []
    private var hiddenVideoTrack: Int32?
    private var videoOff = false
    private var remoteControlsEnabled = false
    private var nowPlayingTitle = ""
    private var nowPlayingSubtitle: String?
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var isLiveStream = false

    init() {
        videoView.backgroundColor = .black
        videoView.isUserInteractionEnabled = false
        let player = VLCMediaPlayer()
        player.drawable = videoView
        slot.player = player
        slot.view = videoView
        videoView.onResize = { [weak self] _ in
            self?.scheduleAspectUpdate()
        }
    }

    deinit {
        // Normally `shutdown()` has already handed the player over.
        if let player = slot.player, let view = slot.view {
            slot.player = nil
            VLCPlayerGraveyard.bury(player, view: view)
        }
    }

    /// nil after `shutdown()`: every call below is then ignored.
    private var player: VLCMediaPlayer? { slot.player }

    var progress: Double {
        guard lengthMs > 0 else { return 0 }
        let value = Double(timeMs) / Double(lengthMs)
        return value.isFinite ? min(1, max(0, value)) : 0
    }

    var isSeekable: Bool { player?.isSeekable ?? false }

    func load(url: URL, startAt: Int32, options: [String: Any], rate: Float, aspect: AspectMode, slaves: [(URL, VLCMediaPlaybackSlaveType)] = []) {
        guard let player = player else { return }
        let media: VLCMedia = VLCMedia(url: url)
        var all: [String: Any] = ["network-caching": 3000]
        if startAt > 0 {
            all["start-time"] = Double(startAt) / 1000.0
        }
        for (key, value) in options {
            all[key] = value
        }
        media.addOptions(all)

        started = false
        ended = false
        failed = false
        isBuffering = true
        timeMs = max(0, startAt)
        lengthMs = 0
        lastTime = -1
        stallTicks = 0
        tickCount = 0
        audioTracks = []
        subtitleTracks = []
        self.rate = rate
        self.aspect = aspect
        appliedAspectKey = ""
        pendingSlaves = slaves
        hiddenVideoTrack = nil

        // VLCKit ignores a new media with the same URL as the current one, together
        // with its options (start position): the old one is detached first.
        if let current = player.media, current.url == url {
            player.media = nil
        }
        player.media = media
        player.play()
        applyAspect()
        startTimer()
        updateNowPlaying()
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated {
                self.tick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard let player = player else { return }
        tickCount += 1
        let state = player.state
        let t = max(0, player.time.intValue)
        let length = player.media?.length.intValue ?? 0
        if length > 0 && length != lengthMs { lengthMs = length }
        if t > 0 && t != timeMs { timeMs = t }
        let playing = player.isPlaying
        if playing != isPlaying {
            isPlaying = playing
            updateNowPlaying()
        } else if tickCount % 4 == 0 {
            updateNowPlaying()
        }

        if !started && t > 0 {
            started = true
            onStarted()
        }

        switch state {
        case .ended:
            if !ended { ended = true }
        case .error:
            if !failed { failed = true }
        default:
            break
        }

        var buffering: Bool
        if state == .opening {
            buffering = true
        } else if playing {
            stallTicks = (t == lastTime) ? stallTicks + 1 : 0
            buffering = !started || stallTicks >= 3
        } else {
            buffering = !started && state != .paused && state != .ended && state != .error
        }
        if ended || failed { buffering = false }
        if buffering != isBuffering { isBuffering = buffering }
        lastTime = t

        if started && (tickCount % 4 == 0) && tickCount < 240 {
            refreshTracks()
        }
    }

    private func onStarted() {
        guard let player = player else { return }
        for (url, type) in pendingSlaves {
            _ = player.addPlaybackSlave(url, type: type, enforce: false)
        }
        pendingSlaves = []
        if abs(rate - 1) > 0.01 {
            player.rate = rate
        }
        applyAspect(force: true)
        // A new stream starts without the shift: the one chosen for the release stays.
        if audioDelayMs != 0 || subtitleDelayMs != 0 { applyDelays() }
        refreshTracks()
        // The next episode started while the app is in the background: sound only.
        if videoOff { hideVideo() }
    }

    func refreshTracks() {
        guard let player = player else { return }
        let audioNames = player.audioTrackNames.compactMap { $0 as? String }
        let audioIds = player.audioTrackIndexes.compactMap { ($0 as? NSNumber)?.int32Value }
        var seenAudio = Set<Int32>()
        let audio = zip(audioIds, audioNames)
            .filter { $0.0 >= 0 && seenAudio.insert($0.0).inserted }
            .map { MediaTrack(id: $0.0, name: $0.1) }
        if audio != audioTracks { audioTracks = audio }
        let audioIndex = player.currentAudioTrackIndex
        if audioIndex != currentAudio { currentAudio = audioIndex }

        let subNames = player.videoSubTitlesNames.compactMap { $0 as? String }
        let subIds = player.videoSubTitlesIndexes.compactMap { ($0 as? NSNumber)?.int32Value }
        var seenSubs = Set<Int32>()
        var subs = zip(subIds, subNames)
            .filter { $0.0 >= 0 && seenSubs.insert($0.0).inserted }
            .map { MediaTrack(id: $0.0, name: $0.1) }
        if !subs.isEmpty {
            subs.insert(MediaTrack(id: -1, name: "Выключены"), at: 0)
        }
        if subs != subtitleTracks { subtitleTracks = subs }
        let subIndex = player.currentVideoSubTitleIndex
        if subIndex != currentSubtitle { currentSubtitle = subIndex }
    }

    /// Connects an external audio file (separate dub) to the current stream.
    func addAudioSlave(_ url: URL) {
        guard let player = player else { return }
        _ = player.addPlaybackSlave(url, type: .audio, enforce: true)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.refreshTracks()
        }
    }

    func togglePlay() {
        guard let player = player else { return }
        if player.isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func pause() {
        guard let player = player, player.isPlaying else { return }
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func resume() {
        guard let player = player, !player.isPlaying else { return }
        if ended {
            ended = false
        }
        player.play()
        isPlaying = true
        // Resumed from the lock screen while the app is in the background: sound only.
        if videoOff { hideVideo() }
        updateNowPlaying()
    }

    func jump(_ seconds: Int32) {
        guard let player = player, player.isSeekable else { return }
        let target = max(0, Int64(timeMs) + Int64(seconds) * 1000)
        if lengthMs > 0 && target >= Int64(lengthMs) - 1000 { return }
        let clamped = Int32(min(target, Int64(Int32.max)))
        player.time = VLCTime(int: clamped)
        timeMs = clamped
        stallTicks = 0
        updateNowPlaying()
    }

    func seek(fraction: Double) {
        guard lengthMs > 0, fraction.isFinite else { return }
        seek(ms: Int32(Double(lengthMs) * min(max(fraction, 0), 0.995)))
    }

    func seek(ms: Int32) {
        guard let player = player, player.isSeekable else { return }
        var target = max(0, ms)
        if lengthMs > 0 { target = min(target, Int32(Double(lengthMs) * 0.995)) }
        player.time = VLCTime(int: target)
        timeMs = target
        stallTicks = 0
        updateNowPlaying()
    }

    // MARK: Background playback

    /// Turns the video track off while the app is in the background (only the sound keeps
    /// playing, as in VLC) and back on when the app returns.
    func setVideoEnabled(_ enabled: Bool) {
        videoOff = !enabled
        guard let player = player else { return }
        if enabled {
            guard let saved = hiddenVideoTrack else { return }
            hiddenVideoTrack = nil
            let available = player.videoTrackIndexes.compactMap { ($0 as? NSNumber)?.int32Value }.filter { $0 >= 0 }
            if available.contains(saved) {
                player.currentVideoTrackIndex = saved
            } else if let first = available.first {
                player.currentVideoTrackIndex = first
            }
            AppDiagnostics.shared.log("player", "Картинка включена")
        } else if player.isPlaying {
            hideVideo()
        }
    }

    private func hideVideo() {
        guard let player = player, hiddenVideoTrack == nil else { return }
        let current = player.currentVideoTrackIndex
        guard current >= 0 else { return }
        hiddenVideoTrack = current
        player.currentVideoTrackIndex = -1
        AppDiagnostics.shared.log("player", "Фон: только звук")
    }

    // MARK: Lock screen and Control Center

    func enableRemoteControls(title: String, subtitle: String?, isLive: Bool) {
        guard player != nil else { return }
        nowPlayingTitle = title
        nowPlayingSubtitle = subtitle
        isLiveStream = isLive
        if !remoteControlsEnabled {
            remoteControlsEnabled = true
            UIApplication.shared.beginReceivingRemoteControlEvents()
            let center = MPRemoteCommandCenter.shared()
            center.togglePlayPauseCommand.addTarget { [weak self] _ in
                Task { @MainActor [weak self] in self?.togglePlay() }
                return .success
            }
            center.playCommand.addTarget { [weak self] _ in
                Task { @MainActor [weak self] in self?.resume() }
                return .success
            }
            center.pauseCommand.addTarget { [weak self] _ in
                Task { @MainActor [weak self] in self?.pause() }
                return .success
            }
            center.skipForwardCommand.preferredIntervals = [10]
            center.skipForwardCommand.addTarget { [weak self] _ in
                Task { @MainActor [weak self] in self?.jump(10) }
                return .success
            }
            center.skipBackwardCommand.preferredIntervals = [10]
            center.skipBackwardCommand.addTarget { [weak self] _ in
                Task { @MainActor [weak self] in self?.jump(-10) }
                return .success
            }
            center.changePlaybackPositionCommand.addTarget { [weak self] event in
                guard let position = event as? MPChangePlaybackPositionCommandEvent,
                      position.positionTime.isFinite else { return .commandFailed }
                let ms = Int32(max(0, min(position.positionTime * 1000, Double(Int32.max))))
                Task { @MainActor [weak self] in self?.seek(ms: ms) }
                return .success
            }
        }
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.isEnabled = !isLive
        center.skipBackwardCommand.isEnabled = !isLive
        center.changePlaybackPositionCommand.isEnabled = !isLive
        updateNowPlaying()
    }

    func setNowPlayingArtwork(_ image: UIImage) {
        nowPlayingArtwork = VLCPlayerModel.artwork(image)
        updateNowPlaying()
    }

    private nonisolated static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    func disableRemoteControls() {
        guard remoteControlsEnabled else { return }
        remoteControlsEnabled = false
        let center = MPRemoteCommandCenter.shared()
        let commands: [MPRemoteCommand] = [center.togglePlayPauseCommand, center.playCommand, center.pauseCommand,
                                           center.skipForwardCommand, center.skipBackwardCommand,
                                           center.changePlaybackPositionCommand]
        for command in commands {
            command.removeTarget(nil)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        UIApplication.shared.endReceivingRemoteControlEvents()
    }

    private func updateNowPlaying() {
        guard remoteControlsEnabled else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlayingTitle,
            MPNowPlayingInfoPropertyIsLiveStream: isLiveStream,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if let subtitle = nowPlayingSubtitle {
            info[MPMediaItemPropertyArtist] = subtitle
        }
        if let artwork = nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        if !isLiveStream && lengthMs > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = Double(lengthMs) / 1000
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(timeMs) / 1000
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func setRate(_ value: Float) {
        guard let player = player, value.isFinite, value > 0 else { return }
        rate = value
        player.rate = value
        updateNowPlaying()
    }

    func setAspect(_ mode: AspectMode) {
        aspect = mode
        applyAspect()
    }

    func setAudio(_ id: Int32) {
        guard let player = player else { return }
        player.currentAudioTrackIndex = id
        currentAudio = id
    }

    func setSubtitle(_ id: Int32) {
        guard let player = player else { return }
        player.currentVideoSubTitleIndex = id
        currentSubtitle = id
    }

    /// Out-of-sync dubs (often a separate audio file of the release) and subtitles.
    func setAudioDelay(ms: Int) {
        audioDelayMs = min(max(ms, -10_000), 10_000)
        applyDelays()
    }

    func setSubtitleDelay(ms: Int) {
        subtitleDelayMs = min(max(ms, -60_000), 60_000)
        applyDelays()
    }

    /// VLC takes the shifts in microseconds.
    private func applyDelays() {
        guard let player = player else { return }
        let audio = audioDelayMs * 1_000
        let subtitle = subtitleDelayMs * 1_000
        VLCPlayerModel.controlQueue.async {
            player.currentAudioPlaybackDelay = audio
            player.currentVideoSubTitleDelay = subtitle
        }
    }

    /// Rotation produces several sizes in a row: only the last one is applied.
    private func scheduleAspectUpdate() {
        aspectTask?.cancel()
        aspectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.applyAspect()
        }
    }

    func applyAspect(force: Bool = false) {
        guard let player = player else { return }
        let size = videoView.bounds.size
        guard size.width > 1, size.height > 1, size.width.isFinite, size.height.isFinite else { return }
        let screen = "\(Int(size.width.rounded())):\(Int(size.height.rounded()))"
        var ratio: String?
        var crop: String?
        switch aspect {
        case .fit:
            break
        case .fill:
            crop = screen
        case .stretch:
            ratio = screen
        case .ratio16x9:
            ratio = "16:9"
        case .ratio4x3:
            ratio = "4:3"
        }
        let key = "\(ratio ?? "-")|\(crop ?? "-")"
        guard force || key != appliedAspectKey else { return }
        appliedAspectKey = key
        VLCPlayerModel.controlQueue.async {
            VLCPlayerModel.applyGeometry(to: player, ratio: ratio, crop: crop)
        }
    }

    private nonisolated static func applyGeometry(to player: VLCMediaPlayer, ratio: String?, crop: String?) {
        if let crop = crop {
            crop.withCString { pointer in
                player.videoCropGeometry = UnsafeMutablePointer(mutating: pointer)
            }
        } else {
            player.videoCropGeometry = nil
        }
        if let ratio = ratio {
            ratio.withCString { pointer in
                player.videoAspectRatio = UnsafeMutablePointer(mutating: pointer)
            }
        } else {
            player.videoAspectRatio = nil
        }
    }

    /// Stops the stream; the player can load another one afterwards (recovery, next file).
    func stop() {
        timer?.invalidate()
        timer = nil
        disableRemoteControls()
        player?.stop()
    }

    /// Final stop when the player screen closes. Safe to call more than once.
    func shutdown() {
        timer?.invalidate()
        timer = nil
        aspectTask?.cancel()
        aspectTask = nil
        disableRemoteControls()
        guard let player = slot.player else { return }
        slot.player = nil
        isPlaying = false
        AppDiagnostics.shared.log("player", "Плеер закрыт")
        VLCPlayerGraveyard.bury(player, view: videoView)
    }
}

struct VLCVideoView: UIViewRepresentable {
    let model: VLCPlayerModel

    func makeUIView(context: Context) -> VideoSurfaceView {
        model.videoView
    }

    func updateUIView(_ uiView: VideoSurfaceView, context: Context) {}
}

@MainActor
enum OrientationHelper {
    private static var scene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    static func set(landscape: Bool) {
        guard let scene = scene else { return }
        let mask: UIInterfaceOrientationMask = landscape ? .landscapeRight : .portrait
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }

    static func toggle() {
        guard let scene = scene else { return }
        set(landscape: !scene.interfaceOrientation.isLandscape)
    }
}
