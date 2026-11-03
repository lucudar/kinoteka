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
