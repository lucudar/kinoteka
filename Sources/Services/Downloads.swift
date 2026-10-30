import Foundation
import Combine
import UIKit

// MARK: - Model

/// One file of a torrent saved for offline viewing (a film or one episode).
struct DownloadItem: Codable, Identifiable, Equatable {
    enum State: String, Codable {
        case queued
        case downloading
        case paused
        case completed
        case failed
    }

    let hash: String
    let file: TorrentFile
    var link: String
    var itemKey: String?
    var item: MediaItem?
    var title: String
    var detail: String
    var season: Int?
    var episode: Int?
    var state: State
    var received: Int64
    var error: String?
    var added: Date
    var completed: Date?
    /// Subtitle files of the torrent next to the video, saved with it.
    var subtitleSources: [TorrentFile]
    var subtitleNames: [String]

    var id: String { DownloadItem.identifier(hash: hash, fileId: file.id) }

    static func identifier(hash: String, fileId: Int) -> String {
        "\(hash.lowercased()):\(fileId)"
    }

    var fileName: String {
        let ext = file.ext.isEmpty ? "mkv" : file.ext
        return "\(hash)-\(file.id).\(ext)"
    }

    var subtitlesFolder: String { "\(hash)-\(file.id)-subs" }

    var progress: Double {
        guard file.length > 0 else { return state == .completed ? 1 : 0 }
        return min(1, max(0, Double(received) / Double(file.length)))
    }

    /// Rows of one film or series are shown together.
    var groupKey: String { itemKey ?? hash }

    var isUnfinished: Bool { state == .queued || state == .downloading }
}

/// The file list of a downloaded torrent: the player opens the saved files without the network.
struct DownloadTorrent: Codable, Equatable {
    let hash: String
    var link: String
    var title: String
    var files: [TorrentFile]
}

private struct DownloadIndex: Codable {
    var items: [DownloadItem]
    var torrents: [DownloadTorrent]
}

// MARK: - One transfer

/// Saves a file from the engine's stream to disk and continues a partial file with a range request.
final class RangeDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Failure: LocalizedError {
        case http(Int)
        case noSpace
        case write(String)

        var errorDescription: String? {
            switch self {
            case .http(let code): return "Торрент-движок ответил HTTP \(code)"
            case .noSpace: return "На iPhone закончилось место"
            case .write(let text): return "Не удалось записать файл: \(text)"
            }
        }
    }

    private let url: URL
    private let destination: URL
    private let expectedLength: Int64
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int64, Error>?
    private var task: URLSessionDataTask?
    private var cancelled = false
    // Touched only on the session's serial delegate queue (and before the task starts).
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var failure: Error?
    private var nothingLeft = false
    private var lastReport = Date.distantPast

    init(url: URL, destination: URL, expectedLength: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.url = url
        self.destination = destination
        self.expectedLength = expectedLength
        self.progress = progress
    }

    /// Returns the size of the file on disk when the stream has ended.
    func run() async throws -> Int64 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int64, Error>) in
                lock.lock()
                let stop = cancelled
                if !stop { self.continuation = continuation }
                lock.unlock()
                if stop {
                    continuation.resume(throwing: CancellationError())
                } else {
                    begin()
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = task
        lock.unlock()
        running?.cancel()
    }

    private func complete(_ result: Result<Int64, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }

    private func begin() {
        let manager = FileManager.default
        if !manager.fileExists(atPath: destination.path) {
            manager.createFile(atPath: destination.path, contents: nil)
        }
        let existing = (try? manager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        if expectedLength > 0, existing >= expectedLength {
            complete(.success(existing))
            return
        }
        do {
            handle = try FileHandle(forWritingTo: destination)
            try handle?.seekToEnd()
        } catch {
            complete(.failure(RangeDownload.map(error)))
            return
        }
        received = existing
        let configuration = URLSessionConfiguration.ephemeral
        // The engine sends nothing while it waits for peers; a minute without data is a stall.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        var request = URLRequest(url: url)
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }
        let dataTask = session.dataTask(with: request)
        lock.lock()
        task = dataTask
        let stop = cancelled
        lock.unlock()
        dataTask.resume()
        if stop { dataTask.cancel() }
    }

    private func position(at offset: Int64) throws {
        guard let handle else { throw Failure.write("файл закрыт") }
        try handle.truncate(atOffset: UInt64(max(0, offset)))
        try handle.seek(toOffset: UInt64(max(0, offset)))
        received = max(0, offset)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        do {
            switch code {
            case 206:
                let start = HTTPRange.start(fromContentRange: http?.value(forHTTPHeaderField: "Content-Range")) ?? received
                // A later start would leave a hole in the file.
                guard start <= received else { throw Failure.http(code) }
                if start != received { try position(at: start) }
            case 200:
                // The range was ignored: the whole file comes again.
                try position(at: 0)
            case 416:
                nothingLeft = true
                completionHandler(.cancel)
                return
            default:
                throw Failure.http(code)
            }
            completionHandler(.allow)
        } catch {
            failure = RangeDownload.map(error)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, let handle else { return }
        do {
            try handle.write(contentsOf: data)
            received += Int64(data.count)
            let now = Date()
            if now.timeIntervalSince(lastReport) >= 0.5 {
                lastReport = now
                progress(received)
            }
        } catch {
            failure = RangeDownload.map(error)
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        progress(received)
        session.finishTasksAndInvalidate()
        lock.lock()
        let stopped = cancelled
        lock.unlock()
        if let failure {
            complete(.failure(failure))
        } else if stopped {
            complete(.failure(CancellationError()))
        } else if let error, !nothingLeft {
            complete(.failure(error))
        } else {
            complete(.success(received))
        }
    }

    static func map(_ error: Error) -> Error {
        if error is Failure { return error }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError { return Failure.noSpace }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return Failure.noSpace }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOSPC) {
            return Failure.noSpace
        }
        return Failure.write(error.localizedDescription)
    }
}

// MARK: - Queue

/// Files are downloaded one after another through the built-in torrent engine, while the app is
/// open (iOS suspends it soon after it is closed, unless a video or its sound is playing).
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    enum Failure: LocalizedError {
        case fileMissing
        case noSpace(Int64)
        case incomplete

        var errorDescription: String? {
            switch self {
            case .fileMissing:
                return "Файла больше нет в раздаче"
            case .noSpace(let needed):
                return "Недостаточно места: освободите ещё \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file))"
            case .incomplete:
                return "Раздача отдала файл не полностью"
            }
        }
    }

    @Published private(set) var items: [DownloadItem] = []
    @Published private(set) var activeId: String?
    /// Bytes per second of the current file.
    @Published private(set) var rate: Double = 0
    /// Why the queue waits ("Ждём Wi‑Fi"), nil when it runs or is empty.
    @Published private(set) var waitingReason: String?

    /// The player streams through the engine (not a saved file).
    var playerStreaming = false {
        didSet { if oldValue != playerStreaming { conditionsChanged() } }
    }

    let directory: URL
    /// Space left free on the iPhone for the system and other apps.
    private let reserve: Int64 = 500 * 1024 * 1024
    private static let ioQueue = DispatchQueue(label: "kinoteka.downloads.io", qos: .utility)
    private let smallSession = URLSession(configuration: .ephemeral)
    private var torrents: [String: DownloadTorrent] = [:]
    private var worker: Task<Void, Never>?
    private var workerGeneration = 0
    private var failures: [String: Int] = [:]
    private var samples: [(date: Date, bytes: Int64)] = []
    private var lastPersist = Date.distantPast
    private var lastProgressAt = Date()
    private var backgroundToken: BackgroundTaskToken?
    private var cancellables: Set<AnyCancellable> = []
    private var started = false

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = directory
        try? folder.setResourceValues(values)
        load()
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    /// At launch: the queue continues when the network and the settings allow.
    func start() {
        guard !started else { return }
        started = true
        let network = NetworkMonitor.shared
        Publishers.CombineLatest(network.$connection, network.$isExpensive)
            .map { "\($0.0.rawValue)-\($0.1)" }
            .removeDuplicates()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.conditionsChanged() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.conditionsChanged() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.becameActive() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.enteredBackground() }
            .store(in: &cancellables)
        updateEngineFlags()
        schedule()
    }

    // MARK: Queries

    var hasItems: Bool { !items.isEmpty }

    func item(hash: String, fileId: Int) -> DownloadItem? {
        let id = DownloadItem.identifier(hash: hash, fileId: fileId)
        return items.first { $0.id == id }
    }

    func items(for itemKey: String) -> [DownloadItem] {
        items.filter { $0.itemKey == itemKey }
    }

    func videoURL(for item: DownloadItem) -> URL {
        directory.appendingPathComponent(item.fileName)
    }

    private func subtitlesURL(for item: DownloadItem) -> URL {
        directory.appendingPathComponent(item.subtitlesFolder, isDirectory: true)
    }

    /// The saved file, when it is complete.
    func localURL(hash: String, fileId: Int) -> URL? {
        guard let item = item(hash: hash, fileId: fileId), item.state == .completed else { return nil }
        let url = videoURL(for: item)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func localSubtitleURLs(hash: String, fileId: Int) -> [URL] {
        guard let item = item(hash: hash, fileId: fileId), item.state == .completed else { return [] }
        let folder = subtitlesURL(for: item)
        return item.subtitleNames
            .map { folder.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func torrent(hash: String) -> DownloadTorrent? {
        torrents[hash.lowercased()]
    }

    /// The saved file list for a magnet link, a hash or a link to a .torrent file.
    func torrent(forLink link: String) -> DownloadTorrent? {
        let plain = LinkInspector.stripMarker(link).trimmed
        if let hash = LinkInspector.infoHash(of: plain)?.lowercased(), let found = torrents[hash] {
            return found
        }
        return torrents.values.first { LinkInspector.stripMarker($0.link).trimmed == plain }
    }

    func hasCompleted(hash: String) -> Bool {
        items.contains { $0.hash == hash.lowercased() && $0.state == .completed }
    }

    var usedBytes: Int64 {
        items.reduce(Int64(0)) { $0 + ($1.state == .completed ? $1.file.length : $1.received) }
    }

    var usedText: String {
        ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file)
    }

    var freeBytes: Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    var freeText: String? {
        freeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    var activeItem: DownloadItem? {
        guard let activeId else { return nil }
        return items.first { $0.id == activeId }
    }

    // MARK: Adding

    /// Adds files of a known torrent. Returns how many were added (or started again).
    @discardableResult
    func enqueue(files: [TorrentFile], all: [TorrentFile], hash: String, link: String, title: String,
                 item: MediaItem?, itemKey: String?, season: Int?) -> Int {
        let hash = hash.lowercased()
        remember(hash: hash, link: link, title: title, files: all)
        let isSeries = item?.kind == .series || files.count > 1
        var count = 0
        for file in files {
            let id = DownloadItem.identifier(hash: hash, fileId: file.id)
            if let index = items.firstIndex(where: { $0.id == id }) {
                if items[index].state == .failed || items[index].state == .paused {
                    items[index].state = .queued
                    items[index].error = nil
                    failures[id] = nil
                    count += 1
                }
                continue
            }
            let numbers = isSeries ? EpisodeMatcher.numbers(of: file) : nil
            let entry = DownloadItem(hash: hash, file: file, link: link, itemKey: itemKey, item: item, title: title,
                                     detail: DownloadManager.label(file, numbers: numbers, season: season),
                                     season: numbers?.season ?? (numbers != nil ? season : nil),
                                     episode: numbers?.episode, state: .queued, received: 0, error: nil,
                                     added: Date(), completed: nil,
                                     subtitleSources: DownloadSelection.subtitles(for: file, in: all),
                                     subtitleNames: [])
            items.append(entry)
            count += 1
        }
        if count > 0 {
            AppDiagnostics.shared.log("downloads", "В очередь: \(title), файлов \(count)")
        }
        persistNow()
        updateEngineFlags()
        schedule()
        return count
    }

    /// Opens the torrent of a release and adds the film, the episode, the season or all episodes.
    func enqueue(link: String, title: String, item: MediaItem?, itemKey: String?,
                 season: Int?, episode: Int?) async throws -> Int {
        try await TorrServer.shared.ensureRunning()
        let status = try await TorrServer.shared.add(link: LinkInspector.stripMarker(link), title: item?.title ?? title,
                                                     poster: item?.posterURL)
        guard let hash = status.hash?.nonEmpty else { throw TorrServerError.server("не удалось добавить торрент") }
        var all = status.files
        if all.isEmpty {
            all = try await TorrServer.shared.waitForFiles(hash: hash, timeout: 90) { _ in }
        }
        let files = DownloadSelection.files(all, isSeries: item?.kind == .series, season: season, episode: episode)
        guard !files.isEmpty else { throw TorrServerError.noVideo }
        return enqueue(files: files, all: all, hash: hash, link: link, title: item?.title ?? title,
                       item: item, itemKey: itemKey, season: season)
    }

    static func label(_ file: TorrentFile, numbers: (season: Int?, episode: Int)?, season: Int?) -> String {
        if let numbers {
            if let value = numbers.season ?? season { return "\(value) сезон, \(numbers.episode) серия" }
            return "\(numbers.episode) серия"
        }
        return (file.name as NSString).deletingPathExtension
    }

    // MARK: Control

    func pause(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].isUnfinished else { return }
        items[index].state = .paused
        if activeId == id { worker?.cancel() }
        persistNow()
        updateEngineFlags()
    }

    func resume(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].state == .paused || items[index].state == .failed else { return }
        items[index].state = .queued
        items[index].error = nil
        failures[id] = nil
        persistNow()
        updateEngineFlags()
        schedule()
    }

    func pauseAll() {
        for index in items.indices where items[index].isUnfinished {
            items[index].state = .paused
        }
        worker?.cancel()
        persistNow()
        updateEngineFlags()
    }

    func resumeAll() {
        for index in items.indices where items[index].state == .paused || items[index].state == .failed {
            items[index].state = .queued
            items[index].error = nil
        }
        failures = [:]
        persistNow()
        updateEngineFlags()
        schedule()
    }

    func remove(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: index)
        if activeId == id { worker?.cancel() }
        failures[id] = nil
        deleteFiles(of: item)
        if !items.contains(where: { $0.hash == item.hash }) {
            torrents[item.hash] = nil
        }
        AppDiagnostics.shared.log("downloads", "Удалено: \(item.title) · \(item.detail)")
        persistNow()
        updateEngineFlags()
    }

    func remove(group key: String) {
        for item in items where item.groupKey == key {
            remove(item.id)
        }
    }

    func removeAll() {
        worker?.cancel()
        let all = items
        items = []
        torrents = [:]
        failures = [:]
        for item in all { deleteFiles(of: item) }
        persistNow()
        updateEngineFlags()
    }

    private func deleteFiles(of item: DownloadItem) {
        let video = videoURL(for: item)
        let subtitles = subtitlesURL(for: item)
        // The transfer may still be closing the file: it is removed a moment later as well.
        try? FileManager.default.removeItem(at: video)
        try? FileManager.default.removeItem(at: subtitles)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, self.item(hash: item.hash, fileId: item.file.id) == nil else { return }
            try? FileManager.default.removeItem(at: video)
            try? FileManager.default.removeItem(at: subtitles)
        }
    }

    // MARK: Worker

    private var wifiOnly: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.downloadsWifiOnly) }
    private var pauseWhileWatching: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.downloadsPauseWhileWatching) }

    private var hasPending: Bool { items.contains { $0.isUnfinished } }

    private func blockedReason() -> String? {
        let network = NetworkMonitor.shared
        if network.connection == .offline { return "Нет сети" }
        if wifiOnly && (network.connection == .cellular || network.isExpensive) { return "Ждём Wi‑Fi" }
        if playerStreaming && pauseWhileWatching { return "На паузе, пока идёт просмотр" }
        return nil
    }

    private func conditionsChanged() {
        guard started else { return }
        if let reason = blockedReason() {
            worker?.cancel()
            waitingReason = hasPending ? reason : nil
        } else {
            schedule()
        }
        updateIdleTimer()
    }

    private func becameActive() {
        backgroundToken?.end()
        backgroundToken = nil
        // A transfer suspended with the app does not recover by itself.
        if worker != nil, Date().timeIntervalSince(lastProgressAt) > 20 {
            AppDiagnostics.shared.log("downloads", "Возобновление после возврата в приложение")
            worker?.cancel()
        } else {
            schedule()
        }
    }

    private func enteredBackground() {
        persistNow()
        if worker != nil, backgroundToken == nil {
            backgroundToken = BackgroundTaskToken.begin("Kinoteka downloads")
        }
    }

    private func schedule() {
        guard started, worker == nil else { return }
        guard hasPending else {
            waitingReason = nil
            return
        }
        if let reason = blockedReason() {
            waitingReason = reason
            return
        }
        waitingReason = nil
        workerGeneration += 1
        let generation = workerGeneration
        worker = Task { @MainActor [weak self] in
            await self?.runQueue()
            self?.workerFinished(generation)
        }
        updateIdleTimer()
    }

    private func workerFinished(_ generation: Int) {
        guard generation == workerGeneration else { return }
        worker = nil
        activeId = nil
        rate = 0
        samples = []
        backgroundToken?.end()
        backgroundToken = nil
        updateEngineFlags()
        updateIdleTimer()
        persistNow()
        // Conditions may have changed while it was stopping (a paused file, a new one).
        schedule()
    }

    private func runQueue() async {
        while !Task.isCancelled {
            if let reason = blockedReason() {
                waitingReason = reason
                return
            }
            guard let next = items.first(where: { $0.state == .downloading }) ?? items.first(where: { $0.state == .queued }) else {
                waitingReason = nil
                return
            }
            let id = next.id
            let startedWith = next.received
            activeId = id
            update(id) {
                $0.state = .downloading
                $0.error = nil
            }
            updateEngineFlags()
            lastProgressAt = Date()
            samples = []
            rate = 0
            do {
                try await download(id)
                failures[id] = nil
                update(id) {
                    $0.state = .completed
                    $0.completed = Date()
                    $0.error = nil
                    $0.received = $0.file.length
                }
                activeId = nil
                persistNow()
                updateEngineFlags()
                AppDiagnostics.shared.log("downloads", "Скачано: \(next.title) · \(next.detail)")
            } catch {
                activeId = nil
                rate = 0
                let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                if cancelled {
                    update(id) { if $0.state == .downloading { $0.state = .queued } }
                    persistNow()
                    if Task.isCancelled { return }
                    continue
                }
                let progressed = (item(id)?.received ?? 0) > startedWith + 1_048_576
                let count = (progressed ? 0 : failures[id] ?? 0) + 1
                failures[id] = count
                let text = error.localizedDescription
                AppDiagnostics.shared.log("downloads", "Ошибка загрузки (\(count)): \(text)")
                if DownloadManager.isPermanent(error) || count >= 5 {
                    update(id) {
                        $0.state = .failed
                        $0.error = text
                    }
                    persistNow()
                    updateEngineFlags()
                    continue
                }
                update(id) {
                    $0.state = .queued
                    $0.error = "\(text). Повтор…"
                }
                try? await Task.sleep(seconds: Double(min(60, 5 * count * count)))
            }
        }
    }

    private static func isPermanent(_ error: Error) -> Bool {
        if let failure = error as? RangeDownload.Failure, case .noSpace = failure { return true }
        if let failure = error as? Failure {
            switch failure {
            case .fileMissing, .noSpace: return true
            case .incomplete: return false
            }
        }
        if let failure = error as? TorrServerError, case .noVideo = failure { return true }
        return false
    }

    private func download(_ id: String) async throws {
        guard let item = item(id) else { throw CancellationError() }
        try await TorrServer.shared.ensureRunning()
        try Task.checkCancellation()
        let status = try await TorrServer.shared.add(link: LinkInspector.stripMarker(item.link),
                                                     title: item.item?.title ?? item.title,
                                                     poster: item.item?.posterURL)
        try Task.checkCancellation()
        let hash = (status.hash?.nonEmpty ?? item.hash).lowercased()
        var all = status.files
        if all.isEmpty {
            all = try await TorrServer.shared.waitForFiles(hash: hash, timeout: 180) { _ in }
        }
        try Task.checkCancellation()
        guard let file = all.first(where: { $0.id == item.file.id && $0.path == item.file.path })
                ?? all.first(where: { $0.path == item.file.path }),
              let url = TorrServer.shared.streamURL(hash: hash, file: file) else {
            throw Failure.fileMissing
        }
        remember(hash: hash, link: item.link, title: item.title, files: all)
        let destination = videoURL(for: item)
        let existing = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        let remaining = max(0, file.length - existing)
        if let free = freeBytes, free < remaining + reserve {
            throw Failure.noSpace(remaining + reserve - free)
        }
        update(id) { $0.received = existing }
        AppDiagnostics.shared.log("downloads", "Загрузка \(item.title) · \(item.detail) с \(existing / 1_048_576) МБ")
        let transfer = RangeDownload(url: url, destination: destination, expectedLength: file.length) { [weak self] bytes in
            Task { @MainActor [weak self] in self?.progress(id, bytes) }
        }
        let total = try await transfer.run()
        progress(id, total)
        if file.length > 0, total < file.length { throw Failure.incomplete }
        await downloadSubtitles(id, hash: hash)
    }

    private func downloadSubtitles(_ id: String, hash: String) async {
        guard let item = item(id), !item.subtitleSources.isEmpty else { return }
        let folder = subtitlesURL(for: item)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var names: [String] = []
        for source in item.subtitleSources {
            guard !Task.isCancelled, let url = TorrServer.shared.streamURL(hash: hash, file: source) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (data, response) = try? await smallSession.data(for: request),
                  ((response as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2, !data.isEmpty else { continue }
            var name = DownloadManager.safeName(source.name)
            if names.contains(name) { name = "\(names.count + 1) \(name)" }
            if (try? data.write(to: folder.appendingPathComponent(name), options: .atomic)) != nil {
                names.append(name)
            }
        }
        update(id) { $0.subtitleNames = names }
    }

    static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return cleaned.isEmpty ? "subtitles.srt" : cleaned
    }

    private func progress(_ id: String, _ bytes: Int64) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if items[index].received != bytes { items[index].received = bytes }
        let now = Date()
        lastProgressAt = now
        if let last = samples.last, bytes < last.bytes { samples = [] }
        samples.append((now, bytes))
        samples.removeAll { now.timeIntervalSince($0.date) > 3 }
        if let first = samples.first {
            let span = now.timeIntervalSince(first.date)
            rate = span > 0.4 ? max(0, Double(bytes - first.bytes) / span) : rate
        }
        if now.timeIntervalSince(lastPersist) > 15 { persistNow() }
    }

    private func item(_ id: String) -> DownloadItem? {
        items.first { $0.id == id }
    }

    private func update(_ id: String, _ change: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private func remember(hash: String, link: String, title: String, files: [TorrentFile]) {
        guard !files.isEmpty else { return }
        let key = hash.lowercased()
        if torrents[key]?.files == files, torrents[key]?.link == link { return }
        torrents[key] = DownloadTorrent(hash: key, link: link, title: title, files: files)
    }

    private func updateEngineFlags() {
        TorrServer.shared.setDownloadsActive(activeId != nil)
        TorrServer.shared.setPinned(Set(items.filter(\.isUnfinished).map(\.hash)))
    }

    private func updateIdleTimer() {
        let keepAwake = UserDefaults.standard.bool(forKey: SettingsKeys.downloadsKeepAwake)
        IdleTimer.set("downloads", active: keepAwake && worker != nil)
    }

    // MARK: Storage

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(DownloadIndex.self, from: data) else { return }
        let manager = FileManager.default
        items = index.items.uniqued(by: \.id).map { stored in
            var item = stored
            if item.state == .downloading { item.state = .queued }
            if item.state == .completed, !manager.fileExists(atPath: directory.appendingPathComponent(item.fileName).path) {
                item.state = .failed
                item.received = 0
                item.error = "Файл не найден, скачайте заново"
            }
            return item
        }
        torrents = Dictionary(index.torrents.map { ($0.hash.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func persistNow() {
        lastPersist = Date()
        let index = DownloadIndex(items: items, torrents: Array(torrents.values))
        let url = indexURL
        DownloadManager.ioQueue.async {
            guard let data = try? JSONEncoder().encode(index) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
