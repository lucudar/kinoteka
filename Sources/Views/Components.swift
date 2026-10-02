import SwiftUI
import UIKit
import ImageIO

// MARK: - Image loading with memory + disk cache

final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    /// Grid posters are at most about 180×270 pt: 800 px covers 3× screens.
    static let defaultMaxPixel = 800

    private let memory = NSCache<NSString, UIImage>()
    private let urlCache: URLCache
    private let session: URLSession
    private let lock = NSLock()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init() {
        memory.countLimit = 300
        memory.totalCostLimit = 80 * 1024 * 1024
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("images", isDirectory: true)
        urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024, directory: dir)
        let config = URLSessionConfiguration.default
        config.urlCache = urlCache
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    private static func key(_ url: URL, _ maxPixel: Int) -> String {
        "\(maxPixel)|\(url.absoluteString)"
    }

    func cached(_ url: URL, maxPixel: Int = ImageCache.defaultMaxPixel) -> UIImage? {
        memory.object(forKey: ImageCache.key(url, maxPixel) as NSString)
    }

    func load(_ url: URL, maxPixel: Int = ImageCache.defaultMaxPixel) async -> UIImage? {
        let key = ImageCache.key(url, maxPixel)
        if let image = memory.object(forKey: key as NSString) { return image }
        let task: Task<UIImage?, Never>
        lock.lock()
        if let existing = inFlight[key] {
            task = existing
        } else {
            let session = session
            let size = max(64, min(maxPixel, 2000))
            task = Task {
                guard let (data, _) = try? await session.data(from: url),
                      let image = ImageCache.downsample(data, maxPixel: size) else { return nil }
                return await image.byPreparingForDisplay() ?? image
            }
            inFlight[key] = task
        }
        lock.unlock()

        let prepared = await task.value
        lock.lock()
        inFlight[key] = nil
        lock.unlock()
        guard let prepared = prepared else { return nil }
        let pixels = prepared.size.width * prepared.scale * prepared.size.height * prepared.scale
        let cost = pixels.isFinite ? Int(min(max(pixels * 4, 0), 64 * 1024 * 1024)) : 0
        memory.setObject(prepared, forKey: key as NSString, cost: cost)
        return prepared
    }

    /// Memory warning: decoded images are dropped, the files stay in the disk cache.
    func purgeMemory() {
        memory.removeAllObjects()
        let capacity = urlCache.memoryCapacity
        urlCache.memoryCapacity = 0
        urlCache.memoryCapacity = capacity
    }

    /// Posters from Kinopoisk can be several thousand pixels wide. Decoding them
    /// at display size avoids large memory spikes while quickly scrolling.
    private static func downsample(_ data: Data, maxPixel: Int) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct PosterImage: View {
    let url: URL?
    var mode: ContentMode = .fill
    var maxPixel: Int = ImageCache.defaultMaxPixel
    @State private var image: UIImage?

    init(url: URL?, mode: ContentMode = .fill, maxPixel: Int = ImageCache.defaultMaxPixel) {
        self.url = url
        self.mode = mode
        self.maxPixel = maxPixel
        _image = State(initialValue: url.flatMap { ImageCache.shared.cached($0, maxPixel: maxPixel) })
    }

    var body: some View {
        ZStack {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: mode)
            } else if mode == .fill {
                Theme.card
                Image(systemName: "film")
                    .font(.title2)
                    .foregroundStyle(Theme.secondary.opacity(0.35))
            }
        }
        .allowsHitTesting(false)
        .task(id: url) {
            guard let url = url else {
                image = nil
                return
            }
            if let cached = ImageCache.shared.cached(url, maxPixel: maxPixel) {
                image = cached
                return
            }
            let loaded = await ImageCache.shared.load(url, maxPixel: maxPixel)
            if !Task.isCancelled, let loaded = loaded {
                image = loaded
            }
        }
    }
}

// MARK: - Cards

struct RatingBadge: View {
    let value: Double

    var body: some View {
        Text(RatingStyle.text(value))
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RatingStyle.color(value), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct PosterCard: View {
    @EnvironmentObject private var library: LibraryStore
    let item: MediaItem
    var width: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay { PosterImage(url: item.poster) }
                .overlay(alignment: .topLeading) {
                    if let rating = item.ratingKP ?? item.ratingIMDb, rating > 0 {
                        RatingBadge(value: rating).padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    VStack(spacing: 5) {
                        if library.isWatched(item.id) {
                            Image(systemName: "eye.fill")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(Circle().fill(Theme.accent))
                        }
                        if library.isWatchLater(item) {
                            Image(systemName: "bookmark.fill")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(Circle().fill(Color.black.opacity(0.7)))
                        }
                    }
                    .padding(6)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(item.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            Text(item.subtitleLine)
                .font(.caption2)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
        }
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                library.toggleWatchLater(item)
            } label: {
                Label(library.isWatchLater(item) ? "Убрать из «Смотреть позже»" : "Смотреть позже",
                      systemImage: library.isWatchLater(item) ? "bookmark.slash" : "bookmark")
            }
            Button {
                library.toggleFavorite(item)
            } label: {
                Label(library.isFavorite(item) ? "Убрать из избранного" : "В избранное",
                      systemImage: library.isFavorite(item) ? "heart.slash" : "heart")
            }
            Button {
                library.toggleWatched(item)
            } label: {
                Label(library.isWatched(item.id) ? "Отметить непросмотренным" : "Отметить просмотренным",
                      systemImage: library.isWatched(item.id) ? "eye.slash" : "eye")
            }
        }
    }
}

struct MediaRow: View {
    let items: [MediaItem]
    var cardWidth: CGFloat = 116

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(items) { item in
                    NavigationLink(value: item) {
                        PosterCard(item: item, width: cardWidth)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

struct PlaceholderRow: View {
    var cardWidth: CGFloat = 116

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(0..<6, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.card)
                        .frame(width: cardWidth, height: cardWidth * 1.5)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollDisabled(true)
    }
}

struct MediaGrid: View {
    let items: [MediaItem]
    var onAppearItem: ((MediaItem) -> Void)? = nil

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 12, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(items) { item in
                NavigationLink(value: item) {
                    PosterCard(item: item)
                }
                .buttonStyle(.plain)
                .onAppear { onAppearItem?(item) }
            }
        }
        .padding(.horizontal, 16)
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.title3.weight(.bold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
    }
}

struct CircleAction: View {
    let title: String
    let systemImage: String
    var active: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(active ? Theme.accent.opacity(0.22) : Theme.card))
                    .foregroundStyle(active ? Theme.accent : Color.white)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ErrorView: View {
    let message: String
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(Theme.secondary)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.secondary)
            if let retry = retry {
                Button("Повторить", action: retry)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

struct TokenBanner: View {
    var body: some View {
        NavigationLink {
            SettingsView()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "key.fill")
                    .foregroundStyle(Theme.accent)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Нужен ключ API Кинопоиска")
                        .font(.subheadline.weight(.semibold))
                    Text("Каталог, поиск и описания берутся из неофициального API Кинопоиска. Ключ бесплатный: зарегистрируйтесь на kinopoiskapiunofficial.tech и вставьте его в настройках.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(Theme.secondary)
            }
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }
}

struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(selected ? Theme.accent : Theme.card))
        }
        .buttonStyle(.plain)
    }
}
