import SwiftUI
import UIKit
import AVFoundation
import MediaPlayer
import AVKit
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
    /// The sample buffer view stays above a view VLC may still add for its own output.
    weak var frontView: UIView?
    private var lastSize: CGSize = .zero

    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        if let front = frontView, subview !== front {
            bringSubviewToFront(front)
        }
    }

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

    /// VLC draws into its own view, or hands the frames to a sample buffer layer, which
    /// Picture in Picture can show.
    enum RenderMode {
        case native
        case sampleBuffer
    }

    private struct TrackRestore {
        let audio: MediaTrack?
        let subtitle: MediaTrack?
        let deadline: Date
    }

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
    @Published private(set) var renderMode: RenderMode = .native
    @Published private(set) var pipActive = false
    @Published private(set) var pipPossible = false
    @Published private(set) var preparingPiP = false
    /// Counters the player screen reacts to: Picture in Picture started, asked to bring the
    /// player back (its button), or was closed (its cross).
    @Published private(set) var pipStarts = 0
    @Published private(set) var pipRestoreRequests = 0
    @Published private(set) var pipClosedRequests = 0
    @Published private(set) var pipMessage: String?
    /// Picture in Picture was started by iOS when the app went to the background.
    private(set) var pipStartedAutomatically = false
    /// Open the streams with frames for Picture in Picture from the start (a setting).
    var prefersSampleBuffer = false
    /// iOS starts Picture in Picture itself when the app is closed during playback.
    var automaticPictureInPicture = false {
        didSet { pipController?.canStartPictureInPictureAutomaticallyFromInline = automaticPictureInPicture }
    }

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
    private var sink: SampleBufferSink?
    private var sampleView: SampleBufferVideoView?
    private var pipController: AVPictureInPictureController?
    private var pipBridge: PictureInPictureBridge?
    private var pipPossibleObservation: NSKeyValueObservation?
    private var pipStartTask: Task<Void, Never>?
    private var frameCheckTask: Task<Void, Never>?
    private var pipRestoring = false
    private var lastURL: URL?
    private var lastOptions: [String: Any] = [:]
    private var loadedSlaves: [(URL, VLCMediaPlaybackSlaveType)] = []
    /// Dubs and subtitles connected later: a reopened stream gets them again.
    private var extraSlaves: [(URL, VLCMediaPlaybackSlaveType)] = []
    private var trackRestore: TrackRestore?

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

    var pipSupported: Bool { PictureInPictureSupport.isAvailable }

    func load(url: URL, startAt: Int32, options: [String: Any], rate: Float, aspect: AspectMode, slaves: [(URL, VLCMediaPlaybackSlaveType)] = []) {
        if prefersSampleBuffer, renderMode == .native, PictureInPictureSupport.isAvailable {
            _ = installSampleBufferPlayer(hint: .zero, pixelAspect: nil)
        }
        trackRestore = nil
        extraSlaves = []
        loadMedia(url: url, startAt: startAt, options: options, rate: rate, aspect: aspect, slaves: slaves)
    }

    private func loadMedia(url: URL, startAt: Int32, options: [String: Any], rate: Float, aspect: AspectMode,
                           slaves: [(URL, VLCMediaPlaybackSlaveType)]) {
        guard let player = player else { return }
        lastURL = url
        lastOptions = options
        loadedSlaves = slaves
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
        syncPictureInPicture()
        if trackRestore != nil && started { applyTrackRestore() }

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
        applyTrackRestore()
        // The next episode started while the app is in the background: sound only.
        if videoOff { hideVideo() }
        if renderMode == .sampleBuffer { checkFramesArrive() }
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
        extraSlaves.append((url, .audio))
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.refreshTracks()
        }
    }

    /// Connects a subtitle file (found on OpenSubtitles); `select` turns it on.
    func addSubtitleSlave(_ url: URL, select: Bool) {
        guard let player = player else { return }
        let before = Set(subtitleTracks.map(\.id))
        _ = player.addPlaybackSlave(url, type: .subtitle, enforce: select)
        extraSlaves.append((url, .subtitle))
        Task { @MainActor [weak self] in
            for _ in 0..<8 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                self.refreshTracks()
                if let added = self.subtitleTracks.last(where: { $0.id >= 0 && !before.contains($0.id) }) {
                    if select && self.currentSubtitle != added.id { self.setSubtitle(added.id) }
                    return
                }
            }
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
        syncPictureInPicture()
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
        syncPictureInPicture()
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
        if renderMode == .sampleBuffer {
            // The frames are shown by the layer: the aspect mode is its geometry.
            sampleView?.aspect = aspect
            return
        }
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
        tearDownPictureInPicture()
        guard let player = slot.player else { return }
        slot.player = nil
        isPlaying = false
        AppDiagnostics.shared.log("player", "Плеер закрыт")
        VLCPlayerGraveyard.bury(player, view: videoView)
    }

    // MARK: Picture in Picture

    /// Shows the video in the floating window. VLC's own view cannot be shown there: the first
    /// time the stream is reopened (from the same place) with its frames handed to a layer.
    func enterPictureInPicture() {
        guard PictureInPictureSupport.isAvailable, player != nil else {
            pipMessage = "Картинка в картинке недоступна на этом устройстве"
            return
        }
        if pipActive { return }
        if renderMode == .native {
            guard switchToSampleBuffer() else {
                pipMessage = "Не удалось подготовить картинку в картинке"
                return
            }
        }
        startPictureInPictureWhenPossible()
    }

    func exitPictureInPicture() {
        pipStartTask?.cancel()
        preparingPiP = false
        if pipController?.isPictureInPictureActive == true {
            pipController?.stopPictureInPicture()
        }
    }

    func clearPipMessage() {
        pipMessage = nil
    }

    /// The app is back: frames are shown again (the layer stops while the app is in the background).
    func recoverVideoLayer() {
        sink?.recover()
    }

    private func startPictureInPictureWhenPossible() {
        pipStartTask?.cancel()
        preparingPiP = true
        try? AVAudioSession.sharedInstance().setActive(true)
        pipStartTask = Task { @MainActor [weak self] in
            for _ in 0..<60 {
                guard let self, !Task.isCancelled else { return }
                if self.pipActive {
                    self.preparingPiP = false
                    return
                }
                if let controller = self.pipController, controller.isPictureInPicturePossible,
                   (self.sink?.displayedFrames ?? 0) > 0 {
                    controller.startPictureInPicture()
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    self.preparingPiP = false
                    return
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard let self, !Task.isCancelled else { return }
            self.preparingPiP = false
            self.pipMessage = "Картинка в картинке не запустилась: видео ещё не готово"
            AppDiagnostics.shared.log("pip", "Не стала возможной за 12 с")
        }
    }

    /// Replaces the player by one that hands its frames to a sample buffer layer and opens the
    /// stream again at the same place, with the same dub, subtitles, speed and shifts.
    private func switchToSampleBuffer() -> Bool {
        guard renderMode == .native, let old = slot.player, let url = lastURL else { return false }
        let restartAt: Int32 = isLiveStream ? 0 : max(0, timeMs - 1_500)
        let audio = audioTracks.first { $0.id == currentAudio }
        let subtitle = subtitleTracks.isEmpty ? nil : (subtitleTracks.first { $0.id == currentSubtitle } ?? MediaTrack(id: -1, name: ""))
        let size = old.videoSize
        let aspectOfPixels = VLCPlayerModel.pixelAspect(of: old.media)
        guard installSampleBufferPlayer(hint: size, pixelAspect: aspectOfPixels) else { return false }
        trackRestore = TrackRestore(audio: audio, subtitle: subtitle, deadline: Date().addingTimeInterval(30))
        AppDiagnostics.shared.log("pip", "Поток открыт заново для картинки в картинке с \(restartAt) мс")
        loadMedia(url: url, startAt: restartAt, options: lastOptions, rate: rate, aspect: aspect,
                  slaves: loadedSlaves + extraSlaves)
        return true
    }

    /// The new player gets no view: VLC hands it the frames (vmem), the layer shows them.
    private func installSampleBufferPlayer(hint: CGSize, pixelAspect: (Int, Int)?) -> Bool {
        guard let old = slot.player else { return false }
        let newSink = SampleBufferSink()
        newSink.setHint(size: hint, pixelAspect: pixelAspect)
        let fresh = VLCMediaPlayer()
        guard LibVLCVideo.attach(newSink, to: fresh) else { return false }
        timer?.invalidate()
        timer = nil
        slot.player = fresh
        VLCPlayerGraveyard.bury(old, view: videoView)
        let view = SampleBufferVideoView(sink: newSink)
        view.frame = videoView.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.aspect = aspect
        videoView.addSubview(view)
        videoView.frontView = view
        sampleView = view
        sink = newSink
        renderMode = .sampleBuffer
        appliedAspectKey = ""
        makePictureInPictureController(for: newSink)
        return true
    }

    /// No frame came (the frames cannot be converted on this device or for this video):
    /// back to VLC's own view, at the same place.
    private func switchToNative() {
        guard renderMode == .sampleBuffer, let old = slot.player, let url = lastURL else { return }
        let restartAt: Int32 = isLiveStream ? 0 : max(0, timeMs - 1_000)
        let audio = audioTracks.first { $0.id == currentAudio }
        let subtitle = subtitleTracks.isEmpty ? nil : (subtitleTracks.first { $0.id == currentSubtitle } ?? MediaTrack(id: -1, name: ""))
        tearDownPictureInPicture()
        timer?.invalidate()
        timer = nil
        let fresh = VLCMediaPlayer()
        fresh.drawable = videoView
        slot.player = fresh
        VLCPlayerGraveyard.bury(old, view: videoView)
        sampleView?.removeFromSuperview()
        sampleView = nil
        videoView.frontView = nil
        renderMode = .native
        prefersSampleBuffer = false
        appliedAspectKey = ""
        trackRestore = TrackRestore(audio: audio, subtitle: subtitle, deadline: Date().addingTimeInterval(30))
        loadMedia(url: url, startAt: restartAt, options: lastOptions, rate: rate, aspect: aspect,
                  slaves: loadedSlaves + extraSlaves)
    }

    private func checkFramesArrive() {
        frameCheckTask?.cancel()
        frameCheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, !Task.isCancelled, self.renderMode == .sampleBuffer, !self.videoOff,
                  UIApplication.shared.applicationState == .active,
                  let player = self.player, player.isPlaying,
                  (self.sink?.displayedFrames ?? 0) == 0 else { return }
            let hasVideo = player.videoTrackIndexes.contains { (($0 as? NSNumber)?.int32Value ?? -1) >= 0 }
            guard hasVideo else { return }
            AppDiagnostics.shared.log("pip", "Кадры не пришли за 6 с, обычный вывод видео")
            self.pipMessage = "Картинка в картинке не работает с этим видео"
            self.switchToNative()
        }
    }

    private func makePictureInPictureController(for sink: SampleBufferSink) {
        tearDownPictureInPicture(keepSink: true)
        let bridge = PictureInPictureBridge { [weak self] event in
            self?.handlePictureInPicture(event)
        }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: sink.layer, playbackDelegate: bridge)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = bridge
        controller.canStartPictureInPictureAutomaticallyFromInline = automaticPictureInPicture
        pipBridge = bridge
        pipController = controller
        pipPossibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor [weak self] in
                if self?.pipPossible != possible { self?.pipPossible = possible }
            }
        }
        syncPictureInPicture()
    }

    private func tearDownPictureInPicture(keepSink: Bool = false) {
        pipStartTask?.cancel()
        pipStartTask = nil
        frameCheckTask?.cancel()
        frameCheckTask = nil
        pipPossibleObservation?.invalidate()
        pipPossibleObservation = nil
        if let controller = pipController {
            if controller.isPictureInPictureActive { controller.stopPictureInPicture() }
            controller.delegate = nil
        }
        pipController = nil
        pipBridge = nil
        if pipActive { pipActive = false }
        if preparingPiP { preparingPiP = false }
        pipPossible = false
        guard !keepSink else { return }
        sink?.invalidate()
        sink = nil
    }

    private func handlePictureInPicture(_ event: PictureInPictureBridge.Event) {
        switch event {
        case .willStart:
            pipStartedAutomatically = UIApplication.shared.applicationState != .active
        case .didStart:
            pipActive = true
            preparingPiP = false
            pipStarts += 1
            AppDiagnostics.shared.log("pip", pipStartedAutomatically ? "Картинка в картинке: автоматически" : "Картинка в картинке")
        case .failed(let text):
            pipActive = false
            preparingPiP = false
            pipMessage = "Картинка в картинке не запустилась: \(text)"
            AppDiagnostics.shared.log("pip", "Ошибка запуска: \(text)")
        case .willStop:
            break
        case .didStop:
            pipActive = false
            if pipRestoring {
                pipRestoring = false
            } else {
                pipClosedRequests += 1
            }
            pipStartedAutomatically = false
            sink?.recover()
        case .restore(let completion):
            pipRestoring = true
            pipRestoreRequests += 1
            completion(true)
        case .setPlaying(let playing):
            if playing { resume() } else { pause() }
        case .skip(let seconds):
            jump(Int32(max(-600, min(600, seconds.rounded()))))
        }
    }

    /// The position, the speed and the pause shown by the Picture in Picture window.
    private func syncPictureInPicture() {
        guard let sink else { return }
        sink.updateClock(seconds: Double(timeMs) / 1_000, rate: isPlaying ? Double(rate) : 0)
        guard let bridge = pipBridge else { return }
        let live = isLiveStream || lengthMs <= 0
        if bridge.update(paused: !isPlaying, duration: Double(lengthMs) / 1_000, live: live) {
            pipController?.invalidatePlaybackState()
        }
    }

    /// The dub and the subtitles chosen before the stream was reopened.
    private func applyTrackRestore() {
        guard let restore = trackRestore else { return }
        if Date() > restore.deadline {
            trackRestore = nil
            return
        }
        var done = true
        if let audio = restore.audio {
            if let track = audioTracks.first(where: { $0.id == audio.id && $0.name == audio.name })
                ?? audioTracks.first(where: { $0.name == audio.name }) {
                if currentAudio != track.id { setAudio(track.id) }
            } else {
                done = false
            }
        }
        if let subtitle = restore.subtitle {
            if subtitle.id == -1 {
                if currentSubtitle != -1, !subtitleTracks.isEmpty { setSubtitle(-1) }
                if subtitleTracks.isEmpty { done = false }
            } else if let track = subtitleTracks.first(where: { $0.id == subtitle.id && $0.name == subtitle.name })
                        ?? subtitleTracks.first(where: { $0.name == subtitle.name }) {
                if currentSubtitle != track.id { setSubtitle(track.id) }
            } else {
                done = false
            }
        }
        if done { trackRestore = nil }
    }

    private static func pixelAspect(of media: VLCMedia?) -> (Int, Int)? {
        guard let tracks = media?.tracksInformation as? [[String: Any]] else { return nil }
        for track in tracks where (track[VLCMediaTracksInformationType] as? String) == VLCMediaTracksInformationTypeVideo {
            let numerator = (track[VLCMediaTracksInformationSourceAspectRatio] as? NSNumber)?.intValue ?? 0
            let denominator = (track[VLCMediaTracksInformationSourceAspectRatioDenominator] as? NSNumber)?.intValue ?? 0
            if numerator > 0, denominator > 0 { return (numerator, denominator) }
        }
        return nil
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
    static var scene: UIWindowScene? {
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
