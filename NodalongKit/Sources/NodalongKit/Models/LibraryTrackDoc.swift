public struct LibraryTrackDoc: Codable, Identifiable, Hashable, Sendable {
    public let catalogId: String
    /// Metadata fields are `var` and sourced from the catalog at read time via
    /// `merged(withCatalog:)`. Slim docs omit them, so decoding defaults them
    /// (see `init(from:)`) rather than failing.
    public var title: String
    public var artist: String
    public var album: String
    public var artwork: String
    public var uri: String
    public let sourceService: MusicServiceType
    public var isrc: String?
    public var duration: Int?
    public var trackNumber: Int?
    public var albumReleaseDate: String?
    public let savedAt: Double

    public var id: String { catalogId }

    public init(
        catalogId: String,
        title: String,
        artist: String,
        album: String,
        artwork: String,
        uri: String,
        sourceService: MusicServiceType,
        isrc: String? = nil,
        duration: Int? = nil,
        trackNumber: Int? = nil,
        albumReleaseDate: String? = nil,
        savedAt: Double
    ) {
        self.catalogId = catalogId
        self.title = title
        self.artist = artist
        self.album = album
        self.artwork = artwork
        self.uri = uri
        self.sourceService = sourceService
        self.isrc = isrc
        self.duration = duration
        self.trackNumber = trackNumber
        self.albumReleaseDate = albumReleaseDate
        self.savedAt = savedAt
    }

    private enum CodingKeys: String, CodingKey {
        case catalogId, title, artist, album, artwork, uri, sourceService
        case isrc, duration, trackNumber, albumReleaseDate, savedAt
    }

    // Tolerant decode: slim event docs carry only catalogId/sourceService/
    // savedAt, so metadata keys default and get overlaid from the catalog.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        catalogId        = try c.decodeIfPresent(String.self, forKey: .catalogId) ?? ""
        title            = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist           = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        album            = try c.decodeIfPresent(String.self, forKey: .album) ?? ""
        artwork          = try c.decodeIfPresent(String.self, forKey: .artwork) ?? ""
        uri              = try c.decodeIfPresent(String.self, forKey: .uri) ?? ""
        sourceService    = try c.decodeIfPresent(MusicServiceType.self, forKey: .sourceService) ?? .appleMusic
        isrc             = try c.decodeIfPresent(String.self, forKey: .isrc)
        duration         = try c.decodeIfPresent(Int.self, forKey: .duration)
        trackNumber      = try c.decodeIfPresent(Int.self, forKey: .trackNumber)
        albumReleaseDate = try c.decodeIfPresent(String.self, forKey: .albumReleaseDate)
        savedAt          = try c.decodeIfPresent(Double.self, forKey: .savedAt) ?? 0
    }

    /// Returns a copy re-keyed to a different `catalogId`, preserving all other
    /// fields. Used by the save path to swap a placeholder/empty id for the
    /// canonical catalogId returned by `upsertCatalogTrack` (`catalogId` is
    /// `let`, so a copy is required).
    public func withCatalogId(_ id: String) -> LibraryTrackDoc {
        LibraryTrackDoc(
            catalogId: id, title: title, artist: artist, album: album,
            artwork: artwork, uri: uri, sourceService: sourceService,
            isrc: isrc, duration: duration, trackNumber: trackNumber,
            albumReleaseDate: albumReleaseDate, savedAt: savedAt
        )
    }

    /// Returns a copy with metadata (incl. album-sort fields) taken from the
    /// catalog row; event fields (`savedAt`) preserved. No-op when nil.
    public func merged(withCatalog catalog: CatalogTrack?) -> LibraryTrackDoc {
        guard let catalog else { return self }
        var copy = self
        copy.title            = catalog.title
        copy.artist           = catalog.artist
        copy.album            = catalog.album
        copy.artwork          = catalog.artwork
        copy.uri              = catalog.appleMusicUri ?? uri
        copy.isrc             = catalog.isrc ?? isrc
        copy.duration         = catalog.duration ?? duration
        copy.trackNumber      = catalog.trackNumber ?? trackNumber
        copy.albumReleaseDate = catalog.albumReleaseDate ?? albumReleaseDate
        return copy
    }
}
