import SwiftUI
import UIKit
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

        player.media = media
        player.play()
        startTimer()
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
        if playing != isPlaying { isPlaying = playing }

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
            player.pause()
            isPlaying = false
        } else {
            if ended {
                ended = false
            }
            player.play()
            isPlaying = true
        }
    }

    func jump(_ seconds: Int32) {
        guard player.isSeekable else { return }
        let target = max(0, timeMs + seconds * 1000)
        if lengthMs > 0 && target >= lengthMs - 1000 { return }
        player.time = VLCTime(int: target)
        timeMs = target
        stallTicks = 0
    }

    func seek(fraction: Double) {
        guard lengthMs > 0, player.isSeekable else { return }
        let target = Int32(Double(lengthMs) * min(max(fraction, 0), 0.995))
        player.time = VLCTime(int: target)
        timeMs = target
        stallTicks = 0
    }

    func setRate(_ value: Float) {
        rate = value
        player.rate = value
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
