import SwiftUI

/// The page of an actor or a director: the photo, a few facts and their films
/// grouped by the kind of work (roles, directing, scripts…).
struct PersonView: View {
    let route: PersonRoute
    @AppStorage(SettingsKeys.kpToken) private var token = ""
    @State private var person: KPPerson?
    @State private var groups: [PersonWorkGroup] = []
    @State private var selected: Int?
    @State private var error: String?

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 12, alignment: .top)]

    private var currentGroup: PersonWorkGroup? {
        groups.first { $0.order == selected } ?? groups.first
    }

    private var displayName: String {
        person?.name.nonEmpty ?? route.name
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if person == nil {
                    if let error = error {
                        ErrorView(message: error) { Task { await load() } }
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                } else if groups.isEmpty {
                    ContentUnavailableView("Фильмов не найдено", systemImage: "film.stack")
                        .padding(.top, 20)
                } else {
                    groupPicker
                    grid
                }
            }
            .padding(.vertical, 12)
        }
        .background(Theme.background)
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: token) { await load() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Color.clear
                .frame(width: 96, height: 144)
                .overlay {
                    PosterImage(url: URL(string: person?.posterUrl ?? ""))
                }
                .overlay {
                    if person?.posterUrl == nil {
                        Image(systemName: "person.fill")
                            .font(.largeTitle)
                            .foregroundStyle(Theme.secondary.opacity(0.4))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(displayName)
                    .font(.title2.weight(.bold))
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                if let english = person?.nameEn?.nonEmpty, english != displayName {
                    Text(english)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                }
                if let profession = person?.profession?.nonEmpty {
                    Text(profession)
                        .font(.subheadline)
                        .lineLimit(3)
                }
                ForEach(facts, id: \.self) { fact in
                    Text(fact)
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    private var facts: [String] {
        guard let person = person else { return [] }
        var lines: [String] = []
        if let born = RuDate.text(person.birthday) {
            if person.death == nil, let age = person.age, age > 0, age < 130 {
                lines.append("Дата рождения: \(born) (\(Plural.ru(age, "год", "года", "лет")))")
            } else {
                lines.append("Дата рождения: \(born)")
            }
        }
        if let died = RuDate.text(person.death) {
            lines.append("Дата смерти: \(died)")
        }
        if let place = person.birthplace?.nonEmpty {
            lines.append("Место рождения: \(place)")
        }
        return lines
    }

    // MARK: Films

    private var groupPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(groups) { group in
                    Chip(title: "\(group.title) · \(group.entries.count)",
                         selected: group.order == currentGroup?.order) {
                        selected = group.order
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(currentGroup?.entries ?? []) { entry in
                NavigationLink(value: entry.item) {
                    PosterCard(item: entry.item, caption: entry.caption)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: Loading

    private func load() async {
        guard person == nil else { return }
        do {
            let loaded = try await KPClient.shared.person(route.id)
            let made = PersonWorkGroup.make(from: loaded.films)
            person = loaded
            groups = made
            error = nil
            if selected == nil, let key = route.professionKey {
                let order = PersonWork.group(key).order
                if made.contains(where: { $0.order == order }) { selected = order }
            }
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

struct PersonWorkEntry: Identifiable {
    let item: MediaItem
    let caption: String?
    var id: Int { item.id }
}

struct PersonWorkGroup: Identifiable {
    let order: Int
    let title: String
    var entries: [PersonWorkEntry]
    var id: Int { order }

    /// One entry per film and kind of work; the best rated films first.
    static func make(from films: [KPPersonFilm]) -> [PersonWorkGroup] {
        var buckets: [Int: PersonWorkGroup] = [:]
        var seen: [Int: Set<Int>] = [:]
        for film in films {
            guard let item = film.item else { continue }
            let kind = PersonWork.group(film.professionKey)
            guard seen[kind.order, default: []].insert(item.id).inserted else { continue }
            var parts: [String] = []
            if kind.order == 0, let role = film.role?.nonEmpty { parts.append(role) }
            if item.kind == .series { parts.append("сериал") }
            if let year = item.year { parts.append(String(year)) }
            let entry = PersonWorkEntry(item: item, caption: parts.isEmpty ? nil : parts.joined(separator: " · "))
            buckets[kind.order, default: PersonWorkGroup(order: kind.order, title: kind.title, entries: [])]
                .entries.append(entry)
        }
        return buckets.values
            .sorted { $0.order < $1.order }
            .map { group in
                var copy = group
                copy.entries.sort { a, b in
                    let left = a.item.ratingKP ?? 0
                    let right = b.item.ratingKP ?? 0
                    if left != right { return left > right }
                    return a.item.title.localizedCompare(b.item.title) == .orderedAscending
                }
                return copy
            }
    }
}
