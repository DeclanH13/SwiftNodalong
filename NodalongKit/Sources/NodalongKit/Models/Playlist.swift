import Foundation

/// Who can see a playlist. Enforced client-side today and (once shipped) by
/// Firestore security rules — see `firestore.rules`.
public enum PlaylistVisibility: String, Codable, Hashable, Sendable, CaseIterable {
    /// Only the owner.
    case `private`
    /// The owner and their mutual-follow friends (default).
    case friends
    /// Anyone.
    case `public`
}

/// How a playlist came to exist. Stored flat (`source` + `partyId`) rather than
/// as an enum-with-payload so Firestore can query it and the schema stays simple.
public enum PlaylistSource: String, Codable, Hashable, Sendable {
    /// Hand-built by the owner.
    case manual
    /// Frozen from an ended listening party (`partyId` points at the source).
    case party
    /// Built by `PlaylistGenerator` from other people's listening. See `lens`
    /// for *whose* listening — `source` answers how it was made, `lens` answers
    /// from whom; they are separate axes and shouldn't be conflated into one.
    case generated
}

/// Which pool of real people a generated playlist drew from.
///
/// Each lens is deliberately explainable in one sentence — that is the whole
/// point of building these from people rather than from an algorithm, and it is
/// what the UI puts on the tile.
public enum PlaylistLens: String, Codable, Hashable, Sendable, CaseIterable {
    /// People you follow whose taste most overlaps yours.
    case circle
    /// People physically near you (NearMe).
    case nearby
    /// People who nodded your tracks.
    case admirers
    /// All of the above, weighted.
    case blend
    /// The only lens sourced from the CATALOG rather than from people: new
    /// music found by expanding your own most-listened artists through Apple's
    /// similarity graph. See `TasteSeeds` / `TasteDiscovery`.
    case taste
    /// Catalog-sourced: tracks you haven't heard from artists you already love.
    case deepCuts
    /// Catalog-sourced: recent releases from artists similar to yours.
    case newFromSimilar
    /// Catalog-sourced: discovery built from ONE of your artists
    /// (`Playlist.variant` names it).
    case becauseArtist

    /// True for every lens sourced from the Apple Music CATALOG rather than from
    /// other people. These have no pool of people, so they never enter the
    /// people pipeline and don't sit under "Made for you, by real people".
    public var isCatalogSourced: Bool {
        switch self {
        case .taste, .deepCuts, .newFromSimilar, .becauseArtist: return true
        case .circle, .nearby, .admirers, .blend:                return false
        }
    }

    public var title: String {
        switch self {
        case .circle:   return "From Your Circle"
        case .nearby:   return "Around You"
        case .admirers: return "They Liked Yours"
        case .blend:    return "Your Blend"
        case .taste:    return "From Your Taste"
        case .deepCuts: return "Deep Cuts"
        case .newFromSimilar: return "New From Artists Like Yours"
        case .becauseArtist:  return "Because You Listen To…"
        }
    }

    public var tagline: String {
        switch self {
        case .circle:   return "People you follow, who listen like you"
        case .nearby:   return "What people around you are playing"
        case .admirers: return "From people who liked your music"
        case .blend:    return "Everyone whose taste matches yours"
        case .taste:    return "New music, from what you actually play"
        case .deepCuts: return "Songs you haven't heard from artists you love"
        case .newFromSimilar: return "Fresh releases from artists like yours"
        case .becauseArtist:  return "More like one of your artists"
        }
    }

    /// The kind of listening this lens leans on.
    ///
    /// Lenses used to differ only in *which people* they drew from, so any two
    /// whose pools overlapped produced identical playlists — which is the norm
    /// on a small follow graph, not an edge case. Weighting the signals
    /// differently gives each lens its own character even when the people are
    /// the same.
    public var signalWeights: SignalWeights {
        switch self {
        // Your people's deliberate picks. A spotlight is capped at 3/day, so it
        // costs the giver something — lean on it hard here.
        case .circle:   return SignalWeights(spotlight: 5.0, replayedRecent: 1.5, recentPlay: 0.4)
        // What is actually being played around you, right now.
        case .nearby:   return SignalWeights(spotlight: 1.5, replayedRecent: 1.0, recentPlay: 2.5)
        // Deep cuts: what people who liked your music keep coming back to.
        case .admirers: return SignalWeights(spotlight: 2.0, replayedRecent: 3.5, recentPlay: 0.8)
        // No opinion of its own — the even read across everything.
        case .blend:    return .balanced
        // Unused: `SignalWeights` weighs OTHER PEOPLE's signals, and this lens
        // has no people in it. Its own weighting of MY signals lives in
        // `TasteSignal`. Returning the neutral value rather than a fabricated
        // one, so nothing reads meaning into it.
        case .taste, .deepCuts, .newFromSimilar, .becauseArtist: return .balanced
        }
    }
}

/// A user-owned collection of tracks stored at `playlists/{id}`.
///
/// The playlist doc holds its own metadata (title/visibility/…); its tracks live
/// in the `playlists/{id}/tracks` subcollection as slim `PlaylistTrack` docs that
/// overlay metadata from the shared catalog on read.
///
/// `id` is the Firestore documentID and is NOT part of the stored payload — the
/// read layer injects it after decoding (`CodingKeys` omits it).
public struct Playlist: Codable, Identifiable, Hashable, Sendable {
    /// Firestore documentID. Empty until set by the read layer.
    public var id: String
    public let ownerUid: String
    public var ownerUsername: String
    public var ownerAvatarEmoji: String?
    public var ownerAvatarColor: String?
    public var title: String
    public var description: String?
    /// Cover image URL — derived from the first track's artwork (or a custom
    /// upload later). May be empty; render falls back to a placeholder.
    public var coverArtwork: String
    public var visibility: PlaylistVisibility
    public let source: PlaylistSource
    /// Which pool of people this was generated from, when `source == .generated`.
    public let lens: PlaylistLens?
    /// The party this playlist was frozen from, when `source == .party`.
    public let partyId: String?
    /// Which genre this was scoped to, when it's a genre-specific discovery
    /// playlist. `nil` for every other playlist, including the general taste
    /// one.
    ///
    /// Part of a generated playlist's IDENTITY, not just a label: a user has
    /// one `.taste` playlist per genre plus the general one, so
    /// `getGeneratedPlaylist` has to match on `(lens, genre)` or they would
    /// all overwrite each other.
    public let genre: String?
    /// The seed artist's display name for a `.becauseArtist` playlist; `nil`
    /// for everything else. Part of the identity alongside `lens` and `genre`.
    public let variant: String?
    /// Everyone who contributed a track (host + participants for party playlists;
    /// just the owner for manual ones). Used to surface a frozen party playlist
    /// on every participant's profile and to gate reads.
    public var contributorUids: [String]
    public var trackCount: Int
    public let createdAt: Double
    public var updatedAt: Double

    public init(
        id: String = "",
        ownerUid: String,
        ownerUsername: String,
        ownerAvatarEmoji: String? = nil,
        ownerAvatarColor: String? = nil,
        title: String,
        description: String? = nil,
        coverArtwork: String = "",
        visibility: PlaylistVisibility = .friends,
        source: PlaylistSource = .manual,
        lens: PlaylistLens? = nil,
        partyId: String? = nil,
        genre: String? = nil,
        variant: String? = nil,
        contributorUids: [String] = [],
        trackCount: Int = 0,
        createdAt: Double,
        updatedAt: Double
    ) {
        self.id = id
        self.ownerUid = ownerUid
        self.ownerUsername = ownerUsername
        self.ownerAvatarEmoji = ownerAvatarEmoji
        self.ownerAvatarColor = ownerAvatarColor
        self.title = title
        self.description = description
        self.coverArtwork = coverArtwork
        self.visibility = visibility
        self.source = source
        self.lens = lens
        self.partyId = partyId
        self.genre = genre
        self.variant = variant
        self.contributorUids = contributorUids
        self.trackCount = trackCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // `id` is the documentID, not a stored field — omit it from the payload.
    private enum CodingKeys: String, CodingKey {
        case ownerUid, ownerUsername, ownerAvatarEmoji, ownerAvatarColor
        case title, description, coverArtwork, visibility, source, lens, partyId, genre, variant
        case contributorUids, trackCount, createdAt, updatedAt
    }

    // Tolerant decode so a doc written by an older/leaner client still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id               = ""
        ownerUid         = try c.decodeIfPresent(String.self, forKey: .ownerUid) ?? ""
        ownerUsername    = try c.decodeIfPresent(String.self, forKey: .ownerUsername) ?? ""
        ownerAvatarEmoji = try c.decodeIfPresent(String.self, forKey: .ownerAvatarEmoji)
        ownerAvatarColor = try c.decodeIfPresent(String.self, forKey: .ownerAvatarColor)
        title            = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        description      = try c.decodeIfPresent(String.self, forKey: .description)
        coverArtwork     = try c.decodeIfPresent(String.self, forKey: .coverArtwork) ?? ""
        // `decodeIfPresent` on an enum THROWS when the key is present but holds a
        // raw value this build doesn't know — it does NOT return nil. Without the
        // `try?`, a doc written by a newer client (a `source` or `lens` case added
        // later) would fail to decode entirely and the playlist would silently
        // vanish, because the read path swallows failures with `try?`.
        visibility       = ((try? c.decodeIfPresent(PlaylistVisibility.self, forKey: .visibility)) ?? nil) ?? .friends
        source           = ((try? c.decodeIfPresent(PlaylistSource.self, forKey: .source)) ?? nil) ?? .manual
        lens             = (try? c.decodeIfPresent(PlaylistLens.self, forKey: .lens)) ?? nil
        partyId          = try c.decodeIfPresent(String.self, forKey: .partyId)
        genre            = try c.decodeIfPresent(String.self, forKey: .genre)
        variant          = try c.decodeIfPresent(String.self, forKey: .variant)
        contributorUids  = try c.decodeIfPresent([String].self, forKey: .contributorUids) ?? []
        trackCount       = try c.decodeIfPresent(Int.self, forKey: .trackCount) ?? 0
        createdAt        = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        updatedAt        = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
    }
}
