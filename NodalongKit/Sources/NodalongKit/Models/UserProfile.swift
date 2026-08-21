public struct SpotlightTrack: Codable, Hashable, Sendable {
    public let trackId: String
    /// Metadata fields are `var` and sourced from the catalog at read time via
    /// `merged(withCatalog:)`. Slim docs omit them, so decoding defaults them
    /// to `""` (see `init(from:)`) rather than failing.
    public var title: String
    public var artist: String
    public var album: String
    public var artwork: String
    public var uri: String
    public let spotlitAt: Double
    public let catalogId: String?
    public let sourceService: MusicServiceType?

    public init(
        trackId: String,
        title: String,
        artist: String,
        album: String,
        artwork: String,
        uri: String,
        spotlitAt: Double,
        catalogId: String? = nil,
        sourceService: MusicServiceType? = nil
    ) {
        self.trackId = trackId
        self.title = title
        self.artist = artist
        self.album = album
        self.artwork = artwork
        self.uri = uri
        self.spotlitAt = spotlitAt
        self.catalogId = catalogId
        self.sourceService = sourceService
    }

    private enum CodingKeys: String, CodingKey {
        case trackId, title, artist, album, artwork, uri, spotlitAt, catalogId, sourceService
    }

    // Tolerant decode: slim event docs carry only trackId/catalogId/spotlitAt/
    // sourceService, so the metadata keys default to "" and get overlaid from
    // the catalog on read.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trackId       = try c.decodeIfPresent(String.self, forKey: .trackId) ?? ""
        title         = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist        = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        album         = try c.decodeIfPresent(String.self, forKey: .album) ?? ""
        artwork       = try c.decodeIfPresent(String.self, forKey: .artwork) ?? ""
        uri           = try c.decodeIfPresent(String.self, forKey: .uri) ?? ""
        spotlitAt     = try c.decodeIfPresent(Double.self, forKey: .spotlitAt) ?? 0
        catalogId     = try c.decodeIfPresent(String.self, forKey: .catalogId)
        sourceService = try c.decodeIfPresent(MusicServiceType.self, forKey: .sourceService)
    }

    /// Returns a copy with metadata taken from the catalog row (the source of
    /// truth); event fields preserved. No-op when `catalog` is nil.
    public func merged(withCatalog catalog: CatalogTrack?) -> SpotlightTrack {
        guard let catalog else { return self }
        var copy = self
        copy.title   = catalog.title
        copy.artist  = catalog.artist
        copy.album   = catalog.album
        copy.artwork = catalog.artwork
        copy.uri     = catalog.appleMusicUri ?? uri
        return copy
    }
}

// Dates are stored as Double (epoch ms) — not Timestamp — for cross-client compatibility
// with the JS app that writes Date.now() numbers.
public struct UserProfile: Codable, Identifiable, Hashable, Sendable {
    public let uid: String
    public let email: String
    public let username: String
    public let usernameLower: String?
    public let bio: String
    public let avatarUrl: String?
    /// Emoji shown as the avatar foreground. New canonical avatar field.
    /// Optional for backward compat with older docs.
    public let avatarEmoji: String?
    /// Legacy field from the sprite-based system. Kept as `Optional` so old
    /// docs decode without errors; not populated by new users and unused by
    /// the UI.
    public let avatarCharacter: Int?
    public let avatarColor: String?
    public let activeService: MusicServiceType?
    public let geohash: String?
    public let lastActive: Double
    public var spotlightTracks: [SpotlightTrack]
    public let createdAt: Double
    public let updatedAt: Double

    public var id: String { uid }

    public init(
        uid: String,
        email: String,
        username: String,
        usernameLower: String? = nil,
        bio: String,
        avatarUrl: String? = nil,
        avatarEmoji: String? = nil,
        avatarCharacter: Int? = nil,
        avatarColor: String? = nil,
        activeService: MusicServiceType? = nil,
        geohash: String? = nil,
        lastActive: Double,
        spotlightTracks: [SpotlightTrack] = [],
        createdAt: Double,
        updatedAt: Double
    ) {
        self.uid = uid
        self.email = email
        self.username = username
        self.usernameLower = usernameLower
        self.bio = bio
        self.avatarUrl = avatarUrl
        self.avatarEmoji = avatarEmoji
        self.avatarCharacter = avatarCharacter
        self.avatarColor = avatarColor
        self.activeService = activeService
        self.geohash = geohash
        self.lastActive = lastActive
        self.spotlightTracks = spotlightTracks
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
