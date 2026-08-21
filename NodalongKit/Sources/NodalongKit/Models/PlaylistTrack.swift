import Foundation

/// A track within a playlist, stored at `playlists/{id}/tracks/{autoId}`.
///
/// Deliberately keyed by an **auto-generated documentID** (`id`), with
/// `catalogId` as a field — NOT keyed by `catalogId`. A playlist (and a party
/// queue) is a *list that can repeat*, so the same song may appear twice; keying
/// by `catalogId` would silently forbid duplicates. This differs from the
/// `library`/`recent_tracks` collections, which are *sets* and key by catalogId.
///
/// Like `LibraryTrackDoc`, this is a slim event doc: only `catalogId` + event
/// data (`addedBy…`, `addedAt`, `order`) is persisted; the metadata fields are
/// overlaid from the shared catalog on read via `merged(withCatalog:)`.
public struct PlaylistTrack: Codable, Identifiable, Hashable, Sendable {
    /// Firestore documentID (auto-generated). Empty until set by the read layer.
    public var id: String
    public let catalogId: String

    // Overlaid from the catalog on read; slim docs omit these.
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

    // Event data — the only fields actually stored on the doc.
    public let addedByUid: String
    public var addedByUsername: String
    public let addedAt: Double
    /// Sparse fractional sort key. Reorder sets a moved item's `order` to the
    /// midpoint of its new neighbours (`PlaylistOrder.midpoint`), a single write.
    public var order: Double

    public init(
        id: String = "",
        catalogId: String,
        title: String = "",
        artist: String = "",
        album: String = "",
        artwork: String = "",
        uri: String = "",
        sourceService: MusicServiceType = .appleMusic,
        isrc: String? = nil,
        duration: Int? = nil,
        trackNumber: Int? = nil,
        albumReleaseDate: String? = nil,
        addedByUid: String,
        addedByUsername: String,
        addedAt: Double,
        order: Double
    ) {
        self.id = id
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
        self.addedByUid = addedByUid
        self.addedByUsername = addedByUsername
        self.addedAt = addedAt
        self.order = order
    }

    // `id` is the documentID, not a stored field.
    private enum CodingKeys: String, CodingKey {
        case catalogId, title, artist, album, artwork, uri, sourceService
        case isrc, duration, trackNumber, albumReleaseDate
        case addedByUid, addedByUsername, addedAt, order
    }

    // Tolerant decode: slim docs carry only catalogId + event data.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id               = ""
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
        addedByUid       = try c.decodeIfPresent(String.self, forKey: .addedByUid) ?? ""
        addedByUsername  = try c.decodeIfPresent(String.self, forKey: .addedByUsername) ?? ""
        addedAt          = try c.decodeIfPresent(Double.self, forKey: .addedAt) ?? 0
        order            = try c.decodeIfPresent(Double.self, forKey: .order) ?? 0
    }

    /// Returns a copy with metadata taken from the catalog row; event fields
    /// (`addedBy…`, `addedAt`, `order`) preserved. No-op when nil.
    public func merged(withCatalog catalog: CatalogTrack?) -> PlaylistTrack {
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
