import Foundation

/// Turning "what this person listens to" into "these artists, this strongly".
///
/// This is the seeding half of the taste lens — the only generated playlist
/// that finds music from the CATALOG rather than from other people. Pure and
/// deterministic so the scoring, which is where subtle bugs actually live, is
/// unit-testable without Firebase or MusicKit.
///
/// Distinct from `TasteAffinity`'s `TasteProfile`, which is a flat set used to
/// compare two *people*. Recommending needs weights and an ordering: "which
/// artists matter most to me" is a different question from "how much do we
/// overlap", and a set can't answer it.

/// How deliberate one of MY OWN listening signals is — the mirror of
/// `TrackSignal`, which weighs other people's.
///
/// The ordering is the whole argument for this feature existing alongside
/// Apple's own recommender. Apple sees plays. It does not know what I chose to
/// **spotlight** in Nodalong — capped at 3/day, so it costs me something — or
/// what I deliberately kept on my **Shelf**. Weighting those above plays is
/// what makes the result mine rather than a weaker copy of Apple's.
public enum TasteSignal: Sendable, Equatable, CaseIterable {
    /// A deliberate "listen to this" pick, capped at 3 per day.
    case spotlight
    /// An explicit keep — saved to the Shelf.
    case shelfSave
    /// Played again after already having been played: a re-choice, not autoplay.
    case replay
    /// An ordinary recent play. May well have been an accident.
    case play
    /// Saved in the user's own Apple Music library, outside Nodalong.
    ///
    /// A genuine keep — you chose to own it — but weighted below `shelfSave`
    /// deliberately: a Shelf save is a decision made *in this app, recently*,
    /// while an Apple Music library can be a decade of accumulated saves
    /// including plenty someone no longer listens to. Above `play`, which may
    /// well have been an accident.
    case appleLibrary

    public var weight: Double {
        switch self {
        case .spotlight:    return 3.0
        case .shelfSave:    return 2.5
        case .appleLibrary: return 1.5
        case .replay:       return 2.0
        case .play:         return 1.0
        }
    }
}

/// One artist I listen to, and how much they matter.
public struct SeededArtist: Sendable, Equatable {
    /// `primaryArtist(_:).lowercased()` — the same normalization
    /// `groupByAlbum` / `groupByArtist` / `TasteProfile` use, so "the same
    /// artist" means the same thing here as everywhere else in the app.
    public let key: String
    /// Kept unnormalized for the playlist description, which names real
    /// artists back to the user.
    public let displayName: String
    public let weight: Double

    public init(key: String, displayName: String, weight: Double) {
        self.key = key
        self.displayName = displayName
        self.weight = weight
    }
}

/// Everything the taste lens needs about one person, derived once.
public struct TasteSeeds: Sendable, Equatable {
    /// Heaviest first, ties broken on `key` so a regenerated playlist doesn't
    /// churn for no reason.
    public let artists: [SeededArtist]
    /// Normalized `0...1` — the share of my listening weight each genre carries.
    public let genreWeights: [String: Double]

    /// 🔴 EVERY artist I listen to, before `artists` is truncated to the seed
    /// limit — which is a different job from seeding and must not share its
    /// cut.
    ///
    /// `artists` is deliberately capped (8) because expanding the similarity
    /// graph from every artist in a library would be enormous. But
    /// `knownArtistKeys` — the exclusion set that decides what counts as a
    /// *discovery* — was being derived from that same truncated list, so in a
    /// 150-artist library the other 142 artists were all eligible to be
    /// handed back as suggestions. That is exactly the reported symptom: "it
    /// shows a lot of artists I already listen to."
    ///
    /// Empty when a `TasteSeeds` is constructed directly (tests, fixtures);
    /// `knownArtistKeys` unions it with the seed keys so that case still
    /// behaves as before.
    public let allArtistKeys: Set<String>

    /// Three different keys for "already heard", because a candidate arriving
    /// from MusicKit has **no `catalogId`** — that's a Firestore concept
    /// assigned at ingest. It can only be recognised by ISRC, or by normalized
    /// title+artist when even the ISRC is missing.
    public let heardCatalogIds: Set<String>
    public let heardIsrcs: Set<String>
    public let heardTitleArtist: Set<String>

    public init(
        artists: [SeededArtist],
        genreWeights: [String: Double],
        heardCatalogIds: Set<String>,
        heardIsrcs: Set<String>,
        heardTitleArtist: Set<String>,
        allArtistKeys: Set<String> = []
    ) {
        self.artists = artists
        self.genreWeights = genreWeights
        self.allArtistKeys = allArtistKeys
        self.heardCatalogIds = heardCatalogIds
        self.heardIsrcs = heardIsrcs
        self.heardTitleArtist = heardTitleArtist
    }

    public var isEmpty: Bool { artists.isEmpty }

    /// The artist keys I already listen to — what stage 1 subtracts, since an
    /// artist I already play is not a discovery.
    /// Everything that disqualifies an artist from being a "discovery".
    /// Unions the full set with the seed keys so a directly-constructed
    /// `TasteSeeds` (no `allArtistKeys`) still excludes its own seeds.
    public var knownArtistKeys: Set<String> { allArtistKeys.union(artists.map(\.key)) }

    /// Recognises an already-heard track across all three keys.
    public func hasHeard(catalogId: String?, isrc: String?, title: String, artist: String) -> Bool {
        if let catalogId, !catalogId.isEmpty, heardCatalogIds.contains(catalogId) { return true }
        if let isrc, !isrc.isEmpty, heardIsrcs.contains(isrc) { return true }
        return heardTitleArtist.contains(titleArtistKey(title: title, artist: artist))
    }
}

/// Last-resort identity for a recording with no id and no ISRC. Runs both
/// halves through the same normalization the rest of the app groups by, so
/// "Song (feat. X) - Remastered" by "A & B" matches plain "Song" by "A".
public func titleArtistKey(title: String, artist: String) -> String {
    "\(stripSearchNoise(title).lowercased())|\(primaryArtist(artist).lowercased())"
}

/// Builds the weighted picture of one person's taste.
///
/// A `Post` with `replayCount > 0` counts as a `.replay` rather than a `.play`
/// — `syncRecentTracks` only increments that when a track genuinely moves back
/// up the user's recents, so it's a real re-choice.
///
/// Genre weight comes from the Shelf, which is the only source that carries
/// `genres` (overlaid from the catalog on read). Recents and spotlights
/// contribute artists but no genre, which is fine: genre is a scoring modifier
/// downstream, never a gate.
public func buildTasteSeeds(
    library: [LibraryTrackDoc],
    recents: [Post],
    spotlights: [SpotlightTrack],
    /// The user's own Apple Music library, read live at generation time and
    /// never persisted — see `AppleMusicService.getSavedTracks`.
    ///
    /// Both a seed source and, more importantly, an exclusion source: an
    /// artist you own on Apple Music is not a discovery just because you
    /// never happened to save them to your Nodalong Shelf. Without this,
    /// `allArtistKeys` only knew about Shelf saves, recents and spotlights,
    /// which for a heavy Apple Music listener is a small fraction of what
    /// they actually own.
    appleLibrary: [Song] = [],
    artistLimit: Int = 8,
    seedGenre: String? = nil,
    /// The user's own corrections — see `TasteOverrides`. Blocked artists are
    /// never seeds AND are added to the known set, so they can never come back
    /// as a "discovery" even if the user has never listened to them.
    overrides: TasteOverrides = TasteOverrides()
) -> TasteSeeds {
    // 🔴 `seedGenre` narrows only WHICH ARTISTS SEED the expansion — never
    // what counts as already-heard or already-known.
    //
    // A genre-scoped run wants its seeds drawn from the hip-hop you play, so
    // the similarity graph expands somewhere hip-hop. But if `heard` and
    // `allArtistKeys` were narrowed the same way, it would happily hand back
    // a track you own under a different genre tag, and artists you listen to
    // outside that genre would count as "discoveries" — which is exactly the
    // bug `allArtistKeys` exists to prevent, reintroduced through a side
    // door. So the genre filter is applied at `note(...)` only; `noteHeard`
    // and the full artist set always see everything.
    let genreKey = seedGenre?.lowercased().trimmingCharacters(in: .whitespaces)
    func matchesSeedGenre(_ genres: [String]) -> Bool {
        guard let genreKey, !genreKey.isEmpty else { return true }
        return genres.contains { $0.lowercased() == genreKey }
    }

    // A genre-scoped run may only SEED from artists who genuinely belong to the
    // genre, not from anyone with one stray tagged track — a rapper with a
    // single Rock-tagged single would otherwise seed the "Rock" run and expand
    // into rap. Measured per artist over the Shelf + Apple Music library; see
    // `tasteArtistGenreShare`.
    var seedableArtists: Set<String>? = nil
    if let genreKey, !genreKey.isEmpty {
        var total: [String: Int] = [:]
        var match: [String: Int] = [:]
        func tally(_ artist: String, _ genres: [String]) {
            let k = primaryArtist(artist).lowercased()
            total[k, default: 0] += 1
            if genres.contains(where: { $0.lowercased() == genreKey }) { match[k, default: 0] += 1 }
        }
        for t in library { tally(t.artist, t.genres) }
        for t in appleLibrary { tally(t.artist, t.genres) }
        seedableArtists = Set(match.compactMap { k, m in
            Double(m) / Double(total[k] ?? 1) >= tasteArtistGenreShare ? k : nil
        })
    }
    func isSeedable(_ artist: String) -> Bool {
        guard let seedableArtists else { return true }
        return seedableArtists.contains(primaryArtist(artist).lowercased())
    }
    var artistWeight: [String: Double] = [:]
    var artistName:   [String: String] = [:]
    var genreWeight:  [String: Double] = [:]

    var heardCatalogIds = Set<String>()
    var heardIsrcs      = Set<String>()
    var heardTitleArtist = Set<String>()
    /// Every artist seen, regardless of genre scoping — the exclusion set.
    var allArtistKeys   = Set<String>()

    func note(artist: String, weight: Double) {
        let key = primaryArtist(artist).lowercased()
        guard !key.isEmpty else { return }
        let m = overrides.multiplier(forKey: key)
        guard m > 0 else { return }
        artistWeight[key, default: 0] += weight * m
        // First display name wins, so the description doesn't flip between
        // spellings of the same artist between runs.
        if artistName[key] == nil { artistName[key] = primaryArtist(artist) }
    }

    func noteHeard(catalogId: String?, isrc: String?, title: String, artist: String) {
        if let catalogId, !catalogId.isEmpty { heardCatalogIds.insert(catalogId) }
        if let isrc, !isrc.isEmpty { heardIsrcs.insert(isrc) }
        heardTitleArtist.insert(titleArtistKey(title: title, artist: artist))
    }

    for track in library {
        // Always recorded — see the note above.
        noteHeard(catalogId: track.catalogId, isrc: track.isrc, title: track.title, artist: track.artist)
        allArtistKeys.insert(primaryArtist(track.artist).lowercased())
        guard matchesSeedGenre(track.genres), isSeedable(track.artist) else { continue }
        note(artist: track.artist, weight: TasteSignal.shelfSave.weight)
        let m = overrides.multiplier(forKey: primaryArtist(track.artist).lowercased())
        for genre in track.genres where !genre.isEmpty && m > 0 {
            genreWeight[genre.lowercased(), default: 0] += TasteSignal.shelfSave.weight * m
        }
    }

    // `Post` and `SpotlightTrack` carry no genres (only `LibraryTrackDoc`
    // does — genre is captured at ingest onto the catalog row and mirrored
    // there). So in a genre-scoped run they can't be judged and are excluded
    // from SEEDING rather than guessed at; they still count fully towards
    // heard and known, which is what matters for correctness.
    for track in appleLibrary {
        noteHeard(catalogId: track.catalogId, isrc: track.isrc, title: track.title, artist: track.artist)
        allArtistKeys.insert(primaryArtist(track.artist).lowercased())
        guard matchesSeedGenre(track.genres), isSeedable(track.artist) else { continue }
        note(artist: track.artist, weight: TasteSignal.appleLibrary.weight)
        let m = overrides.multiplier(forKey: primaryArtist(track.artist).lowercased())
        for genre in track.genres where !genre.isEmpty && m > 0 {
            genreWeight[genre.lowercased(), default: 0] += TasteSignal.appleLibrary.weight * m
        }
    }

    for post in recents {
        noteHeard(catalogId: post.catalogId, isrc: post.isrc, title: post.title, artist: post.artist)
        allArtistKeys.insert(primaryArtist(post.artist).lowercased())
        guard genreKey == nil else { continue }
        let signal: TasteSignal = post.replayCount > 0 ? .replay : .play
        note(artist: post.artist, weight: signal.weight)
    }

    for spotlight in spotlights {
        noteHeard(catalogId: spotlight.catalogId, isrc: nil, title: spotlight.title, artist: spotlight.artist)
        allArtistKeys.insert(primaryArtist(spotlight.artist).lowercased())
        guard genreKey == nil else { continue }
        note(artist: spotlight.artist, weight: TasteSignal.spotlight.weight)
    }

    // Split into explicit steps deliberately: as one chained map/sorted this
    // exceeded the Swift type-checker's time budget and failed to compile
    // outright — the same trap `rankPeople` hit and documents.
    var ranked: [SeededArtist] = []
    ranked.reserveCapacity(artistWeight.count)
    for (key, weight) in artistWeight {
        let display: String = artistName[key] ?? key
        ranked.append(SeededArtist(key: key, displayName: display, weight: weight))
    }
    ranked.sort { a, b in
        a.weight == b.weight ? a.key < b.key : a.weight > b.weight
    }

    // Normalized so `genreAffinity` downstream is a comparable 0...1 share
    // regardless of how large a library it was derived from.
    let genreTotal: Double = genreWeight.values.max() ?? 0
    var normalizedGenres: [String: Double] = [:]
    if genreTotal > 0 {
        for (genre, weight) in genreWeight { normalizedGenres[genre] = weight / genreTotal }
    }

    return TasteSeeds(
        artists: Array(ranked.prefix(max(0, artistLimit))),
        genreWeights: normalizedGenres,
        heardCatalogIds: heardCatalogIds,
        heardIsrcs: heardIsrcs,
        heardTitleArtist: heardTitleArtist,
        // The FULL set, not `ranked.prefix(...)` and not genre-scoped — see
        // `allArtistKeys` and the `seedGenre` note above.
        allArtistKeys: allArtistKeys.union(overrides.blocked).subtracting([""])
    )
}

extension TasteSeeds {
    /// The same exclusions with a single seed — "Because you listen to X".
    /// Heard and known-artist sets are untouched, so narrowing the seed can
    /// never let something you already own back in.
    public func narrowedTo(artistKey: String) -> TasteSeeds {
        TasteSeeds(
            artists: artists.filter { $0.key == artistKey },
            genreWeights: genreWeights,
            heardCatalogIds: heardCatalogIds,
            heardIsrcs: heardIsrcs,
            heardTitleArtist: heardTitleArtist,
            allArtistKeys: allArtistKeys
        )
    }
}
