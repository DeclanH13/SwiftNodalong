import Foundation

/// One row of the unified Music search list — a song, an artist or an album.
public enum SearchHit: Identifiable, Hashable, Sendable {
    case artist(ArtistResult)
    case album(AlbumResult)
    case track(SearchItem)

    public var id: String {
        switch self {
        case .artist(let a): return "artist:\(a.key)"
        case .album(let a):  return "album:\(a.key)"
        case .track(let t):  return "track:\(t.key)"
        }
    }

    /// The song / album / artist name.
    public var title: String {
        switch self {
        case .artist(let a): return a.name
        case .album(let a):  return a.name
        case .track(let t):  return t.title
        }
    }

    /// The credited artist (the artist's own name for an artist hit).
    public var artistName: String {
        switch self {
        case .artist(let a): return a.name
        case .album(let a):  return a.artistName
        case .track(let t):  return t.artist
        }
    }

    /// Album name for a track; empty otherwise.
    var albumName: String {
        if case .track(let t) = self { return t.album }
        return ""
    }

    var genreNames: [String] {
        switch self {
        case .artist(let a):
            return a.genres.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        case .album(let a):
            return a.genres
        case .track(let t):
            return t.genres
        }
    }

    var kindRank: Int {
        switch self {
        case .track:  return 0
        case .artist: return 1
        case .album:  return 2
        }
    }
}

/// What the user listens to, as 0...1 weights. Only ever used to break ties
/// *within* a match tier — it can never lift a weak match over a strong one.
public struct TasteWeights: Sendable, Equatable {
    /// Keyed by `primaryArtist(name).lowercased()`.
    public var artists: [String: Double]
    /// Keyed by lowercased genre name.
    public var genres: [String: Double]
    /// Artists the user has asked never to be boosted or suggested.
    public var blocked: Set<String>

    public init(artists: [String: Double] = [:], genres: [String: Double] = [:], blocked: Set<String> = []) {
        self.artists = artists
        self.genres = genres
        self.blocked = blocked
    }

    public static let empty = TasteWeights()
}

/// Ranks a mixed list of songs, artists and albums for one query.
///
/// Order is lexicographic: **match tier**, then how many query words matched,
/// then a **taste boost**, then the service's own order. So "good news" puts the
/// exact-title songs first and, among those, the artist you actually listen to;
/// a famous artist whose name shares no words with the query sinks to the
/// bottom instead of leading the page.
///
/// Tiers (title compared after `stripSearchNoise`):
/// 5 exact title · 4 title starts with the query · 3 every word starts a title
/// word · 2 every word found across title + artist · 1 across title + artist +
/// album · 0 otherwise.
public func rankSearchHits(_ hits: [SearchHit], query: String, taste: TasteWeights = .empty) -> [SearchHit] {
    let tokens = tokenize(query)
    guard !tokens.isEmpty else { return hits }
    let queryNorm = tokens.joined(separator: " ")

    struct Scored { let hit: SearchHit; let tier: Int; let matched: Int; let boost: Double; let order: Int }

    func norm(_ s: String) -> String {
        stripSearchNoise(s).lowercased().trimmingCharacters(in: .whitespaces)
    }

    let scored: [Scored] = deduplicated(hits).enumerated().map { index, hit in
        let title = norm(hit.title)
        let artist = hit.artistName.lowercased()
        let album = hit.albumName.lowercased()
        let titleWords = title.split(whereSeparator: \.isWhitespace).map(String.init)

        let tier: Int
        if title == queryNorm { tier = 5 }
        else if title.hasPrefix(queryNorm) { tier = 4 }
        else if tokens.allSatisfy({ t in titleWords.contains { $0.hasPrefix(t) } }) { tier = 3 }
        else if matchesAllTokens(tokens, fields: [title, artist]) { tier = 2 }
        else if matchesAllTokens(tokens, fields: [title, artist, album]) { tier = 1 }
        else { tier = 0 }

        let matched = tokens.filter { t in title.contains(t) || artist.contains(t) || album.contains(t) }.count

        let key = primaryArtist(hit.artistName).lowercased()
        var boost = 0.0
        if !taste.blocked.contains(key) {
            let artistW = taste.artists[key] ?? 0
            let genreW = hit.genreNames.map { taste.genres[$0.lowercased()] ?? 0 }.max() ?? 0
            boost = 0.6 * artistW + 0.4 * genreW
        }
        return Scored(hit: hit, tier: tier, matched: matched, boost: boost, order: index * 3 + hit.kindRank)
    }

    var sorted = scored.sorted { a, b in
        if a.tier != b.tier { return a.tier > b.tier }
        if a.matched != b.matched { return a.matched > b.matched }
        if a.boost != b.boost { return a.boost > b.boost }
        return a.order < b.order
    }

    // Variety: if the first screenful is a single kind (all songs, say) while
    // other kinds match just as well, pull the best of each up near the top.
    // Never crosses a match tier, so it can't promote a weaker match.
    let window = min(8, sorted.count)
    if window >= 6, Set(sorted.prefix(window).map { $0.hit.kindRank }).count == 1 {
        let dominant = sorted[0].hit.kindRank
        var slot = 3
        for kind in [1, 2, 0] where kind != dominant {
            guard slot < window,
                  let i = sorted.indices.first(where: { $0 >= window && sorted[$0].hit.kindRank == kind && sorted[$0].tier == sorted[slot].tier })
            else { continue }
            sorted.insert(sorted.remove(at: i), at: slot)
            slot += 1
        }
    }
    return sorted.map(\.hit)
}

/// Artist names from `candidates` (your Shelf, recent searches, already-resolved
/// artists) that the half-typed `query` could be heading towards — so "pink
/// floy" can offer Pink Floyd before Apple's own search does. Matches when the
/// name starts with the query, or every query word starts a word of the name
/// (in order, first word anchored). Needs at least 3 characters. Strongest
/// listening weight first.
public func localArtistMatches(
    query: String,
    candidates: [String],
    weights: TasteWeights = .empty,
    limit: Int = 2
) -> [String] {
    let tokens = tokenize(query)
    let joined = tokens.joined(separator: " ")
    guard joined.count >= 3, limit > 0 else { return [] }

    var seen = Set<String>()
    var matches: [(name: String, weight: Double)] = []
    for name in candidates {
        let key = primaryArtist(name).lowercased()
        guard !key.isEmpty, seen.insert(key).inserted, !weights.blocked.contains(key) else { continue }
        let words = key.split(whereSeparator: \.isWhitespace).map(String.init)
        var ok = key.hasPrefix(joined)
        if !ok, let first = tokens.first, words.first?.hasPrefix(first) == true {
            // Each query word must start some later-or-equal word, in order.
            var from = 0
            ok = tokens.allSatisfy { t in
                guard let i = words[from...].firstIndex(where: { $0.hasPrefix(t) }) else { return false }
                from = i + 1
                return true
            }
        }
        if ok { matches.append((name, weights.artists[key] ?? 0)) }
    }
    return matches
        .sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.name.count < $1.name.count }
        .prefix(limit)
        .map(\.name)
}

/// Adds `extra` artists in front of `existing`, dropping any whose id or
/// normalised name is already present.
public func mergingArtists(_ extra: [ArtistResult], into existing: [ArtistResult]) -> [ArtistResult] {
    var seenIds = Set(existing.map(\.id))
    var seenNames = Set(existing.map { $0.name.lowercased() })
    var added: [ArtistResult] = []
    for a in extra where !seenIds.contains(a.id) && !seenNames.contains(a.name.lowercased()) {
        seenIds.insert(a.id); seenNames.insert(a.name.lowercased()); added.append(a)
    }
    return added + existing
}

/// Drops repeat editions of the same song or album, keeping the first
/// (the service's own best-ranked one).
private func deduplicated(_ hits: [SearchHit]) -> [SearchHit] {
    var seen = Set<String>()
    return hits.filter { hit in
        let artist = primaryArtist(hit.artistName).lowercased()
        let key: String
        switch hit {
        case .artist(let a): key = "artist|\(a.name.lowercased())"
        case .album:         key = "album|\(albumMatchKey(hit.title))|\(artist)"
        case .track:         key = "track|\(albumMatchKey(hit.title))|\(artist)"
        }
        return seen.insert(key).inserted
    }
}
