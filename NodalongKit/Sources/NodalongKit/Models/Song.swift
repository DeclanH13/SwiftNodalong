/// A playable music track. The canonical model passed to `MusicService.play(_:)`
/// and used everywhere a track surfaces in the UI.
///
/// Fields are intentionally permissive (most are `var` and many are optional)
/// so the same struct can model tracks from many origins — feed posts,
/// library entries, search results, recently-played — without separate types.
///
/// `sourceService` is non-optional with a default of `.appleMusic`. The
/// `uri` field carries the service-native identifier (a `MusicItemID.rawValue`
/// for Apple Music).
public struct Song: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var artist: String
    public var album: String
    public var artwork: String
    public var liked: Bool
    public var nods: Int
    public var trackId: String
    public var uri: String
    public var userName: String?
    public var listenedAt: Double?
    public var catalogId: String?
    public var sourceService: MusicServiceType
    public var isrc: String?
    public var duration: Int?
    public var trackNumber: Int?
    public var albumReleaseDate: String?
    /// From MusicKit's `contentRating` — drives the explicit ("E") tag in
    /// search/track rows. Decoded tolerantly (see `init(from:)`) since
    /// `Song` is persisted directly via `SnapshotStore` (Home's cached
    /// top-charts snapshot) and an older cached file won't have this key.
    public var isExplicit: Bool
    /// Apple Music genre names for this track (e.g. ["Alternative"]).
    /// Empty for anything ingested before genre capture, and for tracks Apple
    /// gives no genre for — treat empty as "unknown", never as a real bucket.
    public var genres: [String]
    /// False when Apple has the track in its catalog but not yet playable —
    /// the unreleased tracks of a pre-release album, which Apple returns with
    /// placeholder titles ("Track 1", "Track 3") and no duration.
    ///
    /// Read from MusicKit's `playParameters`, which is `nil` for exactly this
    /// case — authoritative, unlike inferring it from a missing duration.
    /// Defaults `true`: every existing caller and every stored snapshot
    /// predates this field, and "playable" is the only safe assumption for a
    /// track we know nothing else about.
    public var isPlayable: Bool
    /// This TRACK's own release date ("yyyy-MM-dd"), which is not the same
    /// question as `albumReleaseDate`: on a pre-release album the album's date
    /// is still in the future while an already-released lead single carries
    /// its own, earlier one.
    public var releaseDate: String?

    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, artwork, liked, nods, uri
        case trackId = "track_id"
        case userName = "user_name"
        case listenedAt, catalogId, sourceService, isrc, duration, trackNumber, albumReleaseDate, isExplicit, genres
        case isPlayable, releaseDate
    }

    public init(
        id: String,
        title: String,
        artist: String,
        album: String,
        artwork: String,
        liked: Bool = false,
        nods: Int = 0,
        trackId: String,
        uri: String,
        userName: String? = nil,
        listenedAt: Double? = nil,
        catalogId: String? = nil,
        sourceService: MusicServiceType = .appleMusic,
        isrc: String? = nil,
        duration: Int? = nil,
        trackNumber: Int? = nil,
        albumReleaseDate: String? = nil,
        isExplicit: Bool = false,
        genres: [String] = [],
        isPlayable: Bool = true,
        releaseDate: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.artwork = artwork
        self.liked = liked
        self.nods = nods
        self.trackId = trackId
        self.uri = uri
        self.userName = userName
        self.listenedAt = listenedAt
        self.catalogId = catalogId
        self.sourceService = sourceService
        self.isrc = isrc
        self.duration = duration
        self.trackNumber = trackNumber
        self.albumReleaseDate = albumReleaseDate
        self.isExplicit = isExplicit
        self.genres = genres
        self.isPlayable = isPlayable
        self.releaseDate = releaseDate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decode(String.self, forKey: .artist)
        album = try c.decode(String.self, forKey: .album)
        artwork = try c.decode(String.self, forKey: .artwork)
        liked = try c.decodeIfPresent(Bool.self, forKey: .liked) ?? false
        nods = try c.decodeIfPresent(Int.self, forKey: .nods) ?? 0
        trackId = try c.decode(String.self, forKey: .trackId)
        uri = try c.decode(String.self, forKey: .uri)
        userName = try c.decodeIfPresent(String.self, forKey: .userName)
        listenedAt = try c.decodeIfPresent(Double.self, forKey: .listenedAt)
        catalogId = try c.decodeIfPresent(String.self, forKey: .catalogId)
        sourceService = try c.decodeIfPresent(MusicServiceType.self, forKey: .sourceService) ?? .appleMusic
        isrc = try c.decodeIfPresent(String.self, forKey: .isrc)
        duration = try c.decodeIfPresent(Int.self, forKey: .duration)
        trackNumber = try c.decodeIfPresent(Int.self, forKey: .trackNumber)
        albumReleaseDate = try c.decodeIfPresent(String.self, forKey: .albumReleaseDate)
        isExplicit = try c.decodeIfPresent(Bool.self, forKey: .isExplicit) ?? false
        // Tolerant, like every field here: `Song` is persisted via SnapshotStore
        // (Home's topChartSongs), and a required new key would make every
        // existing on-disk snapshot fail to decode — silently turning each
        // launch back into a cold network load with no signal.
        genres = try c.decodeIfPresent([String].self, forKey: .genres) ?? []
        // `?? true` is load-bearing, not defensive padding: a stored snapshot
        // written before this field existed has no key here, and a required
        // decode would throw — which `SnapshotStore.load` swallows with
        // `try?`, silently turning every launch into a cold network load. The
        // same shape once blanked every track in the app (`CatalogTrack`).
        isPlayable = try c.decodeIfPresent(Bool.self, forKey: .isPlayable) ?? true
        releaseDate = try c.decodeIfPresent(String.self, forKey: .releaseDate)
    }

    /// Returns a copy with the `catalogId` set. Used after the
    /// `LibrarySyncService` resolves a track to its global catalog entry.
    public static func withCatalogId(_ song: Song, catalogId: String) -> Song {
        var copy = song
        copy.catalogId = catalogId
        return copy
    }
}
