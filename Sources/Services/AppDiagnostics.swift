import Foundation
import MetricKit
import UIKit
import os

/// Local diagnostics: a ring log of events, crash and hang reports from MetricKit,
/// the state of the previous run (to notice that it ended abnormally), uncaught
/// Objective-C exceptions and the TorrServer log (Go panics and Swift runtime errors
/// are written there). Nothing is uploaded: the user shares the report explicitly.
final class AppDiagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = AppDiagnostics()

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    /// Written by the uncaught exception handler, read on the next launch.
    static var exceptionURL: URL { directory.appendingPathComponent("exception.txt") }

    private let queue = DispatchQueue(label: "kinoteka.diagnostics", qos: .utility)
    private let logURL: URL
    private let metricsDirectory: URL
    private let sessionURL: URL
    private let incidentsURL: URL
    private let lastExceptionURL: URL
    private let engineCrashURL: URL
    /// Problems not yet shown to the user (the app may have ended before it could show them).
    private let pendingURL: URL
    /// Used only on `queue`.
    private let stamp: ISO8601DateFormatter
    private var started = false

    private let stateLock = NSLock()
    private var session = SessionState()
    /// The session file is written only once the app has been on screen: iOS may launch
    /// ("prewarm") the process in advance and end it without it ever becoming active.
    private var sessionActive = false
    private var appActive = false
    /// State of the previous run, read on launch and analyzed on the first activation.
    private var previousSession: SessionState?
    private var previousException: String?
    /// Used only on `queue`.
    private var analyzed = false
    /// The last events of the previous run (used only on `queue`).
    private var previousEvents: [String] = []
    private var pingPending = false
    private var pingSentAt: TimeInterval = 0
    private var sessionWritePending = false
    private var sampler: DispatchSourceTimer?
    private var samplerTicks = 0

    /// What the app was doing; read on the next launch.
    private struct SessionState: Codable {
        var version = ""
        var started = Date()
        var updated = Date()
        /// launch, active, inactive, background, terminated
        var phase = "launch"
        var playing: String?
        var footprintMB: Int?
        var availableMB: Int?
        var hangSeconds: Int?
    }

    private override init() {
        let dir = AppDiagnostics.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logURL = dir.appendingPathComponent("events.log")
        metricsDirectory = dir.appendingPathComponent("MetricKit", isDirectory: true)
        sessionURL = dir.appendingPathComponent("session.json")
        incidentsURL = dir.appendingPathComponent("incidents.log")
        lastExceptionURL = dir.appendingPathComponent("last-exception.txt")
        engineCrashURL = dir.appendingPathComponent("engine-crash.txt")
        pendingURL = dir.appendingPathComponent("pending-notice.json")
        try? FileManager.default.createDirectory(at: metricsDirectory, withIntermediateDirectories: true)
        stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        stamp.timeZone = .current
        super.init()
    }

    // MARK: Start

    @MainActor
    func start() {
        guard !started else { return }
        started = true
        NSSetUncaughtExceptionHandler { exception in
            AppDiagnostics.recordUncaughtException(exception)
        }

        // State of the previous run. It is analyzed (and the file overwritten) only when the
        // app becomes active, so a process that iOS started in advance changes nothing.
        let previous = (try? Data(contentsOf: sessionURL)).flatMap { try? JSONDecoder().decode(SessionState.self, from: $0) }
        let exception = try? String(contentsOf: AppDiagnostics.exceptionURL, encoding: .utf8)

        stateLock.lock()
        previousSession = previous
        previousException = exception
        session = SessionState()
        session.version = AppInfo.version
        session.phase = "launch"
        stateLock.unlock()

        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setPhase("active")
        }
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setPhase("inactive")
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setPhase("background")
        }
        center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setPhase("terminated")
        }

        // Read before this run adds its own events.
        queue.async { [weak self] in
            guard let self = self else { return }
            self.previousEvents = self.lastLogLines(5)
        }
        MXMetricManager.shared.add(self)
        startHangMonitor()
        startMemorySampler()
        log("app", "Запуск \(AppInfo.version) · \(ProcessInfo.processInfo.operatingSystemVersionString) · \(AppDiagnostics.deviceModel) · \(AppDiagnostics.memorySummary())")
    }

    /// On `queue`, at every activation: the first one analyzes the previous run.
    private func activated() {
        if !analyzed {
            analyzed = true
            stateLock.lock()
            let previous = previousSession
            let exception = previousException
            previousSession = nil
            previousException = nil
            stateLock.unlock()
            if exception != nil {
                try? FileManager.default.removeItem(at: lastExceptionURL)
                try? FileManager.default.moveItem(at: AppDiagnostics.exceptionURL, to: lastExceptionURL)
            }
            analyzePreviousRun(previous, exception: exception)
        }
        offerPending()
    }

    private func analyzePreviousRun(_ previous: SessionState?, exception: String?) {
        var lines: [String] = []
        if let exception = exception {
            let first = exception.split(separator: "\n").first.map(String.init) ?? exception
            lines.append("Необработанное исключение: " + String(first.prefix(300)))
        }
        if let previous = previous, previous.version == AppInfo.version {
            // After an update the previous run was ended by the installation, not by a crash.
            if previous.phase == "launch" || previous.phase == "active" {
                var text = "Прошлый запуск неожиданно завершился, когда приложение было на экране"
                if let playing = previous.playing { text += " (шло воспроизведение «\(playing)»)" }
                lines.append(text + ".")
                if let hang = previous.hangSeconds {
                    lines.append("Перед этим главный поток не отвечал \(hang) с — похоже на зависание.")
                }
                if let used = previous.footprintMB {
                    lines.append("Память приложения перед этим: \(used) МБ, до лимита оставалось \(previous.availableMB ?? 0) МБ.")
                }
            } else if previous.phase == "background", let playing = previous.playing {
                appendLog("session", "Прошлый сеанс закончился в фоне во время воспроизведения «\(playing)» (iOS могла выгрузить приложение из-за памяти); память: \(previous.footprintMB ?? 0) МБ")
            }
        }
        if !lines.isEmpty {
            if !previousEvents.isEmpty {
                lines.append("Последние события: " + previousEvents.joined(separator: " | "))
            }
            report(lines)
        }
    }

    // MARK: Session state

    private func setPhase(_ phase: String) {
        stateLock.lock()
        session.phase = phase
        appActive = phase == "active"
        if appActive { sessionActive = true }
        if !appActive { pingPending = false }
        stateLock.unlock()
        if phase == "active" {
            queue.async { [weak self] in self?.activated() }
        }
        writeSessionNow()
        switch phase {
        case "active": log("app", "Приложение активно")
        case "background": log("app", "Приложение ушло в фон · \(AppDiagnostics.memorySummary())")
        default: break
        }
    }

    /// Title of what is playing now; nil when the player is closed.
    func setPlayback(_ title: String?) {
        stateLock.lock()
        let changed = session.playing != title
        session.playing = title
        stateLock.unlock()
        if changed { writeSessionNow() }
    }

    private func writeSessionNow() {
        stateLock.lock()
        guard sessionActive else {
            stateLock.unlock()
            return
        }
        session.updated = Date()
        let snapshot = session
        stateLock.unlock()
        queue.async { [sessionURL] in
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: sessionURL, options: .atomic)
            }
        }
    }

    private func updateMemoryInSession() {
        let used = Int(AppDiagnostics.footprintBytes() / 1_048_576)
        let available = AppDiagnostics.availableBytes() / 1_048_576
        stateLock.lock()
        session.footprintMB = used
        session.availableMB = available
        stateLock.unlock()
        writeSessionNow()
    }

    private func startMemorySampler() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 20, repeating: 30, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.samplerTicks += 1
            self.updateMemoryInSession()
            self.stateLock.lock()
            let playing = self.session.playing
            self.stateLock.unlock()
            if playing != nil && self.samplerTicks % 10 == 0 {
                self.appendLog("memory", AppDiagnostics.memorySummary())
            }
        }
        timer.resume()
        sampler = timer
    }

    // MARK: Main thread hangs

    private func startHangMonitor() {
        let thread = Thread { [weak self] in
            self?.monitorMainThread()
        }
        thread.name = "kinoteka.hang-monitor"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Logs when the main thread stops answering while the app is on screen. If iOS
    /// then kills the app, the next launch knows it was a hang.
    private func monitorMainThread() {
        var last = ProcessInfo.processInfo.systemUptime
        var reported = 0
        while true {
            Thread.sleep(forTimeInterval: 1)
            let now = ProcessInfo.processInfo.systemUptime
            let gap = now - last
            last = now
            stateLock.lock()
            let active = appActive
            let pending = pingPending
            let sentAt = pingSentAt
            stateLock.unlock()
            guard active, gap < 3 else {
                // Suspended or in the background: a delay there is not a hang.
                stateLock.lock()
                pingPending = false
                stateLock.unlock()
                if reported > 0 { clearHang() }
                reported = 0
                continue
            }
            if pending {
                let blocked = Int(now - sentAt)
                if blocked >= 4 && blocked >= reported + 4 {
                    reported = blocked
                    hangDetected(seconds: blocked)
                }
            } else {
                if reported > 0 {
                    log("hang", "Главный поток снова отвечает (был занят не меньше \(reported) с)")
                    clearHang()
                    reported = 0
                }
                stateLock.lock()
                pingPending = true
                pingSentAt = now
                stateLock.unlock()
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.stateLock.lock()
                    self.pingPending = false
                    self.stateLock.unlock()
                }
            }
        }
    }

    private func hangDetected(seconds: Int) {
        stateLock.lock()
        session.hangSeconds = seconds
        stateLock.unlock()
        writeSessionNow()
        log("hang", "Главный поток не отвечает \(seconds) с · \(AppDiagnostics.memorySummary())")
    }

    private func clearHang() {
        stateLock.lock()
        let had = session.hangSeconds != nil
        session.hangSeconds = nil
        stateLock.unlock()
        if had { writeSessionNow() }
    }

    // MARK: Exceptions and engine crashes

    /// Runs inside the uncaught exception handler: writes synchronously.
    static func recordUncaughtException(_ exception: NSException) {
        var text = "\(Date()) \(exception.name.rawValue): \(exception.reason ?? "")\n"
        text += exception.callStackSymbols.prefix(80).joined(separator: "\n")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: exceptionURL, options: .atomic)
    }

    /// A Go panic or a Swift runtime error found in the TorrServer log of the previous run.
    func saveEngineCrash(_ excerpt: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            try? Data(excerpt.utf8).write(to: self.engineCrashURL, options: .atomic)
            let first = excerpt
                .split(separator: "\n")
                .first { line in EngineLog.crashMarkers.contains { line.contains($0) } }
                .map(String.init) ?? "ошибка"
            self.report(["В журнале торрент-движка найден сбой прошлого запуска: " + String(first.prefix(300))])
        }
    }

    /// Must be called on `queue`.
    private func report(_ lines: [String]) {
        let date = stamp.string(from: Date())
        let text = lines.map { "\(date) \($0)\n" }.joined()
        appendData(Data(text.utf8), to: incidentsURL)
        for line in lines { appendLog("incident", line) }
        var pending = readPending()
        for line in lines where !pending.contains(line) {
            pending.append(line)
        }
        writePending(Array(pending.suffix(20)))
        offerPending()
    }

    /// On `queue`: shows the problems not seen yet, when the app is on screen.
    private func offerPending() {
        let pending = readPending()
        guard !pending.isEmpty else { return }
        stateLock.lock()
        let active = appActive
        stateLock.unlock()
        guard active else { return }
        Task { @MainActor in
            DiagnosticsNotice.shared.add(pending)
        }
    }

    private func readPending() -> [String] {
        guard let data = try? Data(contentsOf: pendingURL),
              let lines = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return lines
    }

    private func writePending(_ lines: [String]) {
        if let data = try? JSONEncoder().encode(lines) {
            try? data.write(to: pendingURL, options: .atomic)
        }
    }

    /// The user has seen the problems (closed the sheet).
    func clearPendingNotice() {
        queue.async { [weak self] in
            guard let self = self else { return }
            try? FileManager.default.removeItem(at: self.pendingURL)
        }
    }

    // MARK: Event log

    func log(_ category: String, _ message: String) {
        let safe = String(message.replacingOccurrences(of: "\n", with: " ").prefix(800))
        let date = Date()
        queue.async { [weak self] in
            self?.appendLog(category, safe, date: date)
        }
    }

    /// Must be called on `queue`.
    private func appendLog(_ category: String, _ message: String, date: Date = Date()) {
        let line = "\(stamp.string(from: date)) [\(category)] \(message)\n"
        AppDiagnostics.trimIfNeeded(logURL, limit: 700_000, keep: 400_000)
        appendData(Data(line.utf8), to: logURL)
    }

    private func appendData(_ data: Data, to url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
        } else if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    /// Must be called on `queue`.
    private func lastLogLines(_ count: Int) -> [String] {
        guard let tail = EngineLog.readTail(of: logURL, bytes: 4096) else { return [] }
        let lines = String(decoding: tail, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.contains("[incident]") }
        return Array(lines.suffix(count))
    }

    var sizeText: String {
        queue.sync {
            let manager = FileManager.default
            let files = (try? manager.contentsOfDirectory(at: AppDiagnostics.directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let metricFiles = (try? manager.contentsOfDirectory(at: metricsDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let total = (files + metricFiles).reduce(Int64(0)) {
                $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        }
    }

    // MARK: Report

    /// Builds the report file off the main thread.
    func prepareReport() async -> URL {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL, Never>) in
            queue.async {
                continuation.resume(returning: self.buildReport())
            }
        }
    }

    /// Must be called on `queue`.
    private func buildReport() -> URL {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("Kinoteka-diagnostics.txt")
        var report = """
        Кинотека \(AppInfo.version)
        Система: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Устройство: \(AppDiagnostics.deviceModel)
        Дата: \(stamp.string(from: Date()))
        Сейчас: \(AppDiagnostics.memorySummary())

        """
        func section(_ title: String, _ url: URL, tail: Int? = nil) {
            let data: Data?
            if let tail = tail {
                data = EngineLog.readTail(of: url, bytes: tail)
            } else {
                data = try? Data(contentsOf: url)
            }
            guard let data = data, !data.isEmpty else { return }
            report += "\n=== \(title) ===\n" + String(decoding: data, as: UTF8.self) + "\n"
        }
        section("ПРОБЛЕМЫ ПРОШЛЫХ ЗАПУСКОВ", incidentsURL, tail: 16_000)
        section("ИСКЛЮЧЕНИЕ ПРОШЛОГО ЗАПУСКА", lastExceptionURL)
        section("СБОЙ ТОРРЕНТ-ДВИЖКА", engineCrashURL)
        section("СОБЫТИЯ", logURL)
        section("ЖУРНАЛ ТОРРЕНТ-ДВИЖКА (КОНЕЦ)", TorrServer.logFile, tail: 48_000)
        let metricFiles = ((try? FileManager.default.contentsOfDirectory(at: metricsDirectory, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in metricFiles.filter({ $0.lastPathComponent.hasPrefix("diagnostic-") }).suffix(5) {
            section("METRICKIT \(file.lastPathComponent)", file)
        }
        for file in metricFiles.filter({ $0.lastPathComponent.hasPrefix("metrics-") }).suffix(2) {
            section("METRICKIT \(file.lastPathComponent)", file)
        }
        try? Data(report.utf8).write(to: target, options: .atomic)
        return target
    }

    func clear() {
        queue.sync {
            let manager = FileManager.default
            for url in [logURL, incidentsURL, lastExceptionURL, engineCrashURL, pendingURL] {
                try? manager.removeItem(at: url)
            }
            let files = (try? manager.contentsOfDirectory(at: metricsDirectory, includingPropertiesForKeys: nil)) ?? []
            for file in files { try? manager.removeItem(at: file) }
        }
        log("diagnostics", "Журнал очищен")
    }

    // MARK: MetricKit

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var lines: [String] = []
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                lines.append("iOS сообщила о сбое: " + AppDiagnostics.describe(crash))
            }
            for hang in payload.hangDiagnostics ?? [] {
                // Short hangs are only kept in the report file.
                let seconds = Int(hang.hangDuration.converted(to: .seconds).value)
                if seconds >= 2 {
                    lines.append("iOS сообщила о зависании на \(seconds) с (сборка \(hang.metaData.applicationBuildVersion))")
                }
            }
        }
        let files = payloads.map { $0.jsonRepresentation() }
        queue.async { [weak self] in
            guard let self = self else { return }
            for json in files {
                let name = "diagnostic-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).json"
                try? json.write(to: self.metricsDirectory.appendingPathComponent(name), options: .atomic)
            }
            self.pruneMetrics(prefix: "diagnostic-", keep: 12)
            if !lines.isEmpty { self.report(lines) }
        }
    }

    /// Daily metrics: among others, how often iOS ended the app and why
    /// (memory limit, watchdog, crash).
    func didReceive(_ payloads: [MXMetricPayload]) {
        let files = payloads.map { $0.jsonRepresentation() }
        queue.async { [weak self] in
            guard let self = self else { return }
            for json in files {
                let name = "metrics-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).json"
                try? json.write(to: self.metricsDirectory.appendingPathComponent(name), options: .atomic)
            }
            self.pruneMetrics(prefix: "metrics-", keep: 4)
        }
    }

    private func pruneMetrics(prefix: String, keep: Int) {
        let files = ((try? FileManager.default.contentsOfDirectory(at: metricsDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files.dropLast(keep) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func describe(_ crash: MXCrashDiagnostic) -> String {
        var parts: [String] = []
        if let signal = crash.signal { parts.append("сигнал \(signal)") }
        if let type = crash.exceptionType { parts.append("исключение \(type)") }
        if let code = crash.exceptionCode { parts.append("код \(code)") }
        if let reason = crash.terminationReason, !reason.isEmpty { parts.append(String(reason.prefix(200))) }
        parts.append("сборка \(crash.metaData.applicationBuildVersion)")
        return parts.joined(separator: ", ")
    }

    // MARK: Memory and device

    /// Memory iOS counts against the app's limit.
    static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// How much more the app may use before iOS terminates it.
    static func availableBytes() -> Int {
        max(0, os_proc_available_memory())
    }

    static func memorySummary() -> String {
        let used = ByteCountFormatter.string(fromByteCount: Int64(clamping: footprintBytes()), countStyle: .memory)
        let free = ByteCountFormatter.string(fromByteCount: Int64(availableBytes()), countStyle: .memory)
        return "память \(used), до лимита \(free)"
    }

    static let deviceModel: String = {
        var info = utsname()
        uname(&info)
        let bytes = Mirror(reflecting: info.machine).children.compactMap { child -> UInt8? in
            guard let value = child.value as? Int8, value != 0 else { return nil }
            return UInt8(bitPattern: value)
        }
        return String(decoding: bytes, as: UTF8.self)
    }()

    private static func trimIfNeeded(_ url: URL, limit: Int, keep: Int) {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
        guard size > limit, let tail = EngineLog.readTail(of: url, bytes: keep) else { return }
        try? tail.write(to: url, options: .atomic)
    }
}

/// The TorrServer log of the previous run, read before the engine opens it again.
enum EngineLog {
    /// Lines that start a Go panic or a Swift runtime error.
    static let crashMarkers = ["panic:", "fatal error:", "Fatal error:", "SIGSEGV", "SIGBUS", "unexpected signal"]

    static func inspectPreviousRun(_ url: URL) {
        if let tail = readTail(of: url, bytes: 384 * 1024) {
            let text = String(decoding: tail, as: UTF8.self)
            // Only what was written after the last start of the engine.
            let run: Substring
            if let range = text.range(of: "Start TorrServer", options: .backwards) {
                run = text[range.lowerBound...]
            } else {
                run = text[...]
            }
            if let excerpt = crashExcerpt(in: String(run)) {
                AppDiagnostics.shared.saveEngineCrash(excerpt)
            }
        }
        trim(url, limit: 8 * 1024 * 1024, keep: 1024 * 1024)
        trim(url.deletingLastPathComponent().appendingPathComponent("web.log"), limit: 4 * 1024 * 1024, keep: 256 * 1024)
    }

    /// The lines around the first crash marker.
    static func crashExcerpt(in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { line in crashMarkers.contains { line.contains($0) } }) else {
            return nil
        }
        let from = max(0, index - 5)
        let to = min(lines.count, index + 80)
        guard from < to else { return nil }
        return lines[from..<to].joined(separator: "\n")
    }

    static func readTail(of url: URL, bytes: Int) -> Data? {
        guard bytes > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let count = UInt64(bytes)
        let start = end > count ? end - count : 0
        guard (try? handle.seek(toOffset: start)) != nil else { return nil }
        return try? handle.readToEnd()
    }

    private static func trim(_ url: URL, limit: Int, keep: Int) {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
        guard size > limit, let tail = readTail(of: url, bytes: keep) else { return }
        try? tail.write(to: url, options: .atomic)
    }
}

/// Offers to share the report after the previous run ended badly.
@MainActor
final class DiagnosticsNotice: ObservableObject {
    static let shared = DiagnosticsNotice()

    @Published private(set) var lines: [String] = []
    @Published var isPresented = false
    private var shown = Set<String>()

    func add(_ newLines: [String]) {
        let fresh = newLines.filter { !shown.contains($0) }
        guard !fresh.isEmpty else { return }
        shown.formUnion(fresh)
        if isPresented {
            lines += fresh
        } else {
            lines = fresh
            isPresented = true
        }
    }

    func dismiss() {
        isPresented = false
        AppDiagnostics.shared.clearPendingNotice()
    }
}
