import SwiftUI

/// Live numbers of the playing torrent in the player settings: they show whether a slow start
/// comes from the release (few peers) or from the network (many peers, low speed).
struct TorrentStatsSection: View {
    let hash: String

    @State private var status: TSStatus?
    @State private var failed = false

    var body: some View {
        Section {
            if let status = status {
                LabeledContent("Скорость", value: status.speedText)
                LabeledContent("Пиры", value: "\(status.activePeers ?? 0) из \(status.totalPeers ?? 0)")
                LabeledContent("Сиды", value: "\(status.connectedSeeders ?? 0)")
                LabeledContent("В кэше", value: status.cachedText)
                if (status.uploadSpeed ?? 0) > 1024 {
                    LabeledContent("Отдача", value: status.uploadText)
                }
            } else if failed {
                Text("Движок не ответил")
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Загрузка…")
                        .foregroundStyle(.secondary)
                }
            }
            if let profile = TorrServer.shared.activeProfile {
                Text(profile.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Торрент")
        } footer: {
            Text("Мало пиров — выберите раздачу, где больше сидов. Пиров много, а скорость ниже нужной — ограничивает сеть: попробуйте Wi‑Fi или включите «Шифрование трафика» в настройках.")
        }
        .task(id: hash) { await poll() }
    }

    private func poll() async {
        while !Task.isCancelled {
            do {
                status = try await TorrServer.shared.get(hash: hash)
                failed = false
            } catch {
                if Task.isCancelled { return }
                failed = status == nil
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }
}
