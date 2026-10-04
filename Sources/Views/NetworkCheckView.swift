import SwiftUI

/// Settings → Диагностика → Проверка сети.
struct NetworkCheckView: View {
    @StateObject private var check = NetworkCheck()

    var body: some View {
        List {
            Section {
                Text("Показывает, что открывается в этой сети: Кинопоиск, серверы поиска раздач и их зеркала в России, трекеры и DHT торрент-сети. Чтобы понять, что мешает в мобильной сети, выключите VPN и Wi‑Fi и запустите проверку снова.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
            }

            ForEach(NetworkCheckItem.Group.allCases) { group in
                let rows = check.items.filter { $0.group == group }
                if !rows.isEmpty {
                    Section(group.title) {
                        ForEach(rows) { item in
                            NetworkCheckRow(item: item)
                        }
                    }
                }
            }

            Section {
                Button {
                    check.start()
                } label: {
                    Label(check.running ? "Проверка…" : "Проверить снова", systemImage: "arrow.clockwise")
                }
                .disabled(check.isBusy)
                Button {
                    check.startSpeedTest()
                } label: {
                    Label(check.testingSpeed ? "Скорость проверяется…" : "Проверить скорость торрента", systemImage: "speedometer")
                }
                .disabled(check.isBusy)
                if !check.isBusy && !check.items.isEmpty {
                    ShareLink(item: check.report) {
                        Label("Поделиться отчётом", systemImage: "square.and.arrow.up")
                    }
                }
            } footer: {
                Text("Проверка скорости около 25 секунд качает открытую раздачу Ubuntu (до 60 МБ в мобильной сети, до 300 МБ по Wi‑Fi) и затем удаляет её. В отчёте нет IP-адреса и ключей — его можно отправить разработчику.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Проверка сети")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if check.items.isEmpty { check.start() }
        }
        .onDisappear { check.cancel() }
    }
}

private struct NetworkCheckRow: View {
    let item: NetworkCheckItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var icon: some View {
        switch item.state {
        case .running:
            ProgressView()
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
        case .info:
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Theme.accent)
        }
    }
}
