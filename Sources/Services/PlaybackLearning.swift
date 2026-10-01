import Foundation

private struct PlaybackStat: Codable {
    var successes = 0
    var failures = 0
    var averageStartupMs: Double = 0
    var lastUsed = Date.distantPast

    mutating func success(startupMs: Double) {
        successes += 1
        averageStartupMs = successes == 1
            ? startupMs
            : (averageStartupMs * Double(successes - 1) + startupMs) / Double(successes)
        lastUsed = Date()
    }

    mutating func failure() {
        failures += 1
        lastUsed = Date()
    }

    var bonus: Double {
        let reliability = Double(successes) * 2.5 - Double(failures) * 2
        let speed = averageStartupMs > 0 ? max(-3, min(5, (12_000 - averageStartupMs) / 2_000)) : 0
        return max(-12, min(16, reliability + speed))
    }
}

private struct PlaybackLearningData: Codable {
    var releases: [String: PlaybackStat] = [:]
    var trackers: [String: PlaybackStat] = [:]
    var audioByTitle: [String: String] = [:]
}

/// Learns only from playback on this device. No history or diagnostics leave the iPhone.
@MainActor
final class PlaybackLearning {
    static let shared = PlaybackLearning()

    private var data = PlaybackLearningData()
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("playback-learning.json")
        if let raw = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(PlaybackLearningData.self, from: raw) {
            data = decoded
        }
    }

    func preferredAudio(for itemKey: String?) -> String? {
        guard let itemKey = itemKey else { return nil }
        return data.audioByTitle[itemKey]?.nonEmpty
    }

    func rememberAudio(_ name: String, for itemKey: String?) {
        guard let itemKey = itemKey, let value = name.nonEmpty else { return }
        data.audioByTitle[itemKey] = value
        scheduleSave()
    }

    func recordSuccess(_ release: TorrentRelease?, startupMs: Double) {
        guard let release = release else { return }
        var releaseStat = data.releases[release.id] ?? PlaybackStat()
        releaseStat.success(startupMs: startupMs)
        data.releases[release.id] = releaseStat
        for tracker in release.trackers {
            var trackerStat = data.trackers[tracker.lowercased()] ?? PlaybackStat()
            trackerStat.success(startupMs: startupMs)
            data.trackers[tracker.lowercased()] = trackerStat
        }
        scheduleSave()
    }

    func recordFailure(_ release: TorrentRelease?) {
        guard let release = release else { return }
        var releaseStat = data.releases[release.id] ?? PlaybackStat()
        releaseStat.failure()
        data.releases[release.id] = releaseStat
        for tracker in release.trackers {
            var trackerStat = data.trackers[tracker.lowercased()] ?? PlaybackStat()
            trackerStat.failure()
            data.trackers[tracker.lowercased()] = trackerStat
        }
        scheduleSave()
    }

    func candidates(_ list: [TorrentRelease],
                    preferred: ReleaseQuality,
                    season: Int?,
                    voice: ReleaseVoiceOption? = nil,
                    ceiling: ReleaseQuality? = nil) -> [TorrentRelease] {
        var candidates = ReleaseRanking.matching(list, season: season)
            .filter { $0.seeders > 0 && !$0.isCamRip }
        if let voice = voice {
            let voiced = ReleaseRanking.matching(candidates, voice: voice)
            if !voiced.isEmpty { candidates = voiced }
        }
        if let ceiling = ceiling {
            let limited = candidates.filter { $0.quality == .unknown || $0.quality <= ceiling }
            if !limited.isEmpty { candidates = limited }
        }
        return candidates.sorted {
            learnedScore($0, preferred: preferred, season: season) >
            learnedScore($1, preferred: preferred, season: season)
        }
    }

    func best(_ list: [TorrentRelease],
              preferred: ReleaseQuality,
              season: Int?,
              voice: ReleaseVoiceOption? = nil) -> TorrentRelease? {
        candidates(list, preferred: preferred, season: season, voice: voice).first
    }

    private func learnedScore(_ release: TorrentRelease,
                              preferred: ReleaseQuality,
                              season: Int?) -> Double {
        var value = ReleaseRanking.score(release, preferred: preferred, season: season)
        value += data.releases[release.id]?.bonus ?? 0
        let trackerBonus = release.trackers.compactMap { data.trackers[$0.lowercased()]?.bonus }.max() ?? 0
        value += trackerBonus * 0.35
        return value
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self = self,
                  let raw = try? JSONEncoder().encode(self.data) else { return }
            try? raw.write(to: self.fileURL, options: .atomic)
        }
    }
}