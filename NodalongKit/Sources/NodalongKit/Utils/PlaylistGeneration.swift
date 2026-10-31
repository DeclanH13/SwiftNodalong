import Foundation

/// Turning "these people, ranked by taste" into "these 25 tracks".
///
/// Pure and deterministic so the scoring — the part where subtle bugs actually
/// live — is unit-testable without Firebase or MusicKit.

/// How deliberate a listening signal is.
///
/// Spotlights are capped at 3 per day per user, which is exactly what makes them
/// the strongest signal in the app: a spotlight costs the giver something, so it
/// means far more than a play. Replays are the next best thing — `Post.replayCount`
/// only increments when a track genuinely moves back up someone's recents, so it
/// is a real "I chose this again", not just an autoplay.
public enum TrackSignal: Sendable, Equatable {
    case spotlight
    case replayedRecent
    case recentPlay

    public var weight: Double {
        switch self {
        case .spotlight:      return 3.0
        case .replayedRecent: return 2.0
        case .recentPlay:     return 1.0
        }
    }
}

/// How much a lens cares about each kind of signal.
///
/// This is what gives a lens a *character* rather than just a source. Without
/// it, two lenses drawing on the same people produce byte-identical playlists —
/// the normal case on a small follow graph, where `circle`, `nearby`,
/// `admirers` and `blend` routinely all resolve to the same one or two people.
public struct SignalWeights: Sendable, Equatable {
    public let spotlight: Double
    public let replayedRecent: Double
    public let recentPlay: Double

    public init(spotlight: Double, replayedRecent: Double, recentPlay: Double) {
        self.spotlight      = spotlight
        self.replayedRecent = replayedRecent
        self.recentPlay     = recentPlay
    }

    public func weight(for signal: TrackSignal) -> Double {
        switch signal {
        case .spotlight:      return spotlight
        case .replayedRecent: return replayedRecent
        case .recentPlay:     return recentPlay
        }
    }

    /// The even read: deliberate > repeated > incidental. Derived from
    /// `TrackSignal.weight` so there is one source of truth for the defaults.
    public static let balanced = SignalWeights(
        spotlight:      TrackSignal.spotlight.weight,
        replayedRecent: TrackSignal.replayedRecent.weight,
        recentPlay:     TrackSignal.recentPlay.weight
    )
}

/// One person's evidence for one track.
public struct TrackContribution: Sendable {
    public let catalogId: String
    public let artist: String
    public let personUid: String
    public let personUsername: String
    public let personWeight: Double
    public let signal: TrackSignal

    public init(
        catalogId: String,
        artist: String,
        personUid: String,
        personUsername: String,
        personWeight: Double,
        signal: TrackSignal
    ) {
        self.catalogId = catalogId
        self.artist = artist
        self.personUid = personUid
        self.personUsername = personUsername
        self.personWeight = personWeight
        self.signal = signal
    }
}

public struct SelectedTrack: Sendable, Equatable {
    public let catalogId: String
    public let artist: String
    /// The strongest single contributor — who the playlist credits this track to.
    public let addedByUid: String
    public let addedByUsername: String
    public let score: Double
    /// How many distinct people contributed. Surfacing this is what lets the UI
    /// say "Aidooo and 2 others", which is the whole point of the feature.
    public let contributorCount: Int

    public init(
        catalogId: String,
        artist: String,
        addedByUid: String,
        addedByUsername: String,
        score: Double,
        contributorCount: Int
    ) {
        self.catalogId = catalogId
        self.artist = artist
        self.addedByUid = addedByUid
        self.addedByUsername = addedByUsername
        self.score = score
        self.contributorCount = contributorCount
    }
}

public let generatedPlaylistTrackLimit = 25
public let generatedPlaylistMaxPerArtist = 2

/// Scores contributions and picks the final track list.
///
/// - `heard` is everything the user already has (library + recents). A generated
///   playlist that hands you back your own library is worthless, so this filter
///   is the feature, not an optimisation.
/// - **Corroboration is emergent, not special-cased**: a track two people both
///   love contributes two summed terms and naturally outranks one person's
///   outlier. That is the collaborative-filtering core, and it falls out of the
///   sum without any separate boost.
/// - `maxPerArtist` stops the list collapsing into one artist's discography,
///   which is the most likely way this reads as broken. Applied greedily after
///   sorting, so the artist's *best* tracks survive the cap.
///
/// Ties break on `catalogId` so regenerating with unchanged inputs produces an
/// unchanged playlist rather than churning the user's list.
public func selectTracks(
    contributions: [TrackContribution],
    excluding heard: Set<String>,
    signalWeights: SignalWeights = .balanced,
    limit: Int = generatedPlaylistTrackLimit,
    maxPerArtist: Int = generatedPlaylistMaxPerArtist
) -> [SelectedTrack] {
    guard limit > 0 else { return [] }

    struct Accumulator {
        var artist: String
        var score: Double
        var bestUid: String
        var bestUsername: String
        var bestContribution: Double
        var contributors: Set<String>
    }

    var byTrack: [String: Accumulator] = [:]

    for c in contributions {
        guard !c.catalogId.isEmpty,
              !heard.contains(c.catalogId),
              c.personWeight > 0 else { continue }

        let contribution = c.personWeight * signalWeights.weight(for: c.signal)

        if var existing = byTrack[c.catalogId] {
            existing.score += contribution
            existing.contributors.insert(c.personUid)
            // Credit the strongest single voice, tie-broken by uid for determinism.
            if contribution > existing.bestContribution
                || (contribution == existing.bestContribution && c.personUid < existing.bestUid) {
                existing.bestContribution = contribution
                existing.bestUid = c.personUid
                existing.bestUsername = c.personUsername
            }
            byTrack[c.catalogId] = existing
        } else {
            byTrack[c.catalogId] = Accumulator(
                artist: c.artist,
                score: contribution,
                bestUid: c.personUid,
                bestUsername: c.personUsername,
                bestContribution: contribution,
                contributors: [c.personUid]
            )
        }
    }

    let ranked = byTrack
        .map { catalogId, a in
            SelectedTrack(
                catalogId: catalogId,
                artist: a.artist,
                addedByUid: a.bestUid,
                addedByUsername: a.bestUsername,
                score: a.score,
                contributorCount: a.contributors.count
            )
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.catalogId < $1.catalogId
        }

    var perArtist: [String: Int] = [:]
    var picked: [SelectedTrack] = []

    for track in ranked {
        guard picked.count < limit else { break }
        // Same normalization the rest of the app groups artists by, so a
        // featured credit can't sneak past the cap as a "different" artist.
        let key = primaryArtist(track.artist).lowercased()
        let used = perArtist[key, default: 0]
        guard used < maxPerArtist else { continue }
        perArtist[key] = used + 1
        picked.append(track)
    }

    return spreadByArtist(picked, artist: \.artist)
}
