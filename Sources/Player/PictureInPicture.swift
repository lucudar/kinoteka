import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import Darwin
import UIKit
import VLCKitSPM

// MARK: - libvlc video callbacks

/// VLC can hand its decoded frames to the app instead of drawing them into a view (the libvlc
/// "vmem" video output). Picture in Picture needs that: iOS shows the floating window only for
/// an AVPlayer or an AVSampleBufferDisplayLayer. VLCKit 3 does not wrap these libvlc functions,
/// they are looked up in the loaded VLCKit framework.
enum LibVLCVideo {
    typealias LockCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> UnsafeMutableRawPointer?
    typealias UnlockCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafePointer<UnsafeMutableRawPointer?>?) -> Void
    typealias DisplayCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    typealias SetupCallback = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>?, UnsafeMutablePointer<CChar>?,
                                              UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?,
                                              UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> UInt32
    typealias CleanupCallback = @convention(c) (UnsafeMutableRawPointer?) -> Void

    private typealias SetCallbacks = @convention(c) (UnsafeMutableRawPointer?, LockCallback?, UnlockCallback?, DisplayCallback?, UnsafeMutableRawPointer?) -> Void
    private typealias SetFormatCallbacks = @convention(c) (UnsafeMutableRawPointer?, SetupCallback?, CleanupCallback?) -> Void
    private typealias PointerGetter = @convention(c) (AnyObject, Selector) -> UnsafeMutableRawPointer?

    private struct Functions: @unchecked Sendable {
        let setCallbacks: SetCallbacks
        let setFormatCallbacks: SetFormatCallbacks
    }

    private static let functions: Functions? = {
        let anyImage = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let callbacks = dlsym(anyImage, "libvlc_video_set_callbacks"),
              let format = dlsym(anyImage, "libvlc_video_set_format_callbacks") else { return nil }
        return Functions(setCallbacks: unsafeBitCast(callbacks, to: SetCallbacks.self),
                         setFormatCallbacks: unsafeBitCast(format, to: SetFormatCallbacks.self))
    }()

    static var isAvailable: Bool { functions != nil }

    /// The libvlc_media_player_t of a VLCKit player (a private VLCKit property).
    private static func mediaPlayer(of player: VLCMediaPlayer) -> UnsafeMutableRawPointer? {
        for name in ["libVLCMediaPlayer", "playerInstance"] {
            let selector = NSSelectorFromString(name)
            guard player.responds(to: selector) else { continue }
            let getter = unsafeBitCast(player.method(for: selector), to: PointerGetter.self)
            if let pointer = getter(player, selector) { return pointer }
        }
        return nil
    }

    /// Sends the frames of a player that has not started yet to the sink.
    static func attach(_ sink: SampleBufferSink, to player: VLCMediaPlayer) -> Bool {
        guard let functions, let handle = mediaPlayer(of: player) else { return false }
        // libvlc may call back until its video output has closed, which can be after the player
        // object is gone: the sink is never freed (its buffers are, when the output closes).
        let opaque = Unmanaged.passRetained(sink).toOpaque()
        functions.setCallbacks(handle, vmemLock, vmemUnlock, vmemDisplay, opaque)
        functions.setFormatCallbacks(handle, vmemSetup, vmemCleanup)
        return true
    }
}

private func sampleSink(_ opaque: UnsafeMutableRawPointer?) -> SampleBufferSink? {
    guard let opaque else { return nil }
    return Unmanaged<SampleBufferSink>.fromOpaque(opaque).takeUnretainedValue()
}

private func vmemSetup(_ opaque: UnsafeMutablePointer<UnsafeMutableRawPointer?>?, _ chroma: UnsafeMutablePointer<CChar>?,
                       _ width: UnsafeMutablePointer<UInt32>?, _ height: UnsafeMutablePointer<UInt32>?,
                       _ pitches: UnsafeMutablePointer<UInt32>?, _ lines: UnsafeMutablePointer<UInt32>?) -> UInt32 {
    guard let opaque, let sink = sampleSink(opaque.pointee), let chroma, let width, let height,
          let pitches, let lines else { return 0 }
    return sink.setup(chroma: chroma, width: width, height: height, pitches: pitches, lines: lines)
}

private func vmemCleanup(_ opaque: UnsafeMutableRawPointer?) {
    sampleSink(opaque)?.cleanup()
}

private func vmemLock(_ opaque: UnsafeMutableRawPointer?, _ planes: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> UnsafeMutableRawPointer? {
    guard let sink = sampleSink(opaque), let planes else { return nil }
    return sink.lockFrame(planes)
}

private func vmemUnlock(_ opaque: UnsafeMutableRawPointer?, _ picture: UnsafeMutableRawPointer?,
                        _ planes: UnsafePointer<UnsafeMutableRawPointer?>?) {
    sampleSink(opaque)?.unlockFrame(picture)
}

private func vmemDisplay(_ opaque: UnsafeMutableRawPointer?, _ picture: UnsafeMutableRawPointer?) {
    sampleSink(opaque)?.displayFrame(picture)
}

// MARK: - Frames to sample buffers

/// Receives VLC's frames in IOSurface pixel buffers of a pool and shows them with an
/// AVSampleBufferDisplayLayer: in the player and in the Picture in Picture window.
/// libvlc calls it on its video threads, the state is guarded by locks.
final class SampleBufferSink: @unchecked Sendable {
    let layer: AVSampleBufferDisplayLayer
    let timebase: CMTimebase?
    private let renderer: AVSampleBufferVideoRenderer

    private struct Frame {
        var buffer: CVPixelBuffer?
        var locked: Bool
    }

    private let stateLock = NSLock()
    private var pool: CVPixelBufferPool?
    private var frames: [Int: Frame] = [:]
    private var nextToken = 0
    private var scratch: UnsafeMutableRawPointer?
    private var scratchSecondPlane = 0
    private var scratchBytes = 0
    private var accepting = true
    private var hint: (width: Int, height: Int)?
    private var pixelAspect: (horizontal: Int, vertical: Int)?
    private var highDefinition = true

    private let renderLock = NSLock()
    private var format: CMVideoFormatDescription?
    private var shownFrames = 0

    init() {
        layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        renderer = layer.sampleBufferRenderer
        var created: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &created)
        timebase = created
        if let created {
            CMTimebaseSetTime(created, time: .zero)
            CMTimebaseSetRate(created, rate: 0)
            layer.controlTimebase = created
        }
    }

    /// The picture size known from the previous player: VLC reports the coded size
    /// (1920×1088 for 1080p), the extra lines must not get into the picture.
    func setHint(size: CGSize, pixelAspect: (Int, Int)?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if size.width >= 16, size.height >= 16, size.width.isFinite, size.height.isFinite {
            hint = (Int(size.width), Int(size.height))
        }
        if let pixelAspect, pixelAspect.0 > 0, pixelAspect.1 > 0, pixelAspect.0 != pixelAspect.1 {
            self.pixelAspect = (pixelAspect.0, pixelAspect.1)
        } else {
            self.pixelAspect = nil
        }
    }

    var displayedFrames: Int {
        renderLock.lock()
        defer { renderLock.unlock() }
        return shownFrames
    }

    func setup(chroma: UnsafeMutablePointer<CChar>, width: UnsafeMutablePointer<UInt32>, height: UnsafeMutablePointer<UInt32>,
               pitches: UnsafeMutablePointer<UInt32>, lines: UnsafeMutablePointer<UInt32>) -> UInt32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        var w = Int(width.pointee)
        var h = Int(height.pointee)
        if let hint, hint.width <= w, hint.height <= h, w - hint.width < 32, h - hint.height < 32 {
            w = hint.width
            h = hint.height
        } else if h == 1088 {
            h = 1080
        }
        w &= ~1
        h &= ~1
        guard w >= 16, h >= 16, w <= 8192, h <= 8192 else { return 0 }

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferBytesPerRowAlignmentKey as String: 64,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        let poolAttributes: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 4]
        var createdPool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary, attributes as CFDictionary,
                                      &createdPool) == kCVReturnSuccess, let newPool = createdPool else { return 0 }
        var probe: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, newPool, &probe) == kCVReturnSuccess,
              let probe, CVPixelBufferGetPlaneCount(probe) == 2 else { return 0 }
        let pitch0 = CVPixelBufferGetBytesPerRowOfPlane(probe, 0)
        let pitch1 = CVPixelBufferGetBytesPerRowOfPlane(probe, 1)
        let lines0 = CVPixelBufferGetHeightOfPlane(probe, 0)
        let lines1 = CVPixelBufferGetHeightOfPlane(probe, 1)
        guard pitch0 >= w, pitch1 >= w, lines0 >= h, lines1 >= h / 2 else { return 0 }

        // Frames that get no pixel buffer (too many on the screen, stopping) go here and are not shown.
        let first = pitch0 * lines0
        let needed = first + pitch1 * lines1 + 64
        if scratch == nil || needed > scratchBytes {
            // The old memory is not freed here: a closing output might still hold it.
            scratch = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 64)
            scratchBytes = needed
        }
        scratchSecondPlane = first

        for (index, byte) in [UInt8(0x4E), 0x56, 0x31, 0x32].enumerated() { // "NV12"
            chroma[index] = CChar(truncatingIfNeeded: byte)
        }
        width.pointee = UInt32(w)
        height.pointee = UInt32(h)
        pitches[0] = UInt32(pitch0)
        pitches[1] = UInt32(pitch1)
        lines[0] = UInt32(lines0)
        lines[1] = UInt32(lines1)
        pool = newPool
        highDefinition = w >= 1280 || h >= 720
        AppDiagnostics.shared.log("pip", "Кадры для «Картинки в картинке»: \(w)×\(h)")
        return 6
    }

    func cleanup() {
        stateLock.lock()
        defer { stateLock.unlock() }
        pool = nil
        for (token, frame) in frames where frame.locked {
            if let buffer = frame.buffer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            frames[token]?.locked = false
        }
        if let scratch, frames.values.allSatisfy({ $0.buffer != nil }) {
            scratch.deallocate()
            self.scratch = nil
        }
    }

    func lockFrame(_ planes: UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> UnsafeMutableRawPointer? {
        stateLock.lock()
        defer { stateLock.unlock() }
        nextToken = nextToken >= Int.max - 1 ? 1 : nextToken + 1
        let token = nextToken
        if accepting, let pool {
            var created: CVPixelBuffer?
            let limit = [kCVPixelBufferPoolAllocationThresholdKey as String: 16] as CFDictionary
            if CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, limit, &created) == kCVReturnSuccess,
               let buffer = created, CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess {
                if let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                   let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
                    planes[0] = luma
                    planes[1] = chroma
                    frames[token] = Frame(buffer: buffer, locked: true)
                    return UnsafeMutableRawPointer(bitPattern: token)
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
            }
        }
        if scratch == nil {
            // Only possible if VLC draws after its output closed: give it memory of the last size.
            scratch = UnsafeMutableRawPointer.allocate(byteCount: max(scratchBytes, 4096), alignment: 64)
        }
        planes[0] = scratch
        planes[1] = scratch.map { $0 + scratchSecondPlane }
        frames[token] = Frame(buffer: nil, locked: false)
        return UnsafeMutableRawPointer(bitPattern: token)
    }

    func unlockFrame(_ picture: UnsafeMutableRawPointer?) {
        let token = Int(bitPattern: picture)
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let frame = frames.removeValue(forKey: token) else { return }
        if frame.locked, let buffer = frame.buffer {
            CVPixelBufferUnlockBaseAddress(buffer, [])
        }
    }

    func displayFrame(_ picture: UnsafeMutableRawPointer?) {
        let token = Int(bitPattern: picture)
        stateLock.lock()
        guard var frame = frames[token], let buffer = frame.buffer else {
            stateLock.unlock()
            return
        }
        if frame.locked {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            frame.locked = false
            frames[token] = frame
        }
        let show = accepting
        let hd = highDefinition
        let aspect = pixelAspect
        stateLock.unlock()
        guard show else { return }
        describe(buffer, highDefinition: hd, pixelAspect: aspect)
        enqueue(buffer)
    }

    private func describe(_ buffer: CVPixelBuffer, highDefinition: Bool, pixelAspect: (horizontal: Int, vertical: Int)?) {
        let matrix = highDefinition ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4
        let primaries = highDefinition ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_SMPTE_C
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        if let pixelAspect {
            let ratio: [String: Any] = [
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String: pixelAspect.horizontal,
                kCVImageBufferPixelAspectRatioVerticalSpacingKey as String: pixelAspect.vertical
            ]
            CVBufferSetAttachment(buffer, kCVImageBufferPixelAspectRatioKey, ratio as CFDictionary, .shouldPropagate)
        }
    }

    private func enqueue(_ buffer: CVPixelBuffer) {
        renderLock.lock()
        defer { renderLock.unlock() }
        if let current = format, CMVideoFormatDescriptionMatchesImageBuffer(current, imageBuffer: buffer) {
            // The same size and colours as before.
        } else {
            var created: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                         formatDescriptionOut: &created)
            format = created
        }
        guard let format else { return }
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
        }
        guard renderer.isReadyForMoreMediaData else { return }
        let now = timebase.map { CMTimebaseGetTime($0) } ?? .zero
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: now, decodeTimeStamp: .invalid)
        var created: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                       formatDescription: format, sampleTiming: &timing,
                                                       sampleBufferOut: &created) == noErr,
              let sample = created else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        renderer.enqueue(sample)
        shownFrames += 1
    }

    /// After the app was in the background the layer may need a flush to show frames again.
    func recover() {
        renderLock.lock()
        defer { renderLock.unlock() }
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
        }
    }

    /// The position and the speed shown by the Picture in Picture window.
    func updateClock(seconds: Double, rate: Double) {
        guard let timebase, seconds.isFinite, rate.isFinite else { return }
        let current = CMTimebaseGetTime(timebase).seconds
        if !current.isFinite || abs(current - seconds) > 0.75 {
            CMTimebaseSetTime(timebase, time: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
        }
        if abs(CMTimebaseGetRate(timebase) - rate) > 0.001 {
            CMTimebaseSetRate(timebase, rate: rate)
        }
    }

    /// The player is gone: nothing more is shown, the buffers are given back.
    func invalidate() {
        stateLock.lock()
        accepting = false
        pool = nil
        stateLock.unlock()
        renderLock.lock()
        renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        format = nil
        renderLock.unlock()
        if let timebase { CMTimebaseSetRate(timebase, rate: 0) }
    }
}

/// The view with the sample buffer layer; the aspect modes of the player are layer geometry here.
final class SampleBufferVideoView: UIView {
    let sink: SampleBufferSink
    var aspect: AspectMode = .fit {
        didSet { if aspect != oldValue { setNeedsLayout() } }
    }

    init(sink: SampleBufferSink) {
        self.sink = sink
        super.init(frame: .zero)
        backgroundColor = .black
        isUserInteractionEnabled = false
        clipsToBounds = true
        layer.addSublayer(sink.layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let video = sink.layer
        switch aspect {
        case .fit:
            video.videoGravity = .resizeAspect
            video.frame = bounds
        case .fill:
            video.videoGravity = .resizeAspectFill
            video.frame = bounds
        case .stretch:
            video.videoGravity = .resize
            video.frame = bounds
        case .ratio16x9:
            video.videoGravity = .resize
            video.frame = AVMakeRect(aspectRatio: CGSize(width: 16, height: 9), insideRect: bounds)
        case .ratio4x3:
            video.videoGravity = .resize
            video.frame = AVMakeRect(aspectRatio: CGSize(width: 4, height: 3), insideRect: bounds)
        }
        CATransaction.commit()
    }
}

// MARK: - Picture in Picture controller

/// Delegate of AVKit's Picture in Picture controller. AVKit asks for the playback state at any
/// time: it is kept behind a lock; the actions are handed to the player on the main thread.
final class PictureInPictureBridge: NSObject, AVPictureInPictureControllerDelegate,
                                    AVPictureInPictureSampleBufferPlaybackDelegate, @unchecked Sendable {
    enum Event {
        case willStart
        case didStart
        case failed(String)
        case willStop
        case didStop
        case restore((Bool) -> Void)
        case setPlaying(Bool)
        case skip(Double)
    }

    private let lock = NSLock()
    private var paused = true
    private var duration: Double = 0
    private var live = false
    private let handler: @MainActor (Event) -> Void

    init(handler: @escaping @MainActor (Event) -> Void) {
        self.handler = handler
    }

    /// Returns whether AVKit has to ask again (`invalidatePlaybackState`).
    func update(paused: Bool, duration: Double, live: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let changed = paused != self.paused || abs(duration - self.duration) > 1 || live != self.live
        self.paused = paused
        self.duration = duration
        self.live = live
        return changed
    }

    private func send(_ event: Event) {
        let handler = self.handler
        if Thread.isMainThread {
            MainActor.assumeIsolated { handler(event) }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { handler(event) }
            }
        }
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        send(.willStart)
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        send(.didStart)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        send(.failed(error.localizedDescription))
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        send(.willStop)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        send(.didStop)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        send(.restore(completionHandler))
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        lock.lock()
        paused = !playing
        lock.unlock()
        send(.setPlaying(playing))
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        lock.lock()
        defer { lock.unlock() }
        guard !live, duration > 0 else {
            return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }
        return CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return paused
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        let seconds = skipInterval.seconds
        if seconds.isFinite { send(.skip(seconds)) }
        completionHandler()
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }
}

enum PictureInPictureSupport {
    /// The device shows Picture in Picture and VLCKit can hand over its frames.
    static var isAvailable: Bool {
        AVPictureInPictureController.isPictureInPictureSupported() && LibVLCVideo.isAvailable
    }
}
