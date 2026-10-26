import Foundation

/// How well a query matches a name. Greater is better: first by tier, then by
/// a smaller penalty within the tier.
struct Match: Comparable {
    enum Tier: Int { case fuzzy, substring, initials, wordPrefix, prefix }

    let tier: Tier
    let penalty: Int

    static func < (a: Match, b: Match) -> Bool {
        a.tier != b.tier ? a.tier.rawValue < b.tier.rawValue : a.penalty > b.penalty
    }
}

/// A name prepared once for fast case- and diacritic-insensitive matching.
struct SearchKey {
    private let chars: [Character]
    private let wordStarts: [Int]

    init(_ name: String) {
        let original = Array(name)
        chars = original.map(fold)
        wordStarts = original.indices.filter { i in
            if i == 0 { return true }
            let previous = original[i - 1], current = original[i]
            let startsWord = !isAlphanumeric(previous) && isAlphanumeric(current)
            let startsCamelCaseWord = current.isUppercase && previous.isLowercase
            return startsWord || startsCamelCaseWord
        }
    }

    func match(_ query: String) -> Match? {
        match(SearchQuery(query))
    }

    func match(_ query: SearchQuery) -> Match? {
        let q = query.chars
        guard !q.isEmpty, q.count <= chars.count else { return nil }
        if let tier = exactTier(q) { return Match(tier: tier, penalty: chars.count - q.count) }

        // Fuzzy: the query's letters appear in order, penalized by the gaps.
        let letters = q.filter { $0 != " " }
        var found = 0, first = 0, last = 0
        for (i, c) in chars.enumerated() where found < letters.count && c == letters[found] {
            if found == 0 { first = i }
            last = i
            found += 1
        }
        guard found == letters.count else { return nil }
        return Match(tier: .fuzzy, penalty: last - first + 1 - letters.count)
    }

    // The best tier in which the query appears as is.
    private func exactTier(_ q: [Character]) -> Match.Tier? {
        if chars.starts(with: q) { return .prefix }
        if wordStarts.contains(where: { matches(q, at: $0) }) { return .wordPrefix }
        if wordStarts.map({ chars[$0] }).starts(with: q) { return .initials }
        if chars.indices.contains(where: { matches(q, at: $0) }) { return .substring }
        return nil
    }

    private func matches(_ q: [Character], at start: Int) -> Bool {
        start + q.count <= chars.count && chars[start..<start + q.count].elementsEqual(q)
    }
}

/// A query folded once so it can be matched against many keys.
struct SearchQuery {
    fileprivate let chars: [Character]

    init(_ query: String) {
        chars = query.trimmingCharacters(in: .whitespaces).map(fold)
    }
}

private func fold(_ c: Character) -> Character {
    String(c).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).first ?? c
}

private func isAlphanumeric(_ c: Character) -> Bool {
    c.isLetter || c.isNumber
}
