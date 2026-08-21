public struct Post: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let uid: String
    public let username: String
    /// Emoji shown as the source user's avatar on this feed card.
    public let avatarEmoji: String?
    /// Legacy sprite-system field. Kept as `Optional` so old docs decode.
    public let avatarCharacter: Int?
    public let avatarColor: String?
    public let catalogId: String
    /// Metadata fields are `var` and sourced from the catalog (single source of
    /// truth) at read time via `merged(withCatalog:)`. The event doc supplies
    /// only `catalogId` + event data.
    public var title: String
    public var artist: String
    public var album: String
    public var artwork: String
    public var uri: String
    /// The recording's ISRC, overlaid from the catalog on read (never stored
    /// on the slim event doc). Carried so album resolution has a real anchor:
    /// `resolveAlbum` used to be handed `isrc: nil` from Home's rails, leaving
    /// only a fuzzy text search against an album name that may itself describe
    /// a different release of the same recording — which is how "Place -
    /// Single" ended up unresolvable.
    public var isrc: String?
    public let sourceService: MusicServiceType
    public var nods: Int
    /// How many times the OWNER of this track has genuinely replayed it
    /// recently (distinct from `nods`, which counts OTHER users nodding —
    /// a social signal, not a personal-listening one). Powers Home's "On
    /// Repeat" section. See `syncRecentTracks`'s replay-detection logic.
    public var replayCount: Int
    public var isSpotlit: Bool
    public let geohash: String?
    public let createdAt: Double
    /// UID of the user who owns this track in their `recent_tracks` subcollection.
    public let sourceUid: String?
    /// Document ID within `users/{sourceUid}/recent_tracks`.
    public let trackId: String?

    public init(
        id: String,
        uid: String,
        username: String,
        avatarEmoji: String? = nil,
        avatarCharacter: Int? = nil,
        avatarColor: String? = nil,
        catalogId: String,
        title: String,
        artist: String,
        album: String,
        artwork: String,
        uri: String,
        isrc: String? = nil,
        sourceService: MusicServiceType,
        nods: Int = 0,
        replayCount: Int = 0,
        isSpotlit: Bool = false,
        geohash: String? = nil,
        createdAt: Double,
        sourceUid: String? = nil,
        trackId: String? = nil
    ) {
        self.id = id
        self.uid = uid
        self.username = username
        self.avatarEmoji = avatarEmoji
        self.avatarCharacter = avatarCharacter
        self.avatarColor = avatarColor
        self.catalogId = catalogId
        self.title = title
        self.artist = artist
        self.album = album
        self.artwork = artwork
        self.uri = uri
        self.isrc = isrc
        self.sourceService = sourceService
        self.nods = nods
        self.replayCount = replayCount
        self.isSpotlit = isSpotlit
        self.geohash = geohash
        self.createdAt = createdAt
        self.sourceUid = sourceUid
        self.trackId = trackId
    }

    /// Tolerant decoder — **required**, not decoration.
    ///
    /// `Post` is persisted via `SnapshotStore` (Home's `HomeSnapshot`, Feed's
    /// `feedPosts`), and `SnapshotStore.load` swallows a decode failure with
    /// `try?`. With the synthesized decoder, adding any new key would make
    /// every already-written snapshot fail to decode *silently* — quietly
    /// turning each launch back into a cold network load with no signal that
    /// anything broke. Decoding every field with a fallback means an older
    /// snapshot still restores, just without the newer fields.
    ///
    /// Same pattern as `Song` / `AlbumResult` / `LibraryTrackDoc`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = (try? c.decode(String.self, forKey: .id)) ?? ""
        uid             = (try? c.decode(String.self, forKey: .uid)) ?? ""
        username        = (try? c.decode(String.self, forKey: .username)) ?? ""
        avatarEmoji     = try? c.decodeIfPresent(String.self, forKey: .avatarEmoji)
        avatarCharacter = try? c.decodeIfPresent(Int.self, forKey: .avatarCharacter)
        avatarColor     = try? c.decodeIfPresent(String.self, forKey: .avatarColor)
        catalogId       = (try? c.decode(String.self, forKey: .catalogId)) ?? ""
        title           = (try? c.decode(String.self, forKey: .title)) ?? ""
        artist          = (try? c.decode(String.self, forKey: .artist)) ?? ""
        album           = (try? c.decode(String.self, forKey: .album)) ?? ""
        artwork         = (try? c.decode(String.self, forKey: .artwork)) ?? ""
        uri             = (try? c.decode(String.self, forKey: .uri)) ?? ""
        isrc            = try? c.decodeIfPresent(String.self, forKey: .isrc)
        // `decodeIfPresent` on an enum THROWS for a present-but-unrecognised
        // raw value, so an unknown service must fall back too, not just a
        // missing key — the same trap `decodeTolerantService` exists for.
        sourceService   = (try? c.decode(MusicServiceType.self, forKey: .sourceService)) ?? .appleMusic
        nods            = (try? c.decode(Int.self, forKey: .nods)) ?? 0
        replayCount     = (try? c.decode(Int.self, forKey: .replayCount)) ?? 0
        isSpotlit       = (try? c.decode(Bool.self, forKey: .isSpotlit)) ?? false
        geohash         = try? c.decodeIfPresent(String.self, forKey: .geohash)
        createdAt       = (try? c.decode(Double.self, forKey: .createdAt)) ?? 0
        sourceUid       = try? c.decodeIfPresent(String.self, forKey: .sourceUid)
        trackId         = try? c.decodeIfPresent(String.self, forKey: .trackId)
    }

    /// Returns a copy with metadata taken from the catalog row (the source of
    /// truth); event fields (`nods`, `isSpotlit`, `createdAt`, attribution)
    /// preserved. No-op when `catalog` is nil.
    public func merged(withCatalog catalog: CatalogTrack?) -> Post {
        guard let catalog else { return self }
        var copy = self
        copy.title   = catalog.title
        copy.artist  = catalog.artist
        copy.album   = catalog.album
        copy.artwork = catalog.artwork
        copy.uri     = catalog.appleMusicUri ?? uri
        copy.isrc    = catalog.isrc ?? isrc
        return copy
    }
}
