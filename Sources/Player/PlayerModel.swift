import SwiftUI
import UIKit
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

@MainActor
final class VLCPlayerModel: ObservableObject {
    let player = VLCMediaPlayer()
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

    private var timer: Timer?
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
        player.drawable = videoView
        videoView.onResize = { [weak self] _ in
            self?.applyAspect()
        }
    }

    var progress: Double {
        guard lengthMs > 0 else { return 0 }
        return min(1, max(0, Double(timeMs) / Double(lengthMs)))
    }

    var isSeekable: Bool { player.isSeekable }

    func load(url: URL, startAt: Int32, options: [String: Any], rate: Float, aspect: AspectMode, slaves: [(URL, VLCMediaPlaybackSlaveType)] = []) {
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
        timeMs = startAt
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

        player.media = media
        player.play()
        startTimer()
        updateNowPlaying()
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        tickCount += 1
        let state = player.state
        let t = player.time.intValue
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
        for (url, type) in pendingSlaves {
            _ = player.addPlaybackSlave(url, type: type, enforce: false)
        }
        pendingSlaves = []
        if abs(rate - 1) > 0.01 {
            player.rate = rate
        }
        appliedAspectKey = ""
        applyAspect()
        refreshTracks()
        // The next episode started while the app is in the background: sound only.
        if videoOff { hideVideo() }
    }

    func refreshTracks() {
        let audioNames = player.audioTrackNames.compactMap { $0 as? String }
        let audioIds = player.audioTrackIndexes.compactMap { ($0 as? NSNumber)?.int32Value }
        let audio = zip(audioIds, audioNames)
            .filter { $0.0 >= 0 }
            .map { MediaTrack(id: $0.0, name: $0.1) }
        if audio != audioTracks { audioTracks = audio }
        let audioIndex = player.currentAudioTrackIndex
        if audioIndex != currentAudio { currentAudio = audioIndex }

        let subNames = player.videoSubTitlesNames.compactMap { $0 as? String }
        let subIds = player.videoSubTitlesIndexes.compactMap { ($0 as? NSNumber)?.int32Value }
        var subs = zip(subIds, subNames)
            .filter { $0.0 >= 0 }
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
        _ = player.addPlaybackSlave(url, type: .audio, enforce: true)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.refreshTracks()
        }
    }

    func togglePlay() {
        if player.isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func pause() {
        guard player.isPlaying else { return }
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func resume() {
        guard !player.isPlaying else { return }
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
        guard player.isSeekable else { return }
        let target = max(0, timeMs + seconds * 1000)
        if lengthMs > 0 && target >= lengthMs - 1000 { return }
        player.time = VLCTime(int: target)
        timeMs = target
        stallTicks = 0
        updateNowPlaying()
    }

    func seek(fraction: Double) {
        guard lengthMs > 0 else { return }
        seek(ms: Int32(Double(lengthMs) * min(max(fraction, 0), 0.995)))
    }

    func seek(ms: Int32) {
        guard player.isSeekable else { return }
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
        if enabled {
            guard let saved = hiddenVideoTrack else { return }
            hiddenVideoTrack = nil
            let available = player.videoTrackIndexes.compactMap { ($0 as? NSNumber)?.int32Value }.filter { $0 >= 0 }
            if available.contains(saved) {
                player.currentVideoTrackIndex = saved
            } else if let first = available.first {
                player.currentVideoTrackIndex = first
            }
        } else if player.isPlaying {
            hideVideo()
        }
    }

    private func hideVideo() {
        guard hiddenVideoTrack == nil else { return }
        let current = player.currentVideoTrackIndex
        guard current >= 0 else { return }
        hiddenVideoTrack = current
        player.currentVideoTrackIndex = -1
    }

    // MARK: Lock screen and Control Center

    func enableRemoteControls(title: String, subtitle: String?, isLive: Bool) {
        nowPlayingTitle = title
        nowPlayingSubtitle = subtitle
        isLiveStream = isLive
        if !remoteControlsEnabled {
            remoteControlsEnabled = true
            UIApplication.shared.beginReceivingRemoteControlEvents()
            let center = MPRemoteCommandCenter.shared()
            center.togglePlayPauseCommand.addTarget { [weak self] _ in
                MainActor.assumeIsolated { self?.togglePlay() }
                return .success
            }
            center.playCommand.addTarget { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
                return .success
            }
            center.pauseCommand.addTarget { [weak self] _ in
                MainActor.assumeIsolated { self?.pause() }
                return .success
            }
            center.skipForwardCommand.preferredIntervals = [10]
            center.skipForwardCommand.addTarget { [weak self] _ in
                MainActor.assumeIsolated { self?.jump(10) }
                return .success
            }
            center.skipBackwardCommand.preferredIntervals = [10]
            center.skipBackwardCommand.addTarget { [weak self] _ in
                MainActor.assumeIsolated { self?.jump(-10) }
                return .success
            }
            center.changePlaybackPositionCommand.addTarget { [weak self] event in
                guard let position = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
                let ms = Int32(max(0, min(position.positionTime * 1000, Double(Int32.max))))
                MainActor.assumeIsolated { self?.seek(ms: ms) }
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
        rate = value
        player.rate = value
        updateNowPlaying()
    }

    func setAspect(_ mode: AspectMode) {
        aspect = mode
        applyAspect()
    }

    func setAudio(_ id: Int32) {
        player.currentAudioTrackIndex = id
        currentAudio = id
    }

    func setSubtitle(_ id: Int32) {
        player.currentVideoSubTitleIndex = id
        currentSubtitle = id
    }

    private func setAspectRatio(_ value: String?) {
        if let value = value {
            value.withCString { pointer in
                player.videoAspectRatio = UnsafeMutablePointer(mutating: pointer)
            }
        } else {
            player.videoAspectRatio = nil
        }
    }

    private func setCrop(_ value: String?) {
        if let value = value {
            value.withCString { pointer in
                player.videoCropGeometry = UnsafeMutablePointer(mutating: pointer)
            }
        } else {
            player.videoCropGeometry = nil
        }
    }

    func applyAspect() {
        let size = videoView.bounds.size
        guard size.width > 1, size.height > 1 else { return }
        let screen = "\(Int(size.width.rounded())):\(Int(size.height.rounded()))"
        let key = "\(aspect.rawValue)-\(screen)"
        guard key != appliedAspectKey else { return }
        appliedAspectKey = key
        switch aspect {
        case .fit:
            setCrop(nil)
            setAspectRatio(nil)
        case .fill:
            setAspectRatio(nil)
            setCrop(screen)
        case .stretch:
            setCrop(nil)
            setAspectRatio(screen)
        case .ratio16x9:
            setCrop(nil)
            setAspectRatio("16:9")
        case .ratio4x3:
            setCrop(nil)
            setAspectRatio("4:3")
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        disableRemoteControls()
        let p = player
        DispatchQueue.global(qos: .userInitiated).async {
            p.stop()
        }
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
