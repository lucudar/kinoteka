import SwiftUI

/// Shown on launch when the previous run ended with a crash, a hang or an engine failure.
struct CrashReportSheet: View {
    let lines: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Похоже, прошлый запуск Кинотеки завершился с ошибкой. Отправьте отчёт разработчику — в нём журнал событий, память и сведения о сбое. Это поможет найти и исправить причину.")
                        .font(.subheadline)
                }
                Section {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondary)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Что известно")
                }
                Section {
                    DiagnosticsReportLink()
                } footer: {
                    Text("Отчёт хранится только на iPhone. Позже его можно отправить из раздела Моё → Настройки → Диагностика.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Сбой прошлого запуска")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
    }
}

/// "Поделиться отчётом": the report file is built off the main thread first.
struct DiagnosticsReportLink: View {
    @State private var url: URL?

    var body: some View {
        Group {
            if let url = url {
                ShareLink(item: url) {
                    Label("Поделиться отчётом", systemImage: "square.and.arrow.up")
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Готовится отчёт…")
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
        .task {
            let prepared = await AppDiagnostics.shared.prepareReport()
            if !Task.isCancelled { url = prepared }
        }
    }
}
