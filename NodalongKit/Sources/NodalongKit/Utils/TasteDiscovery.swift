import Foundation

/// Turning "these artists, this strongly" into "these 25 songs you haven't heard".
///
/// The second half of the taste lens. `TasteSeeds` says what I listen to; this
/// scores what the catalog offers next to it.
///
/// **What this is and isn't.** The similarity itself is Apple's — MusicKit's
/// `similarArtists` relationship — and deliberately so: Apple's graph is built
/// on vastly more listening than anything inferable from the title, artist and
/// genre this app stores. What's ours is the weighting of deliberate signals
/// (see `TasteSignal`), the corroboration across seeds, the genre modifier, and
/// the exclusion of everything already heard. That last one is the biggest
/// practical difference from Apple's own recommendations, which routinely hand
/// back music already in your library.

/// One artist the expansion surfaced, and why.
public struct CandidateArtist: Sendable, Equatable {
    public let id: String
    public let name: String
    /// Summed weight of the seed artists that pointed here.
    public let score: Double
    /// Which of my own artists led to this one — heaviest first. Feeds the
    /// playlist description, so a suggestion can always explain itself.
    public let seedNames: [String]

    public init(id: String, name: String, score: Double, seedNames: [String]) {
        self.id = id
        self.name = name
        self.score = score
        self.seedNames = seedNames
    }
}

/// Ranks the artists Apple's similarity graph returned for my seeds.
///
/// **Corroboration is the point**: an artist reached from three of my seeds
/// scores the sum of all three, so it outranks one reached from a single seed.
/// That's the same emergent property `selectTracks` relies on for people,
/// applied a level up — and it's what stops a single outlier artist in my
/// library from dominating the whole playlist.
///
/// Anyone in `known` is dropped outright. An artist I already listen to is not
/// a discovery, however strongly the graph points at them.
///
/// Ties break on `id` so a regenerated playlist doesn't churn.
///
/// Variety controls (all off by default, so the plain behaviour above is what
/// existing callers and tests get):
/// - `novelty`: normalized artist key → multiplier (see `noveltyMultipliers`),
///   so artists suggested recently sink and others get a turn.
/// - `dampenHubs`: divides the summed score by `reached^0.75`, so an artist
///   that is merely close to everything (a graph hub) stops winning on sheer
///   connectivity every single time.
public func rankCandidateArtists(
    similarBySeed: [(seed: SeededArtist, similar: [(id: String, name: String)])],
    excluding known: Set<String>,
    limit: Int,
    novelty: [String: Double] = [:],
    dampenHubs: Bool = false
) -> [CandidateArtist] {
    guard limit > 0 else { return [] }

    struct Accumulator {
        var name: String
        var score: Double
        /// Kept with weights so the description can name the strongest seeds
        /// rather than whichever happened to be processed first.
        var seeds: [(name: String, weight: Double)]
    }

    var byArtist: [String: Accumulator] = [:]

    for (seed, similar) in similarBySeed {
        for candidate in similar {
            guard !candidate.id.isEmpty else { continue }
            let key = primaryArtist(candidate.name).lowercased()
            guard !key.isEmpty, !known.contains(key) else { continue }

            if var existing = byArtist[candidate.id] {
                existing.score += seed.weight
                existing.seeds.append((seed.displayName, seed.weight))
                byArtist[candidate.id] = existing
            } else {
                byArtist[candidate.id] = Accumulator(
                    name: candidate.name,
                    score: seed.weight,
                    seeds: [(seed.displayName, seed.weight)]
                )
            }
        }
    }

    return byArtist
        .map { id, accumulator in
            let seedNames = accumulator.seeds
                .sorted { $0.weight == $1.weight ? $0.name < $1.name : $0.weight > $1.weight }
                .map(\.name)
            var score = accumulator.score
            if dampenHubs { score /= pow(Double(accumulator.seeds.count), 0.75) }
            score *= novelty[primaryArtist(accumulator.name).lowercased()] ?? 1
            return CandidateArtist(
                id: id,
                name: accumulator.name,
                score: score,
                seedNames: seedNames
            )
        }
        .sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
        .prefix(limit)
        .map { $0 }
}

/// A track offered by one candidate artist, with its position in that artist's
/// top songs.
public struct TasteCandidate: Sendable, Equatable {
    public let song: Song
    /// The `CandidateArtist.score` that surfaced it.
    public let artistScore: Double
    /// Index within that artist's top songs — 0 is their biggest.
    public let rank: Int
    /// Normalized artist key, for the per-artist cap.
    public let artistKey: String

    public init(song: Song, artistScore: Double, rank: Int) {
        self.song = song
        self.artistScore = artistScore
        self.rank = rank
        self.artistKey = primaryArtist(song.artist).lowercased()
    }
}

/// How much each step down an artist's top songs costs.
///
/// **Kept only for the non-discovery scoring path and the tests that pin it.**
/// `discoveryPositionWeight(rank:)` is what the taste lens actually uses now —
/// see the note there for why rewarding rank 0 was backwards for this feature.
public let tasteRankDecay: Double = 0.12

/// How many of a candidate artist's top songs to consider.
///
/// `getArtistCore` returns whatever single page Apple's relationship gives
/// (~10) — an artist's most-played handful, i.e. exactly the tracks someone
/// adjacent to them already knows. 30 is what `getArtistTopSongsFull` pages
/// to, and it is what gives the scoring anything to choose between.
public let tasteTopSongsPerArtist = 30

/// How many of a candidate artist's albums to pull tracks from.
///
/// Top songs — even 30 of them — are still that artist's 30 most *popular*
/// recordings, which is not what "deep cut" means. Album tracks are the only
/// genuine source. Bounded at 2 because each album is one `getAlbumTracks`
/// request (disk-cached per album afterwards), and this runs across every
/// candidate artist.
public let tasteAlbumsPerArtist = 2

/// The rank an album track is filed under.
///
/// A distinct sentinel (not a real position in `topSongs`) so a deep cut can be
/// told apart from an artist's 4th–30th most popular song. Album tracks are
/// added AFTER top songs, so a hit that also appears on an album is
/// deduplicated against its top-songs entry inside `selectTasteTracks` and
/// keeps its popularity rank. Whatever survives with this rank is a track
/// outside the artist's top songs — the nearest thing to "low plays" MusicKit
/// lets us see, since catalog songs expose no global play counts.
///
/// Still ≥ `tasteFamiliarRankCutoff`, so `discoveryPositionWeight` leaves it
/// unpenalised.
public let tasteAlbumTrackRank = 1000

/// How many of the first-drawn artists get a second track. The rest get one,
/// so a full 25-track list is 7 × 2 + 11 × 1 — at least 18 different artists.
public let tasteDoubleSlotArtists = 7

/// Ranks at or below this are an artist's signature tracks.
public let tasteFamiliarRankCutoff = 3

/// What a signature track's score is multiplied by.
public let tasteFamiliarPenalty: Double = 0.6

/// 🔴 Discovery inverts the usual ranking instinct, and this is the whole
/// point of the change.
///
/// The original weighting was `1 / (1 + rank × tasteRankDecay)`, which
/// **rewards rank 0** — each similar artist's biggest hit. For a lens whose
/// entire job is showing you music you haven't heard, that is backwards: if
/// Apple's graph says "you like Fontaines D.C., try Shame", the one Shame
/// track you have plausibly already heard is their most popular one. The
/// engine was tuned for plausibility when it should have been tuned for
/// surprise, and the result read as a greatest-hits reel of artists adjacent
/// to your taste.
///
/// So signature tracks are now *penalised* rather than rewarded, and
/// everything past the cutoff is treated as equally worth surfacing. Flat
/// rather than actively favouring the deepest cut: rank within an artist's
/// top songs is a popularity signal, not a quality one, so past the "you have
/// definitely heard this" band there is no reason to believe track 12 beats
/// track 5. What separates them is the seeded jitter in `selectTasteTracks`.
///
/// Deliberately not applied to `hasHeard` tracks — those are already dropped
/// outright. This is about the ones we can't prove you've heard but probably
/// have.
public func discoveryPositionWeight(rank: Int) -> Double {
    rank < tasteFamiliarRankCutoff ? tasteFamiliarPenalty : 1.0
}

/// How far a seeded reshuffle may move a candidate's score, as a fraction.
///
/// Bounded rather than a free shuffle so the ranking still means something:
/// an artist three of your seeds point at should still beat one reached from
/// a single seed. This changes *which of their tracks* surface and lets two
/// close-scoring artists trade places — it does not throw the ranking away.
public let tasteShuffleJitter: Double = 0.35

/// Deterministic RNG so a given seed always produces the same ordering.
///
/// splitmix64 — the same construction `ParkBackgroundView` uses for its
/// scenery, kept local to this module rather than shared because that one is
/// a private implementation detail of a view.
public struct TasteShuffleGenerator: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) { self.state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Genre agreement scales a score by at most this much. Deliberately modest:
/// Apple's similarity already did the hard part, and over-weighting genre
/// would just re-sort Apple's answer by our much thinner metadata.
public let tasteGenreBoost: Double = 0.5

/// How strongly a track's genres match what I listen to, `0...1`.
///
/// Takes the best-matching genre rather than averaging: a track tagged
/// `["Alternative", "Hip-Hop"]` where I only listen to hip-hop is still a hip-hop
/// suggestion, and averaging would halve it for carrying a second tag.
public func genreAffinity(of genres: [String], against weights: [String: Double]) -> Double {
    guard !weights.isEmpty else { return 0 }
    var best = 0.0
    for genre in genres {
        if let weight = weights[genre.lowercased()], weight > best { best = weight }
    }
    return best
}

/// The first `count` tracks of an artist's ranked list, but when taking more
/// than one, prefer tracks from DIFFERENT albums: the best track first, then the
/// best remaining one from another album, falling back to the next-ranked only
/// if every track is from the same album. Keeps an artist's two slots from being
/// two songs off one record.
func pickTracks(from tracks: [TasteCandidate], count: Int) -> [TasteCandidate] {
    guard count > 1, let first = tracks.first else { return Array(tracks.prefix(count)) }
    var picked = [first]
    var usedAlbums: Set<String> = [albumMatchKey(first.song.album)]
    var rest = Array(tracks.dropFirst())
    while picked.count < count, !rest.isEmpty {
        let i = rest.firstIndex { !usedAlbums.contains(albumMatchKey($0.song.album)) } ?? 0
        let t = rest.remove(at: i)
        usedAlbums.insert(albumMatchKey(t.song.album))
        picked.append(t)
    }
    return picked
}

/// Picks the final list: **many artists, one or two tracks each, deep cuts
/// first.**
///
/// The list used to be built artist-first from a tiny fixed pool (12 artists ×
/// 2 tracks), so the same artists came back every time and the shuffle only
/// reordered them. Now:
///
/// 1. Drop anything already heard (matched on catalogId, ISRC **or** normalised
///    title+artist) and duplicate recordings.
/// 2. Group what's left by artist and order each artist's tracks by tier — a
///    deep cut (album track outside their top songs) first, then the rest of
///    their top songs, then their signature tracks as a last resort.
/// 3. Order the artists by a **weighted random draw without replacement**
///    (Efraimidis–Spirakis: `key = u^(1/weight)`), weight = `artistScore`
///    nudged by genre agreement. High scorers are likelier, not guaranteed, so
///    ↻ brings in different artists. With no `shuffleSeed` the key is just the
///    weight, i.e. a fully deterministic ranking (what the weekly refresh and
///    the pinned tests rely on).
/// 4. Walk the artists in that order: the first `tasteDoubleSlotArtists` may
///    contribute two tracks, the rest one, until `limit`. If that runs short
///    (few artists), a second pass tops up with extra tracks.
public func selectTasteTracks(
    candidates: [TasteCandidate],
    seeds: TasteSeeds,
    limit: Int = generatedPlaylistTrackLimit,
    shuffleSeed: UInt64? = nil
) -> [TasteCandidate] {
    guard limit > 0 else { return [] }

    func identity(_ song: Song) -> String {
        song.isrc.flatMap { $0.isEmpty ? nil : $0 } ?? titleArtistKey(title: song.title, artist: song.artist)
    }

    // Stable input order first, so the seeded draws below don't depend on how
    // the caller happened to order candidates.
    let ordered = candidates.sorted {
        let a = identity($0.song), b = identity($1.song)
        return a == b ? $0.song.title < $1.song.title : a < b
    }

    var seen = Set<String>()
    var byArtist: [String: [TasteCandidate]] = [:]
    for candidate in ordered {
        let song = candidate.song
        guard candidate.artistScore > 0, !song.title.isEmpty else { continue }
        guard !seeds.hasHeard(
            catalogId: song.catalogId, isrc: song.isrc, title: song.title, artist: song.artist
        ) else { continue }
        // One artist can legitimately surface twice (two seeds pointing at them);
        // the same recording twice is just a duplicate row.
        guard seen.insert(identity(song)).inserted else { continue }
        byArtist[candidate.artistKey, default: []].append(candidate)
    }

    let seeded = shuffleSeed != nil
    var rng = TasteShuffleGenerator(seed: shuffleSeed ?? 0)

    /// 0 = deep cut, 1 = ordinary top song, 2 = signature track.
    func tier(_ c: TasteCandidate) -> Int {
        if c.rank == tasteAlbumTrackRank { return 0 }
        return c.rank < tasteFamiliarRankCutoff ? 2 : 1
    }

    // Iterate artists in a stable order so draws are reproducible per seed.
    var drawn: [(key: String, tracks: [TasteCandidate], draw: Double, tieBreak: String)] = []
    for artistKey in byArtist.keys.sorted() {
        var tracks = byArtist[artistKey]!
        // Random tiebreak WITHIN a tier so ↻ also varies which deep cut.
        var tiebreak: [String: Double] = [:]
        if seeded { for t in tracks { tiebreak[identity(t.song)] = Double.random(in: 0..<1, using: &rng) } }
        tracks.sort {
            let ta = tier($0), tb = tier($1)
            if ta != tb { return ta < tb }
            let ra = tiebreak[identity($0.song)] ?? 0, rb = tiebreak[identity($1.song)] ?? 0
            if ra != rb { return ra < rb }
            return identity($0.song) < identity($1.song)
        }

        let base = tracks.map(\.artistScore).max() ?? 0
        let affinity = tracks
            .map { genreAffinity(of: $0.song.genres, against: seeds.genreWeights) }
            .max() ?? 0
        let weight = base * (1 + tasteGenreBoost * affinity)
        let draw: Double
        if seeded {
            let u = Double.random(in: Double.leastNonzeroMagnitude..<1, using: &rng)
            draw = pow(u, 1 / weight)
        } else {
            draw = weight
        }
        drawn.append((artistKey, tracks, draw, tracks.first.map { identity($0.song) } ?? ""))
    }

    drawn.sort {
        if $0.draw != $1.draw { return $0.draw > $1.draw }
        return $0.tieBreak < $1.tieBreak
    }

    var kept: [TasteCandidate] = []
    kept.reserveCapacity(limit)
    for (index, artist) in drawn.enumerated() {
        let slots = index < tasteDoubleSlotArtists ? 2 : 1
        for track in pickTracks(from: artist.tracks, count: slots) {
            guard kept.count < limit else { return spreadByArtist(kept, artist: { $0.song.artist }) }
            kept.append(track)
        }
    }

    // Too few artists to fill the list — top up with the second track of the
    // artists that only got one. Never more than two per artist.
    if kept.count < limit {
        for artist in drawn.dropFirst(tasteDoubleSlotArtists) {
            guard kept.count < limit, artist.tracks.count > 1 else { continue }
            kept.append(pickTracks(from: artist.tracks, count: 2)[1])
        }
    }
    return spreadByArtist(kept, artist: { $0.song.artist })
}

/// An artist counts as belonging to a genre when at least this share of the
/// tracks we have for them carry its tag.
///
/// Apple tags genres per release, and often loosely: measured on a real device
/// cache, Frank Ocean's "Novacane" and "Swim Good" singles are tagged
/// `Rock` (2 of 26 tracks), Eminem's "Stan" on a Dido compilation is tagged
/// `Rock` (1 of 13), Drake 12%, Tyler 2% — while genuine rock artists sit at
/// 60–100%. Filtering on a single track's tag therefore let a rapper into a
/// "Rock Discoveries" list on the strength of one mislabelled single.
public let tasteArtistGenreShare: Double = 0.25

/// Keeps candidates only from artists who genuinely belong to `genre`, and
/// within them only the tracks tagged with it.
///
/// An artist qualifies when `tasteArtistGenreShare` of their (de-duplicated)
/// tracks carry the tag, **or** the tag is their single most common one — so a
/// small catalogue that is mostly tagged something else can't be argued out of
/// its own genre by a few extra labels.
public func filterCandidates(_ candidates: [TasteCandidate], toGenre genre: String) -> [TasteCandidate] {
    let key = genre.lowercased()
    func has(_ c: TasteCandidate) -> Bool { c.song.genres.contains { $0.lowercased() == key } }

    var seen: [String: Set<String>] = [:]
    var matching: [String: Set<String>] = [:]
    var tagCounts: [String: [String: Int]] = [:]
    for c in candidates {
        let id = c.song.isrc.flatMap { $0.isEmpty ? nil : $0 }
            ?? titleArtistKey(title: c.song.title, artist: c.song.artist)
        guard seen[c.artistKey, default: []].insert(id).inserted else { continue }
        if has(c) { matching[c.artistKey, default: []].insert(id) }
        for g in Set(c.song.genres.map { $0.lowercased() }) { tagCounts[c.artistKey, default: [:]][g, default: 0] += 1 }
    }

    var qualifies = Set<String>()
    for (artist, ids) in seen {
        let m = matching[artist]?.count ?? 0
        guard m > 0 else { continue }
        let share = Double(m) / Double(ids.count)
        let top = tagCounts[artist]?.max { $0.value < $1.value }?.key
        if share >= tasteArtistGenreShare || top == key { qualifies.insert(artist) }
    }
    return candidates.filter { qualifies.contains($0.artistKey) && has($0) }
}

/// True when `releaseDate` (`yyyy-MM-dd`) is within the last `withinDays` days
/// and not in the future — an album dated tomorrow isn't playable yet, so it
/// must not appear in "New From Artists Like Yours".
public func isRecentRelease(_ releaseDate: String, withinDays: Int, now: Date = Date()) -> Bool {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    guard let date = f.date(from: String(releaseDate.prefix(10))) else { return false }
    guard date <= now else { return false }
    return now.timeIntervalSince(date) <= Double(withinDays) * 86_400
}
