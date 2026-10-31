import Foundation

/// One listened-to track, reduced to what a genre match needs.
public struct GenreArtistTrack: Sendable, Equatable {
    public let artist: String
    public let genres: [String]
    public init(artist: String, genres: [String]) {
        self.artist = artist
        self.genres = genres
    }
}

/// A genre both people listen to, with the artists they share in it.
public struct GenreOverlap: Sendable, Equatable {
    public let genre: String
    public let sharedArtists: [String]
}

/// "Strong match in Hip-Hop and Alternative" — what two people share, by genre.
public struct GenreTasteMatch: Sendable, Equatable {
    /// Best first, at most `genreMatchMaxGenres`.
    public let overlaps: [GenreOverlap]
    /// Distinct shared artists across every shared genre (not just the shown ones).
    public let sharedArtistCount: Int
    public let band: TasteMatch.Band
}

public let genreMatchMaxGenres = 3
public let genreMatchMaxArtistsPerGenre = 3

/// Genre-level overlap between two listening histories.
///
/// An artist belongs to a genre under the same rule discovery uses
/// (`tasteArtistGenreShare` of their tracks carry the tag, or it is their top
/// tag), so one mislabelled single can't make someone a "jazz listener".
/// Returns nil when no genre is shared — including when either side has no
/// genre data at all, which is the caller's cue to fall back to `tasteMatch`.
public func genreTasteMatch(mine: [GenreArtistTrack], theirs: [GenreArtistTrack]) -> GenreTasteMatch? {
    let a = genreArtistMap(mine)
    let b = genreArtistMap(theirs)
    guard !a.genres.isEmpty, !b.genres.isEmpty else { return nil }

    var overlaps: [(genre: String, artists: [String], weight: Int)] = []
    var allShared = Set<String>()
    for (genreKey, theirArtists) in b.genres {
        guard let myArtists = a.genres[genreKey] else { continue }
        let shared = myArtists.intersection(theirArtists)
        guard !shared.isEmpty else { continue }
        allShared.formUnion(shared)
        let names = shared
            .sorted { (b.plays[$0] ?? 0, $1) > (b.plays[$1] ?? 0, $0) }
            .prefix(genreMatchMaxArtistsPerGenre)
            .map { b.display[$0] ?? a.display[$0] ?? $0.capitalized }
        overlaps.append((b.genreDisplay[genreKey] ?? genreKey.capitalized, Array(names), shared.count))
    }
    guard !overlaps.isEmpty else { return nil }

    let top = overlaps
        .sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.genre < $1.genre }
        .prefix(genreMatchMaxGenres)
        .map { GenreOverlap(genre: $0.genre, sharedArtists: $0.artists) }
    let band: TasteMatch.Band =
        allShared.count >= tasteMatchStrongThreshold ? .strong :
        allShared.count >= tasteMatchSomeThreshold   ? .some   : .little
    return GenreTasteMatch(overlaps: Array(top), sharedArtistCount: allShared.count, band: band)
}

private struct GenreArtistMap {
    var genres: [String: Set<String>] = [:]       // genre key -> artist keys
    var display: [String: String] = [:]           // artist key -> name
    var genreDisplay: [String: String] = [:]      // genre key -> name
    var plays: [String: Int] = [:]                // artist key -> track count
}

private func genreArtistMap(_ tracks: [GenreArtistTrack]) -> GenreArtistMap {
    var perArtist: [String: (name: String, total: Int, genres: [String: (name: String, count: Int)])] = [:]
    for t in tracks {
        let key = primaryArtist(t.artist).lowercased()
        guard !key.isEmpty else { continue }
        var e = perArtist[key] ?? (primaryArtist(t.artist), 0, [:])
        e.total += 1
        for g in normalizedGenres(t.genres) {
            let gk = g.lowercased()
            e.genres[gk] = (e.genres[gk]?.name ?? g, (e.genres[gk]?.count ?? 0) + 1)
        }
        perArtist[key] = e
    }

    var map = GenreArtistMap()
    for (key, e) in perArtist {
        map.display[key] = e.name
        map.plays[key] = e.total
        guard !e.genres.isEmpty else { continue }
        let topCount = e.genres.values.map(\.count).max() ?? 0
        for (gk, g) in e.genres {
            let qualifies = Double(g.count) / Double(e.total) >= tasteArtistGenreShare || g.count == topCount
            guard qualifies else { continue }
            map.genres[gk, default: []].insert(key)
            if map.genreDisplay[gk] == nil { map.genreDisplay[gk] = g.name }
        }
    }
    return map
}
