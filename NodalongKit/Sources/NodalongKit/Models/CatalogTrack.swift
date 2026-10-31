/// Global cross-user catalog entry stored at `tracks/{catalogId}`.
///
/// One canonical row per song-as-identity, found by ISRC across users. Lets
/// the Feed deduplicate plays of the same track even when different users
/// surface it from slightly different metadata, and powers cross-service
/// resolution — a track can carry BOTH Apple Music and Spotify identifiers on
/// the same ISRC-matched row, once a user of the other service surfaces it too.
public struct CatalogTrack: Codable, Hashable, Sendable {
    public let title: String
    public let artist: String
    public let album: String
    public let artwork: String
    public let duration: Int?
    public let isrc: String?
    /// Track's position within its album — used by Shelf album ordering.
    public let trackNumber: Int?
    /// Album release date (`yyyy-MM-dd`) — used by Shelf chronological sort.
    public let albumReleaseDate: String?
    /// Apple Music genre names. Empty means "not captured yet" (rows written
    /// before genre ingest) — never assume empty implies genre-less.
    public let genres: [String]
    /// Apple Music's `contentRating == .explicit` for this track, captured at
    /// ingest. `false` also means "not captured yet" for rows written before
    /// this field existed — the same caveat `genres` carries, and the reason
    /// album-level explicit marks fill in gradually rather than all at once.
    public let isExplicit: Bool
    public let titleLower: String
    public let artistLower: String
    public let albumLower: String

    /// Apple Music catalog identifier — the `MusicItemID.rawValue` (or a
    /// `music://` URL). `nil` for tracks added before Apple Music was wired.
    public let appleMusicUri: String?
    public let appleMusicTrackId: String?

    /// Spotify catalog identifier — a `spotify:track:...` URI and the bare
    /// track id. `nil` until a Spotify-linked user's listening/search surfaces
    /// this track (additive; existing Apple-only rows are unaffected).
    public let spotifyUri: String?
    public let spotifyTrackId: String?

    public let createdAt: Double
    public let updatedAt: Double

    public init(
        title: String,
        artist: String,
        album: String,
        artwork: String,
        duration: Int? = nil,
        isrc: String? = nil,
        trackNumber: Int? = nil,
        albumReleaseDate: String? = nil,
        genres: [String] = [],
        isExplicit: Bool = false,
        appleMusicUri: String? = nil,
        appleMusicTrackId: String? = nil,
        spotifyUri: String? = nil,
        spotifyTrackId: String? = nil,
        createdAt: Double,
        updatedAt: Double
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artwork = artwork
        self.duration = duration
        self.isrc = isrc
        self.trackNumber = trackNumber
        self.albumReleaseDate = albumReleaseDate
        self.genres = genres
        self.isExplicit = isExplicit
        self.titleLower = title.lowercased()
        self.artistLower = artist.lowercased()
        self.albumLower = album.lowercased()
        self.appleMusicUri = appleMusicUri
        self.appleMusicTrackId = appleMusicTrackId
        self.spotifyUri = spotifyUri
        self.spotifyTrackId = spotifyTrackId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
    private enum CodingKeys: String, CodingKey {
        case title, artist, album, artwork, duration, isrc, trackNumber, albumReleaseDate
        case genres, isExplicit, titleLower, artistLower, albumLower
        case appleMusicUri, appleMusicTrackId, spotifyUri, spotifyTrackId
        case createdAt, updatedAt
    }

    /// Tolerant decode — every field falls back rather than throwing.
    ///
    /// 🔴 This exists because the SYNTHESIZED decoder is a trap for this type
    /// specifically. Swift synthesises `decode(_:forKey:)` (not
    /// `decodeIfPresent`) for a non-optional property and IGNORES its default
    /// value, so adding a single non-optional field makes decoding throw on
    /// every document written before that field existed.
    ///
    /// That is catastrophic here rather than merely lossy: `tracks/{catalogId}`
    /// is the single source of truth for ALL track metadata, and every read
    /// path swallows decode failures with `try?`. A throw therefore surfaces as
    /// `merged(withCatalog: nil)` — a silent no-op leaving title/artist/album
    /// empty — so Shelf buckets the whole library as "Singles"/"Unknown Artist"
    /// and Feed/Spotlight blank out. It shipped exactly that way when `genres`
    /// was added: green build, passing tests, every screen broken on device.
    ///
    /// Any new field on this type MUST be optional or decoded tolerantly here.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title            = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist           = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        album            = try c.decodeIfPresent(String.self, forKey: .album) ?? ""
        artwork          = try c.decodeIfPresent(String.self, forKey: .artwork) ?? ""
        duration         = try c.decodeIfPresent(Int.self, forKey: .duration)
        isrc             = try c.decodeIfPresent(String.self, forKey: .isrc)
        trackNumber      = try c.decodeIfPresent(Int.self, forKey: .trackNumber)
        albumReleaseDate = try c.decodeIfPresent(String.self, forKey: .albumReleaseDate)
        genres           = try c.decodeIfPresent([String].self, forKey: .genres) ?? []
        isExplicit       = try c.decodeIfPresent(Bool.self, forKey: .isExplicit) ?? false
        // Derived on write; recompute when an older row lacks them.
        titleLower        = try c.decodeIfPresent(String.self, forKey: .titleLower)  ?? title.lowercased()
        artistLower       = try c.decodeIfPresent(String.self, forKey: .artistLower) ?? artist.lowercased()
        albumLower        = try c.decodeIfPresent(String.self, forKey: .albumLower)  ?? album.lowercased()
        appleMusicUri     = try c.decodeIfPresent(String.self, forKey: .appleMusicUri)
        appleMusicTrackId = try c.decodeIfPresent(String.self, forKey: .appleMusicTrackId)
        spotifyUri        = try c.decodeIfPresent(String.self, forKey: .spotifyUri)
        spotifyTrackId    = try c.decodeIfPresent(String.self, forKey: .spotifyTrackId)
        createdAt        = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        updatedAt        = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
    }
}

/// Inputs for `upsertCatalogTrack`. The caller doesn't supply timestamps —
/// the Firestore layer stamps them. Service-identifier fields are all
/// optional so a caller only supplies whichever service(s) it has — a
/// Spotify-only ingest doesn't need to fabricate Apple identifiers, and vice
/// versa.
public struct CatalogTrackInput: Sendable {
    public let title: String
    public let artist: String
    public let album: String
    public let artwork: String
    public let duration: Int?
    public let isrc: String?
    public let trackNumber: Int?
    public let albumReleaseDate: String?
    public let genres: [String]
    public let isExplicit: Bool
    public let appleMusicUri: String?
    public let appleMusicTrackId: String?
    public let spotifyUri: String?
    public let spotifyTrackId: String?

    public init(
        title: String,
        artist: String,
        album: String,
        artwork: String,
        duration: Int? = nil,
        isrc: String? = nil,
        trackNumber: Int? = nil,
        albumReleaseDate: String? = nil,
        genres: [String] = [],
        isExplicit: Bool = false,
        appleMusicUri: String? = nil,
        appleMusicTrackId: String? = nil,
        spotifyUri: String? = nil,
        spotifyTrackId: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artwork = artwork
        self.duration = duration
        self.isrc = isrc
        self.trackNumber = trackNumber
        self.albumReleaseDate = albumReleaseDate
        self.genres = genres
        self.isExplicit = isExplicit
        self.appleMusicUri = appleMusicUri
        self.appleMusicTrackId = appleMusicTrackId
        self.spotifyUri = spotifyUri
        self.spotifyTrackId = spotifyTrackId
    }
}
