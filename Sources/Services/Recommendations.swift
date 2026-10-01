import Foundation

struct RecommendationResult {
    let items: [MediaItem]
    let reason: String
}

enum RecommendationService {
    static func hasProfile(_ data: LibraryData) -> Bool {
        profileGenres(data).isEmpty == false
    }

    static func profileKey(_ data: LibraryData) -> String {
        let values = (data.favorites + data.watchLater + Array(data.history.prefix(30)) + data.watched)
            .map { String($0.id) }
        return values.joined(separator: ",")
    }

    static func recommendations(for data: LibraryData) async throws -> RecommendationResult {
        let genres = profileGenres(data)
        guard let first = genres.first else {
            return RecommendationResult(items: [], reason: "")
        }

        let filters = try await KPClient.shared.filters()
        let mapped = genres.compactMap { genre -> (String, Int)? in
            guard let value = filters.genres.first(where: {
                $0.title.compare(genre, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }), let id = value.id else { return nil }
            return (genre, id)
        }
        guard let movieGenre = mapped.first else {
            return RecommendationResult(items: [], reason: "")
        }
        let seriesGenre = mapped.dropFirst().first ?? movieGenre

        var movieFilter = CatalogFilter()
        movieFilter.type = "FILM"
        movieFilter.order = "RATING"
        movieFilter.genreId = movieGenre.1
        movieFilter.ratingFrom = 6

        var seriesFilter = CatalogFilter()
        seriesFilter.type = "TV_SERIES"
        seriesFilter.order = "RATING"
        seriesFilter.genreId = seriesGenre.1
        seriesFilter.ratingFrom = 6

        async let moviesRequest = KPClient.shared.films(movieFilter, page: 1)
        async let seriesRequest = KPClient.shared.films(seriesFilter, page: 1)
        let moviePage = try? await moviesRequest
        let seriesPage = try? await seriesRequest

        let existing = Set(
            (data.favorites + data.watchLater + data.history + data.watched +
             data.continueWatching.compactMap(\.item)).map(\.id)
        )
        let preferred = Set(genres.map { $0.lowercased() })
        var seen = Set<Int>()
        let candidates = ((moviePage?.items ?? []) + (seriesPage?.items ?? []))
            .filter { !existing.contains($0.id) && seen.insert($0.id).inserted }
            .sorted {
                score($0, genres: preferred) > score($1, genres: preferred)
            }

        let reason = "По вашим жанрам: " + mapped.prefix(2).map(\.0).joined(separator: " и ")
        return RecommendationResult(items: Array(candidates.prefix(20)), reason: reason)
    }

    private static func profileGenres(_ data: LibraryData) -> [String] {
        var scores: [String: (title: String, score: Int)] = [:]

        func add(_ items: [MediaItem], weight: Int) {
            for item in items {
                for genre in item.genres.prefix(3) {
                    let key = genre.trimmed.lowercased()
                    guard !key.isEmpty else { continue }
                    let old = scores[key] ?? (genre, 0)
                    scores[key] = (old.title, old.score + weight)
                }
            }
        }

        add(data.favorites, weight: 5)
        add(data.watchLater, weight: 3)
        add(Array(data.history.prefix(30)), weight: 2)
        add(data.watched, weight: 1)

        return scores.values
            .sorted {
                $0.score == $1.score
                    ? $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                    : $0.score > $1.score
            }
            .prefix(3)
            .map(\.title)
    }

    private static func score(_ item: MediaItem, genres: Set<String>) -> Double {
        let overlap = item.genres.reduce(0) { value, genre in
            value + (genres.contains(genre.lowercased()) ? 1 : 0)
        }
        let rating = item.ratingKP ?? item.ratingIMDb ?? 0
        let freshness = Double(max(0, (item.year ?? 2000) - 2000)) / 100
        return Double(overlap) * 10 + rating + freshness
    }
}