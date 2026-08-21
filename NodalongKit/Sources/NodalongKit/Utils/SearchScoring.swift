// Splits a raw query into lowercase, deduplicated, non-empty tokens.
// "Kanye LIGHTS lights" → ["kanye", "lights"]
public func tokenize(_ query: String) -> [String] {
    var seen = Set<String>()
    var tokens: [String] = []
    for raw in query.lowercased().split(whereSeparator: \.isWhitespace) {
        let t = String(raw)
        if !t.isEmpty && !seen.contains(t) {
            seen.insert(t)
            tokens.append(t)
        }
    }
    return tokens
}

// Returns true if every token appears as a case-insensitive substring in at least one field.
public func matchesAllTokens(_ tokens: [String], fields: [String]) -> Bool {
    tokens.allSatisfy { token in
        fields.contains { field in field.contains(token) }
    }
}

// Returns a relevance score. Title matches outrank artist, which outrank album.
// Word-prefix matches earn bonus points within title and artist.
public func scoreTrack(tokens: [String], title: String, artist: String, album: String) -> Int {
    let titleL = title.lowercased()
    let artistL = artist.lowercased()
    let albumL = album.lowercased()
    let titleWords = titleL.split(whereSeparator: \.isWhitespace).map(String.init)
    let artistWords = artistL.split(whereSeparator: \.isWhitespace).map(String.init)

    var score = 0
    for token in tokens {
        if titleL.contains(token) {
            score += 4
            if titleWords.contains(where: { $0.hasPrefix(token) }) { score += 2 }
        }
        if artistL.contains(token) {
            score += 2
            if artistWords.contains(where: { $0.hasPrefix(token) }) { score += 2 }
        }
        if albumL.contains(token) {
            score += 1
        }
    }
    return score
}

// Stable-sort by descending score; items with equal score keep original order.
public func rankByRelevance<T>(_ items: [T], scorer: (T) -> Int) -> [T] {
    items
        .enumerated()
        .map { (offset: $0.offset, item: $0.element, score: scorer($0.element)) }
        .sorted { lhs, rhs in lhs.score != rhs.score ? lhs.score > rhs.score : lhs.offset < rhs.offset }
        .map(\.item)
}
