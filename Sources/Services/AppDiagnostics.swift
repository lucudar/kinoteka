import Foundation
import MetricKit

/// A small local ring log plus MetricKit crash/hang reports. The user explicitly
/// exports the report from Settings; nothing is uploaded automatically.
final class AppDiagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = AppDiagnostics()

    private let queue = DispatchQueue(label: "kinoteka.diagnostics", qos: .utility)
    private let logURL: URL
    private let metricsDirectory: URL
    private var started = false

    private override init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logURL = dir.appendingPathComponent("events.log")
        metricsDirectory = dir.appendingPathComponent("MetricKit", isDirectory: true)
        try? FileManager.default.createDirectory(at: metricsDirectory, withIntermediateDirectories: true)
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
        log("app", "Запуск \(AppInfo.version)")
    }

    func log(_ category: String, _ message: String) {
        let safe = message
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(800)
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) [\(category)] \(safe)\n"
        queue.async { [logURL] in
            Self.trimIfNeeded(logURL)
            let data = Data(line.utf8)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                try? data.write(to: logURL, options: .atomic)
            } else if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }

    var sizeText: String {
        queue.sync {
            let manager = FileManager.default
            let log = ((try? manager.attributesOfItem(atPath: logURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
            let metricFiles = (try? manager.contentsOfDirectory(at: metricsDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let metrics = metricFiles.reduce(Int64(0)) {
                $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            return ByteCountFormatter.string(fromByteCount: log + metrics, countStyle: .file)
        }
    }

    func exportURL() -> URL {
        queue.sync {
            let target = FileManager.default.temporaryDirectory.appendingPathComponent("Kinoteka-diagnostics.txt")
            var report = """
            Кинотека \(AppInfo.version)
            Устройство: \(ProcessInfo.processInfo.operatingSystemVersionString)
            Дата: \(ISO8601DateFormatter().string(from: Date()))

            === СОБЫТИЯ ===
            """
            if let text = try? String(contentsOf: logURL, encoding: .utf8) {
                report += "\n" + text
            } else {
                report += "\nЖурнал пуст.\n"
            }
            let metricFiles = (try? FileManager.default.contentsOfDirectory(at: metricsDirectory,
                                                                            includingPropertiesForKeys: nil)) ?? []
            for file in metricFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).suffix(5) {
                report += "\n=== METRICKIT \(file.lastPathComponent) ===\n"
                report += (try? String(contentsOf: file, encoding: .utf8)) ?? "Не удалось прочитать.\n"
            }
            try? Data(report.utf8).write(to: target, options: .atomic)
            return target
        }
    }

    func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: logURL)
            let files = (try? FileManager.default.contentsOfDirectory(at: metricsDirectory,
                                                                      includingPropertiesForKeys: nil)) ?? []
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
        log("diagnostics", "Журнал очищен")
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        queue.async { [metricsDirectory] in
            for payload in payloads {
                let name = "diagnostic-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).json"
                let target = metricsDirectory.appendingPathComponent(name)
                try? payload.jsonRepresentation().write(to: target, options: .atomic)
            }
        }
    }

    private static func trimIfNeeded(_ url: URL) {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
        guard size > 700_000, let data = try? Data(contentsOf: url) else { return }
        let tail = data.suffix(400_000)
        try? Data(tail).write(to: url, options: .atomic)
    }
}