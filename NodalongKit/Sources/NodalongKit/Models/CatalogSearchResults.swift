/// Shared tolerant read for `MusicServiceType`.
///
/// `decodeIfPresent` throws when the key is PRESENT but holds an unrecognised
/// raw value — so a future service rename would break decoding of every
/// persisted snapshot, which is exactly the failure mode these tolerant
/// decoders exist to prevent. Reading the raw string and mapping it ourselves
/// treats "missing" and "unknown" identically: fall back to the default.
private extension KeyedDecodingContainer {
    func decodeTolerantService(forKey key: Key) -> MusicServiceType {
        // `try?` flattens here (Swift 5+), so a missing key and a decode
        // failure both land on `nil` — which is exactly the behaviour we want.
        guard let raw = try? decodeIfPresent(String.self, forKey: key) else {
            return .appleMusic
        }
        return MusicServiceType(rawValue: raw) ?? .appleMusic
    }
}

public struct ArtistResult: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let key: String
    public let name: String
    public let imageUrl: String
    public let genres: String
    public let followers: Int
    public let sourceService: MusicServiceType

    public init(
        id: String,
        name: String,
        imageUrl: String,
        genres: String,
        followers: Int,
        sourceService: MusicServiceType
    ) {
        self.id = id
        self.key = "artist:\(id)"
        self.name = name
        self.imageUrl = imageUrl
        self.genres = genres
        self.followers = followers
        self.sourceService = sourceService
    }

    /// Decode-tolerant, deliberately — see `AlbumResult.init(from:)` for the
    /// full rationale. This type is persisted inside `HomeSnapshot`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedId = try c.decode(String.self, forKey: .id)
        id = decodedId
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? "artist:\(decodedId)"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        imageUrl = try c.decodeIfPresent(String.self, forKey: .imageUrl) ?? ""
        genres = try c.decodeIfPresent(String.self, forKey: .genres) ?? ""
        followers = try c.decodeIfPresent(Int.self, forKey: .followers) ?? 0
        sourceService = c.decodeTolerantService(forKey: .sourceService)
    }
}

public struct AlbumResult: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let key: String
    public let name: String
    public let artistName: String
    /// `var`, not `let`: some resolution paths backfill this in place when a
    /// library-sourced album's own artwork is a device-local reference with
    /// no usable https URL, swapping in a resolved catalog counterpart's
    /// artwork instead of reconstructing the whole struct.
    public var artwork: String
    public let releaseDate: String
    public let totalTracks: Int
    public let albumType: String   // "album" | "single" | "compilation"
    public let sourceService: MusicServiceType
    /// From MusicKit's `contentRating` — used to prefer the explicit release
    /// when the same album exists in explicit/clean pairs (see
    /// `dedupeAlbumEditions`). Defaults `false` for Spotify, which doesn't
    /// surface this distinction the same way.
    public var isExplicit: Bool
    /// Set only on an entry inside another album's `alternates` — a short
    /// human label for why this is the alternate ("Clean", "Deluxe Edition",
    /// "Remastered 2011"), shown in the "Alternative versions" list.
    public var editionLabel: String?
    /// Other editions of this same release (clean vs. explicit, deluxe,
    /// remaster, etc.) folded away from the main discography list — see
    /// `dedupeAlbumEditions`. Always empty on an entry that is ITSELF inside
    /// another album's `alternates`, so this never nests more than one level
    /// deep.
    public var alternates: [AlbumResult]
    /// Genre tags (Apple's `genreNames`, umbrella "Music" dropped). Search uses
    /// them so an album gets the same taste boost a song by the same artist does
    /// — without them albums always ranked below songs. Empty when unknown.
    public var genres: [String]

    public init(
        id: String,
        name: String,
        artistName: String,
        artwork: String,
        releaseDate: String,
        totalTracks: Int,
        albumType: String = "album",
        sourceService: MusicServiceType,
        isExplicit: Bool = false,
        editionLabel: String? = nil,
        alternates: [AlbumResult] = [],
        genres: [String] = []
    ) {
        self.id = id
        self.key = "album:\(id)"
        self.name = name
        self.artistName = artistName
        self.artwork = artwork
        self.releaseDate = releaseDate
        self.totalTracks = totalTracks
        self.albumType = albumType
        self.sourceService = sourceService
        self.isExplicit = isExplicit
        self.editionLabel = editionLabel
        self.alternates = alternates
        self.genres = genres
    }

    /// Decode-tolerant by design — every field except `id` falls back to the
    /// same default its memberwise `init` uses.
    ///
    /// This matters because `AlbumResult` is persisted (inside `HomeSnapshot`,
    /// via `RecommendationShelf.albums`) and Swift's SYNTHESIZED `Codable`
    /// does **not** apply `init` defaults on decode — it hard-requires every
    /// non-optional key. So adding a non-optional field (as `isExplicit` and
    /// `alternates` both were) silently broke decoding of every snapshot
    /// written before that field existed. `SnapshotStore.load` swallows the
    /// failure with `try?`, so the symptom isn't a crash — it's the
    /// stale-while-revalidate fast path quietly switching off and every
    /// launch becoming a cold network load. Mirrors `Song.init(from:)`,
    /// which already does this for the same reason.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedId = try c.decode(String.self, forKey: .id)
        id = decodedId
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? "album:\(decodedId)"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        artistName = try c.decodeIfPresent(String.self, forKey: .artistName) ?? ""
        artwork = try c.decodeIfPresent(String.self, forKey: .artwork) ?? ""
        releaseDate = try c.decodeIfPresent(String.self, forKey: .releaseDate) ?? ""
        totalTracks = try c.decodeIfPresent(Int.self, forKey: .totalTracks) ?? 0
        albumType = try c.decodeIfPresent(String.self, forKey: .albumType) ?? "album"
        sourceService = c.decodeTolerantService(forKey: .sourceService)
        isExplicit = try c.decodeIfPresent(Bool.self, forKey: .isExplicit) ?? false
        editionLabel = try c.decodeIfPresent(String.self, forKey: .editionLabel)
        alternates = try c.decodeIfPresent([AlbumResult].self, forKey: .alternates) ?? []
        genres = (try? c.decodeIfPresent([String].self, forKey: .genres)) ?? []
    }
}

/// A curated Apple Music playlist mix (e.g. "New Music Mix", "Chill Mix")
/// surfaced via `AppleMusicService.getMadeForYouPlaylists` — a genuinely
/// different content type from `AlbumResult` (a curated playlist, not an
/// album), even though both can come from the same recommendations payload.
public struct PlaylistResult: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let key: String
    public let name: String
    public let curatorName: String
    public let artwork: String
    public let sourceService: MusicServiceType

    public init(
        id: String,
        name: String,
        curatorName: String,
        artwork: String,
        sourceService: MusicServiceType
    ) {
        self.id = id
        self.key = "playlist:\(id)"
        self.name = name
        self.curatorName = curatorName
        self.artwork = artwork
        self.sourceService = sourceService
    }

    /// Decode-tolerant — see `AlbumResult.init(from:)`. Persisted inside
    /// `HomeSnapshot` as `madeForYouPlaylists`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedId = try c.decode(String.self, forKey: .id)
        id = decodedId
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? "playlist:\(decodedId)"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        curatorName = try c.decodeIfPresent(String.self, forKey: .curatorName) ?? ""
        artwork = try c.decodeIfPresent(String.self, forKey: .artwork) ?? ""
        sourceService = c.decodeTolerantService(forKey: .sourceService)
    }
}

public struct CombinedSearchResults: Sendable {
    public let artists: [ArtistResult]
    public let albums: [AlbumResult]
    public let tracks: [SearchItem]

    public init(artists: [ArtistResult], albums: [AlbumResult], tracks: [SearchItem]) {
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
    }

    public static let empty = CombinedSearchResults(artists: [], albums: [], tracks: [])
}
