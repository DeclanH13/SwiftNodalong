import Foundation

/// A track in a live party queue, stored at `parties/{id}/queue/{autoId}`.
///
/// Same slim, auto-ID, catalog-overlay shape as `PlaylistTrack` (a queue is a
/// list that can repeat, so it's keyed by an auto-ID with `catalogId` as a
/// field) plus a `played` flag the host advances as it plays through. On party
/// end these docs are copied into a `PlaylistTrack` for the frozen playlist.
public struct PartyQueueTrack: Codable, Identifiable, Hashable, Sendable {
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

    // Event data.
    public let addedByUid: String
    public var addedByUsername: String
    public let addedAt: Double
    public var order: Double
    /// Set true once the host has played this entry.
    public var played: Bool

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
        order: Double,
        played: Bool = false
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
        self.played = played
    }

    private enum CodingKeys: String, CodingKey {
        case catalogId, title, artist, album, artwork, uri, sourceService
        case isrc, duration, trackNumber, albumReleaseDate
        case addedByUid, addedByUsername, addedAt, order, played
    }

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
        played           = try c.decodeIfPresent(Bool.self, forKey: .played) ?? false
    }

    /// Overlays catalog metadata; event fields preserved. No-op when nil.
    public func merged(withCatalog catalog: CatalogTrack?) -> PartyQueueTrack {
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
