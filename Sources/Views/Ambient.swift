import SwiftUI
import UIKit
import CoreImage

/// The soft light at the top of a screen: the poster on screen, blurred and faded into the
/// background, so the screen takes the colour of the film. It is placed with its upper part far
/// above the screen, so pulling the list down does not show its edge.
struct AmbientGlow: View {
    let url: URL?
    var height: CGFloat
    var intensity: Double = 0.65
    @State private var image: UIImage?

    init(url: URL?, height: CGFloat, intensity: Double = 0.65) {
        self.url = url
        self.height = height
        self.intensity = intensity
        _image = State(initialValue: url.flatMap { AmbientImages.cached($0) })
    }

    var body: some View {
        Color.clear
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .overlay {
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .opacity(intensity)
                        .id(ObjectIdentifier(image))
                        .transition(.opacity)
                }
            }
            .clipped()
            .overlay {
                LinearGradient(stops: [
                    .init(color: Theme.background.opacity(0.1), location: 0),
                    .init(color: Theme.background.opacity(0.1), location: 0.35),
                    .init(color: Theme.background.opacity(0.32), location: 0.68),
                    .init(color: Theme.background, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: url) {
                guard let url = url else {
                    withAnimation(.easeInOut(duration: 0.5)) { image = nil }
                    return
                }
                if let cached = AmbientImages.cached(url) {
                    if cached !== image {
                        withAnimation(.easeInOut(duration: 0.5)) { image = cached }
                    }
                    return
                }
                let loaded = await AmbientImages.load(url)
                if !Task.isCancelled, let loaded = loaded {
                    withAnimation(.easeInOut(duration: 0.6)) { image = loaded }
                }
            }
    }
}

/// Blurred, more saturated copies of posters for `AmbientGlow`. They are made once from a tiny
/// thumbnail on the processor: a live blur over the whole screen would cost the graphics on every
/// frame of scrolling.
enum AmbientImages {
    private static let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 60
        return cache
    }()
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    static func load(_ url: URL) async -> UIImage? {
        if let image = cached(url) { return image }
        guard let small = await ImageCache.shared.load(url, maxPixel: 96), let source = small.cgImage else { return nil }
        let made = await Task.detached(priority: .utility) { () -> CGImage? in
            AmbientImages.blurred(source)
        }.value
        guard let made = made else { return nil }
        let image = UIImage(cgImage: made)
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    private static func blurred(_ source: CGImage) -> CGImage? {
        let input = CIImage(cgImage: source)
        let extent = input.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let sigma = Double(max(extent.width, extent.height)) * 0.07
        let output = input
            .clampedToExtent()
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.6,
                kCIInputBrightnessKey: -0.04
            ])
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: extent)
        return context.createCGImage(output, from: extent)
    }
}

extension AmbientImages {
    /// The average colour of a small picture.
    static func average(_ source: CGImage) -> PosterRGB? {
        let input = CIImage(cgImage: source)
        let extent = input.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let output = input.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: extent)])
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: extent.minX, y: extent.minY, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return PosterRGB(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
    }
}

// MARK: - The colour of a film page

/// The average colour of a poster.
struct PosterRGB {
    var red: Double
    var green: Double
    var blue: Double
}

/// The background of a film page: the hue of its poster, dark enough for white text. A grey or
/// almost black poster gives the usual neutral background.
enum PosterTint {
    private static let cache: NSCache<NSURL, UIColor> = {
        let cache = NSCache<NSURL, UIColor>()
        cache.countLimit = 200
        return cache
    }()

    static func cached(_ url: URL?) -> Color? {
        guard let url = url, let color = cache.object(forKey: url as NSURL) else { return nil }
        return Color(uiColor: color)
    }

    static func load(_ url: URL) async -> Color? {
        if let color = cache.object(forKey: url as NSURL) { return Color(uiColor: color) }
        guard let small = await ImageCache.shared.load(url, maxPixel: 96), let source = small.cgImage else { return nil }
        let average = await Task.detached(priority: .utility) { () -> PosterRGB? in
            AmbientImages.average(source)
        }.value
        guard let average = average else { return nil }
        let color = page(from: average)
        cache.setObject(color, forKey: url as NSURL)
        return Color(uiColor: color)
    }

    /// "Дюна" (an orange poster) gives a dark amber, a blue poster a dark navy.
    static func page(from average: PosterRGB) -> UIColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        UIColor(red: CGFloat(average.red), green: CGFloat(average.green), blue: CGFloat(average.blue), alpha: 1)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // How much colour the poster has: none for a grey or an almost black one.
        let colour = min(saturation / 0.45, 1) * min(brightness / 0.2, 1)
        return UIColor(hue: hue,
                       saturation: min(saturation, 0.7) * 0.85 * colour,
                       brightness: 0.065 + 0.105 * colour,
                       alpha: 1)
    }
}

// MARK: - Frames of films

/// Landscape frames of films (Zona's backdrops) for the cards of "Продолжить просмотр" and the
/// trailer when Kinopoisk gives none.
enum Backdrops {
    private static let known = NSCache<NSNumber, NSURL>()

    static func cached(_ id: Int?) -> URL? {
        guard let id = id, let url = known.object(forKey: NSNumber(value: id)) else { return nil }
        return url as URL
    }

    static func load(_ id: Int) async -> URL? {
        if let url = cached(id) { return url }
        guard ZonaCatalog.isEnabled, let movie = try? await ZonaCatalog.shared.movie(id),
              let link = movie.backdropURL, let url = URL(string: link) else { return nil }
        known.setObject(url as NSURL, forKey: NSNumber(value: id))
        return url
    }
}

// MARK: - The big poster at the top

/// A poster over the whole width from the very top of the screen (under the status bar and the
/// navigation bar), fading into the page below. Pulled down, it grows up instead of leaving a gap.
struct HeroPicture: View {
    let item: MediaItem
    let height: CGFloat
    /// The colour of the page under the picture.
    var fade: Color = Theme.background

    /// The full-size poster, drawn over the preview of the lists (that one is usually loaded already).
    private var largePoster: URL? {
        guard let preview = item.posterPreviewURL, !preview.isEmpty,
              let full = item.posterURL, full != preview else { return nil }
        return URL(string: full)
    }

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay(alignment: .top) { PosterImage(url: item.poster) }
            .overlay(alignment: .top) { PosterImage(url: largePoster, maxPixel: 1400, placeholder: false) }
            .overlay {
                // A little darker under the status bar; the bottom, where the title is, fades into the page.
                LinearGradient(stops: [
                    .init(color: Color.black.opacity(0.3), location: 0),
                    .init(color: Color.black.opacity(0), location: 0.2),
                    .init(color: fade.opacity(0), location: 0.42),
                    .init(color: fade.opacity(0.55), location: 0.68),
                    .init(color: fade.opacity(0.9), location: 0.86),
                    .init(color: fade, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .clipped()
            .visualEffect { content, geometry in
                let minY = geometry.frame(in: .scrollView(axis: .vertical)).minY
                let side = max(geometry.size.height, 1)
                return content.scaleEffect(minY > 0 ? 1 + minY / side : 1, anchor: .bottom)
            }
            .mask(alignment: .bottom) {
                // The grown picture stays within its width (the next poster of a carousel is beside it).
                Rectangle()
                    .frame(height: height + 2000)
            }
            .accessibilityHidden(true)
    }
}
