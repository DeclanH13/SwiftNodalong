import Foundation

/// How closely two people's listening resembles each other's.
///
/// This is the ranking basis for every generated playlist lens. It exists
/// because Nodalong has **no genre, mood, tempo or audio-feature data** —
/// `CatalogTrack` carries title/artist/album/isrc only — so "taste" can only be
/// inferred from overlap of the actual tracks and artists two people listen to.
/// That turns out to be a strength rather than a limitation: the overlap is real
/// listening, not an inferred label, and it is explainable to the user ("you and
/// Aidooo both play these 12 artists").
///
/// Deliberately knows nothing about *relationships* — a follow, a nearby
/// stranger and someone who nodded your track are all just a `PersonTaste` here.
/// The caller supplies the pool and a `skew`; see `PlaylistLens` in the app
/// layer for what each pool means.

/// A normalized summary of what one person listens to.
///
/// Artists are normalized through `primaryArtist(_:)` and lowercased so a
/// featured credit ("Dahi & Childish Gambino") collapses onto the primary
/// artist — the same normalization `groupByAlbum`/`groupByArtist` already use,
/// so a track counts as "the same artist" everywhere in the app.
public struct TasteProfile: Sendable, Equatable {
    public private(set) var trackIds: Set<String>
    public private(set) var artists:  Set<String>
    /// Normalized key -> first-seen original spelling, for showing artist names
    /// to people. Deliberately excluded from `==` — it's presentation only.
    public private(set) var artistDisplay: [String: String] = [:]

    public init(trackIds: Set<String> = [], artists: Set<String> = []) {
        self.trackIds = trackIds
        self.artists  = artists
    }

    public static func == (a: TasteProfile, b: TasteProfile) -> Bool {
        a.trackIds == b.trackIds && a.artists == b.artists
    }

    /// Original-casing name for a normalized artist key, if one was recorded.
    public func displayName(for key: String) -> String? { artistDisplay[key] }

    /// Adds one listened-to track. An empty `catalogId` contributes only its
    /// artist — better than dropping the signal entirely, since artist overlap
    /// is the heavier-weighted dimension anyway.
    public mutating func add(catalogId: String?, artist: String) {
        if let catalogId, !catalogId.isEmpty { trackIds.insert(catalogId) }
        let normalized = primaryArtist(artist).lowercased()
        if !normalized.isEmpty {
            artists.insert(normalized)
            if artistDisplay[normalized] == nil { artistDisplay[normalized] = primaryArtist(artist) }
        }
    }

    public func merging(_ other: TasteProfile) -> TasteProfile {
        var merged = TasteProfile(
            trackIds: trackIds.union(other.trackIds),
            artists:  artists.union(other.artists)
        )
        merged.artistDisplay = artistDisplay.merging(other.artistDisplay) { mine, _ in mine }
        return merged
    }

    public var isEmpty: Bool { trackIds.isEmpty && artists.isEmpty }

    public static func from(posts: [Post]) -> TasteProfile {
        var p = TasteProfile()
        for post in posts { p.add(catalogId: post.catalogId, artist: post.artist) }
        return p
    }

    public static func from(spotlights: [SpotlightTrack]) -> TasteProfile {
        var p = TasteProfile()
        for s in spotlights { p.add(catalogId: s.catalogId, artist: s.artist) }
        return p
    }

    public static func from(library: [LibraryTrackDoc]) -> TasteProfile {
        var p = TasteProfile()
        for t in library { p.add(catalogId: t.catalogId, artist: t.artist) }
        return p
    }
}

/// Weight given to artist overlap vs exact-track overlap.
///
/// Artists dominate deliberately. Exact `catalogId` overlap is **sparse** — two
/// people can share a genuine taste and still overlap on very few identical
/// recordings — whereas artist overlap is dense and a far better proxy. A pure
/// track-Jaccard ranking would score almost everyone at ~0 and rank noise.
public let tasteArtistWeight: Double = 0.7
public let tasteTrackWeight:  Double = 0.3

/// Below this, nobody in the pool genuinely resembles the user; prefer an
/// honest empty state over a playlist of noise.
public let minimumTasteAffinity: Double = 0.02

/// Weight given to a candidate we have **no** stage-1 signal for.
///
/// Stage-1 taste comes only from the spotlights embedded on a profile, and most
/// people have never spotlit anything — so their `TasteProfile` is empty and a
/// plain quality floor drops them. That is the wrong call: an empty profile
/// means "no data", not "bad match", and dropping it is a large part of why the
/// `nearby` and `admirers` pools collapse back onto people you already follow.
/// Unknowns are kept at a baseline that always ranks *below* anyone with real
/// overlap, so they only ever fill slots nobody better wanted.
public let unknownTasteAffinity: Double = 0.01

/// Affinity in `0...1`.
///
/// Normalized by **their** set size, not by the union (Jaccard). That's
/// deliberate: Jaccard punishes someone with a small library for being small,
/// even when everything they play is something you also play. The question that
/// actually matters for recommending is "how much of their taste do I already
/// share", which is coverage of *theirs*.
public func tasteAffinity(mine: TasteProfile, theirs: TasteProfile) -> Double {
    let artistOverlap = theirs.artists.isEmpty
        ? 0
        : Double(mine.artists.intersection(theirs.artists).count) / Double(theirs.artists.count)
    let trackOverlap = theirs.trackIds.isEmpty
        ? 0
        : Double(mine.trackIds.intersection(theirs.trackIds).count) / Double(theirs.trackIds.count)

    // Renormalize when a dimension is missing entirely, so someone we only have
    // artist data for isn't capped at 0.7 of the score they deserve.
    switch (theirs.artists.isEmpty, theirs.trackIds.isEmpty) {
    case (true, true):   return 0
    case (false, true):  return artistOverlap
    case (true, false):  return trackOverlap
    case (false, false): return tasteArtistWeight * artistOverlap + tasteTrackWeight * trackOverlap
    }
}

/// One candidate person plus the lens's own multiplier.
///
/// `skew` is how a lens expresses its premise — e.g. the "they liked yours" lens
/// passes nod strength here so someone who nodded twelve of your tracks outranks
/// someone who nodded one. A lens with no extra opinion passes `1`.
public struct PersonTaste: Sendable {
    public let uid: String
    public let username: String
    public let profile: TasteProfile
    public let skew: Double

    public init(uid: String, username: String, profile: TasteProfile, skew: Double = 1) {
        self.uid = uid
        self.username = username
        self.profile = profile
        self.skew = skew
    }
}

public struct RankedPerson: Sendable, Equatable {
    public let uid: String
    public let username: String
    public let affinity: Double
    /// `affinity × skew` — what candidate scoring actually multiplies by.
    public let weight: Double

    public init(uid: String, username: String, affinity: Double, weight: Double) {
        self.uid = uid
        self.username = username
        self.affinity = affinity
        self.weight = weight
    }
}

/// Ranks a lens's pool, best match first, dropping anyone below the quality floor.
///
/// Sorted by `weight` with `uid` as a tiebreak so the result is deterministic —
/// two people with identical overlap must not reorder between runs, or a
/// regenerated playlist would churn for no reason.
public func rankPeople(
    mine: TasteProfile,
    candidates: [PersonTaste],
    limit: Int
) -> [RankedPerson] {
    guard !mine.isEmpty, limit > 0 else { return [] }

    // Split into explicit steps deliberately: as one chained expression this
    // exceeded the Swift type-checker's time budget and failed to compile.
    var scored: [RankedPerson] = []
    scored.reserveCapacity(candidates.count)

    for c in candidates {
        // No data ≠ bad match. Someone we know nothing about stays eligible at
        // a baseline; someone we *do* have data on who genuinely doesn't
        // overlap is still dropped.
        let affinity: Double
        if c.profile.isEmpty {
            affinity = unknownTasteAffinity
        } else {
            let measured: Double = tasteAffinity(mine: mine, theirs: c.profile)
            guard measured >= minimumTasteAffinity else { continue }
            affinity = measured
        }
        let weight: Double = affinity * c.skew
        guard weight > 0 else { continue }
        scored.append(
            RankedPerson(uid: c.uid, username: c.username, affinity: affinity, weight: weight)
        )
    }

    scored.sort { a, b in
        a.weight == b.weight ? a.uid < b.uid : a.weight > b.weight
    }

    return Array(scored.prefix(limit))
}
