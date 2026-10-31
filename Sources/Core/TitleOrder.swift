import Foundation

/// The order of a list of films and series on screen. `.original` is the list's own order
/// (popularity, relevance, the place in a top list); the others sort what is loaded by the year
/// of release or by the rating. Sorting is stable: titles of the same year (or rating) keep the
/// list's order between them, and titles without a year (or a rating) go last either way.
enum TitleOrder: String, CaseIterable, Identifiable, Sendable {
    case original
    case newest
    case oldest
    case rating

    var id: String { rawValue }

    /// A paged list is sorted whole: this many pages of a collection are loaded first
    /// (300 titles: all of "250 лучших"), and this many of the search results.
    static let collectionPages = 15
    static let searchPages = 3

    /// The menu item; the list names its own order ("По популярности", "По релевантности").
    func title(original: String) -> String {
        switch self {
        case .original: return original
        case .newest: return "Сначала новые"
        case .oldest: return "Сначала старые"
        case .rating: return "По рейтингу"
        }
    }

    func sorted<T>(_ items: [T], year: (T) -> Int?, rating: (T) -> Double?) -> [T] {
        switch self {
        case .original:
            return items
        case .newest:
            return TitleOrder.stable(items, key: { TitleOrder.validYear(year($0)) }, descending: true)
        case .oldest:
            return TitleOrder.stable(items, key: { TitleOrder.validYear(year($0)) }, descending: false)
        case .rating:
            return TitleOrder.stable(items, key: { TitleOrder.validRating(rating($0)) }, descending: true)
        }
    }

    /// A year of release worth sorting by (0 and garbage are "unknown").
    static func validYear(_ year: Int?) -> Int? {
        guard let year = year, year >= 1850, year <= 2200 else { return nil }
        return year
    }

    static func validRating(_ rating: Double?) -> Double? {
        guard let rating = rating, rating.isFinite, rating > 0 else { return nil }
        return rating
    }

    /// Sorted by `key`, the items without one last; equal keys keep their order.
    static func stable<T, Key: Comparable>(_ items: [T], key: (T) -> Key?, descending: Bool) -> [T] {
        let keyed = items.enumerated().map { (offset: $0.offset, key: key($0.element), item: $0.element) }
        return keyed.sorted { a, b in
            switch (a.key, b.key) {
            case let (left?, right?):
                if left != right { return descending ? left > right : left < right }
                return a.offset < b.offset
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return a.offset < b.offset
            }
        }.map(\.item)
    }
}

/// Loads pages of a paged list a few at a time and returns them in order. Stops at the first
/// failure: the pages before it come back with the error.
enum PagedLoad {
    static func pages<T: Sendable>(_ numbers: ClosedRange<Int>, width: Int = 4,
                                   load: @escaping @Sendable (Int) async throws -> T) async -> (pages: [T], error: Error?) {
        var result: [T] = []
        var start = numbers.lowerBound
        while start <= numbers.upperBound {
            if Task.isCancelled { return (result, CancellationError()) }
            let end = min(numbers.upperBound, start + max(1, width) - 1)
            let batch = await withTaskGroup(of: (Int, Result<T, Error>).self) { group -> [(Int, Result<T, Error>)] in
                for number in start...end {
                    group.addTask {
                        do {
                            return (number, .success(try await load(number)))
                        } catch {
                            return (number, .failure(error))
                        }
                    }
                }
                var answers: [(Int, Result<T, Error>)] = []
                for await answer in group {
                    answers.append(answer)
                }
                return answers.sorted { $0.0 < $1.0 }
            }
            for (_, answer) in batch {
                switch answer {
                case .success(let page):
                    result.append(page)
                case .failure(let error):
                    return (result, error)
                }
            }
            start = end + 1
        }
        return (result, nil)
    }
}
