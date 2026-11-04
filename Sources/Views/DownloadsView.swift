import SwiftUI

/// Films and episodes saved on the iPhone: progress, pause, deletion and offline playback.
struct DownloadsView: View {
    @ObservedObject private var downloads = DownloadManager.shared
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @AppStorage(SettingsKeys.downloadsKeepAwake) private var keepAwake = false
    @AppStorage(SettingsKeys.downloadsWifiOnly) private var wifiOnly = true
    @State private var confirmDeleteAll = false

    private struct DownloadGroup: Identifiable {
        let id: String
        let title: String
        let rows: [DownloadItem]
    }

    private var groups: [DownloadGroup] {
        var order: [String] = []
        var map: [String: [DownloadItem]] = [:]
        for item in downloads.items {
            if map[item.groupKey] == nil { order.append(item.groupKey) }
            map[item.groupKey, default: []].append(item)
        }
        return order.map { key in
            let rows = (map[key] ?? []).sorted {
                ($0.season ?? 0, $0.episode ?? 0, $0.file.id) < ($1.season ?? 0, $1.episode ?? 0, $1.file.id)
            }
            return DownloadGroup(id: key, title: rows.first?.title ?? "", rows: rows)
        }
    }

    private var hasUnfinished: Bool { downloads.items.contains(where: \.isUnfinished) }
    private var hasStopped: Bool { downloads.items.contains { $0.state == .paused || $0.state == .failed } }

    var body: some View {
        List {
            if downloads.items.isEmpty {
                ContentUnavailableView("Нет загрузок", systemImage: "arrow.down.circle",
                                       description: Text("Откройте «Раздачи» фильма, удерживайте раздачу и выберите «Скачать». Или в плеере: кнопка настроек → «Скачать»."))
                    .listRowBackground(Color.clear)
            } else {
                if let reason = downloads.waitingReason {
                    Label(reason, systemImage: reason == "Нет сети" ? "wifi.slash" : "pause.circle")
                        .foregroundStyle(.orange)
                }
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.rows) { row in
                            Button {
                                tap(row)
                            } label: {
                                DownloadRow(item: row, active: downloads.activeId == row.id, rate: downloads.rate)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    downloads.remove(row.id)
                                } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                                if row.isUnfinished {
                                    Button {
                                        downloads.pause(row.id)
                                    } label: {
                                        Label("Пауза", systemImage: "pause.fill")
                                    }
                                    .tint(.orange)
                                } else if row.state == .paused || row.state == .failed {
                                    Button {
                                        downloads.resume(row.id)
                                    } label: {
                                        Label("Продолжить", systemImage: "play.fill")
                                    }
                                    .tint(.green)
                                }
                            }
                            .contextMenu { menu(for: row) }
                        }
                    }
                }
                Section {
                    LabeledContent("Занято", value: downloads.usedText)
                    if let free = downloads.freeText {
                        LabeledContent("Свободно на iPhone", value: free)
                    }
                    Toggle("Только по Wi‑Fi", isOn: $wifiOnly)
                    Toggle("Не гасить экран", isOn: $keepAwake)
                } footer: {
                    Text("Загрузка идёт, пока Кинотека открыта. Для долгой загрузки включите «Не гасить экран» и поставьте iPhone на зарядку.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Загрузки")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !downloads.items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if hasUnfinished {
                            Button {
                                downloads.pauseAll()
                            } label: {
                                Label("Приостановить все", systemImage: "pause")
                            }
                        }
                        if hasStopped {
                            Button {
                                downloads.resumeAll()
                            } label: {
                                Label("Продолжить все", systemImage: "play")
                            }
                        }
                        Button(role: .destructive) {
                            confirmDeleteAll = true
                        } label: {
                            Label("Удалить все", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
        }
        .confirmationDialog("Удалить все загрузки?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { downloads.removeAll() }
        }
    }

    @ViewBuilder
    private func menu(for row: DownloadItem) -> some View {
        if row.state == .completed {
            Button {
                play(row)
            } label: {
                Label("Смотреть", systemImage: "play.fill")
            }
        } else if row.isUnfinished {
            Button {
                downloads.pause(row.id)
            } label: {
                Label("Пауза", systemImage: "pause")
            }
        } else {
            Button {
                downloads.resume(row.id)
            } label: {
                Label(row.state == .failed ? "Повторить" : "Продолжить", systemImage: "arrow.clockwise")
            }
        }
        Button(role: .destructive) {
            downloads.remove(row.id)
        } label: {
            Label("Удалить", systemImage: "trash")
        }
    }

    private func tap(_ row: DownloadItem) {
        switch row.state {
        case .completed: play(row)
        case .queued, .downloading: downloads.pause(row.id)
        case .paused, .failed: downloads.resume(row.id)
        }
    }

    private func play(_ row: DownloadItem) {
        let title = row.episode != nil ? SeriesTitle.make(row.title, row.season, row.episode) : row.title
        coordinator.play(PlayRequest(title: title, link: row.link, itemKey: row.itemKey, item: row.item,
                                     preferredFileId: row.file.id, season: row.season, episode: row.episode))
    }
}

struct DownloadRow: View {
    let item: DownloadItem
    let active: Bool
    let rate: Double

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.detail)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if item.state != .completed {
                    ProgressView(value: item.progress)
                        .tint(item.state == .failed ? .red : (item.state == .paused ? Theme.secondary : Theme.accent))
                }
                Text(status)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(item.state == .failed ? .red : Theme.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var icon: some View {
        switch item.state {
        case .completed:
            Image(systemName: "play.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(Theme.accent)
        case .downloading:
            ZStack {
                Circle().stroke(Color.white.opacity(0.15), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(0.02, item.progress))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "pause.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
            .padding(2)
        case .queued:
            Image(systemName: "clock")
                .font(.system(size: 22))
                .foregroundStyle(Theme.secondary)
        case .paused:
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 28))
                .foregroundStyle(Theme.secondary)
        case .failed:
            Image(systemName: "exclamationmark.arrow.circlepath")
                .font(.system(size: 24))
                .foregroundStyle(.red)
        }
    }

    private var sizes: String {
        let received = ByteCountFormatter.string(fromByteCount: item.received, countStyle: .file)
        return "\(received) из \(item.file.sizeText)"
    }

    private var status: String {
        let percent = "\(Int(item.progress * 100))%"
        switch item.state {
        case .completed:
            return item.file.sizeText
        case .downloading:
            guard active else { return "Подготовка… \(percent)" }
            return rate > 0 ? "\(percent) · \(sizes) · \(TSStatus.rateText(rate))" : "\(percent) · подключение к пирам…"
        case .queued:
            if let error = item.error { return error }
            return item.received > 0 ? "В очереди · \(percent)" : "В очереди · \(item.file.sizeText)"
        case .paused:
            return "Пауза · \(percent) · \(sizes)"
        case .failed:
            return item.error ?? "Ошибка"
        }
    }
}
