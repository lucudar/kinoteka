import SwiftUI

/// Subtitles found on OpenSubtitles for the playing file; a tap downloads and turns them on.
struct SubtitleSearchList: View {
    let query: () async -> SubtitleService.Query
    let onPick: (URL, SubtitleCandidate) -> Void

    @AppStorage(SettingsKeys.openSubtitlesKey) private var apiKey = ""
    @State private var results: [SubtitleCandidate] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var errorText: String?
    @State private var downloading: Int?

    var body: some View {
        List {
            if apiKey.trimmed.isEmpty {
                Section {
                    SecureField("Ключ API OpenSubtitles", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    PasteButton(payloadType: String.self) { strings in
                        Task { @MainActor in
                            if let first = strings.first { apiKey = first.trimmed }
                        }
                    }
                    if let url = SubtitleService.keyPage {
                        Link(destination: url) {
                            Label("Получить ключ бесплатно", systemImage: "arrow.up.right.square")
                        }
                    }
                } footer: {
                    Text("Поиск идёт по OpenSubtitles.com — нужен бесплатный ключ: зарегистрируйтесь, откройте «API consumers», создайте ключ и вставьте сюда.")
                }
            } else if loading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Ищем субтитры…")
                        .foregroundStyle(Theme.secondary)
                }
            } else if let errorText {
                Section {
                    Text(errorText)
                        .foregroundStyle(Theme.secondary)
                    Button("Повторить") {
                        Task { await load() }
                    }
                }
            } else if loaded && results.isEmpty {
                Text("Ничего не найдено")
                    .foregroundStyle(Theme.secondary)
            } else {
                Section {
                    ForEach(results.prefix(40)) { candidate in
                        Button {
                            pick(candidate)
                        } label: {
                            row(candidate)
                        }
                        .disabled(downloading != nil)
                    }
                } footer: {
                    Text("✓ — синхронизированы именно с этим файлом.")
                }
            }
        }
        .navigationTitle("Субтитры из интернета")
        .task(id: apiKey.trimmed.isEmpty) {
            if !apiKey.trimmed.isEmpty, !loaded { await load() }
        }
    }

    private func row(_ candidate: SubtitleCandidate) -> some View {
        HStack(spacing: 12) {
            Text(candidate.language.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 24)
                .background(Theme.accent.opacity(0.35), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.release.isEmpty ? candidate.fileName : candidate.release)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(details(candidate))
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 8)
            if downloading == candidate.fileId {
                ProgressView()
            } else if candidate.hashMatch {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
        }
        .contentShape(Rectangle())
    }

    private func details(_ candidate: SubtitleCandidate) -> String {
        var parts = ["скачиваний: \(candidate.downloads)"]
        if candidate.hearingImpaired { parts.append("для слабослышащих") }
        if candidate.machineTranslated { parts.append("машинный перевод") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        loading = true
        errorText = nil
        defer {
            loading = false
            loaded = true
        }
        do {
            let request = await query()
            results = try await SubtitleService.shared.search(request)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func pick(_ candidate: SubtitleCandidate) {
        downloading = candidate.fileId
        Task {
            defer { downloading = nil }
            do {
                let url = try await SubtitleService.shared.download(candidate)
                onPick(url, candidate)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

/// "Скачать" in the player: this episode or film, the season, or every file of the release.
struct PlayerDownloadPage: View {
    @ObservedObject private var downloads = DownloadManager.shared
    let hash: String
    let current: TorrentFile?
    let isSeries: Bool
    let season: Int?
    let seasonFiles: [TorrentFile]
    let allVideos: [TorrentFile]
    let enqueue: ([TorrentFile]) -> Void

    var body: some View {
        List {
            if let current {
                Section {
                    if let item = downloads.item(hash: hash, fileId: current.id) {
                        LabeledContent(isSeries ? "Эта серия" : "Этот фильм", value: status(item))
                        if item.state == .failed || item.state == .paused {
                            Button("Продолжить загрузку") { downloads.resume(item.id) }
                        }
                    } else {
                        Button {
                            enqueue([current])
                        } label: {
                            choice(isSeries ? "Эту серию" : "Этот фильм", files: [current])
                        }
                    }
                }
            }
            if isSeries {
                Section {
                    if let season, seasonFiles.count > 1 {
                        Button {
                            enqueue(seasonFiles)
                        } label: {
                            choice("Весь \(season) сезон", files: seasonFiles)
                        }
                    }
                    if allVideos.count > 1 && allVideos.count != seasonFiles.count {
                        Button {
                            enqueue(allVideos)
                        } label: {
                            choice("Все файлы раздачи", files: allVideos)
                        }
                    }
                }
            }
            Section {
                NavigationLink {
                    DownloadsView()
                } label: {
                    LabeledContent("Все загрузки", value: downloads.items.isEmpty ? "" : "\(downloads.items.count)")
                }
            } footer: {
                Text("Скачанное смотрится без интернета: «Моё» → «Загрузки». По умолчанию загрузка идёт только по Wi‑Fi и ждёт, пока вы смотрите онлайн. Свободно: \(downloads.freeText ?? "—").")
            }
        }
        .navigationTitle("Скачать")
    }

    private func choice(_ title: String, files: [TorrentFile]) -> some View {
        let size = ByteCountFormatter.string(fromByteCount: files.reduce(Int64(0)) { $0 + $1.length }, countStyle: .file)
        return HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(Theme.accent)
                .frame(width: 26)
            Text(title)
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            Text(files.count > 1 ? "\(files.count) · \(size)" : size)
                .foregroundStyle(Theme.secondary)
        }
        .contentShape(Rectangle())
    }

    private func status(_ item: DownloadItem) -> String {
        switch item.state {
        case .completed: return "скачано"
        case .downloading, .queued: return "загружается, \(Int(item.progress * 100))%"
        case .paused: return "пауза, \(Int(item.progress * 100))%"
        case .failed: return item.error ?? "ошибка"
        }
    }
}
