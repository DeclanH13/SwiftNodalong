public struct SearchItem: Codable, Identifiable, Hashable, Sendable {
    public let key: String
    public let title: String
    public let artist: String
    public let album: String
    public let artwork: String
    public let uri: String
    public let catalogId: String?
    public let isrc: String?
    public let duration: Int?
    public let trackNumber: Int?
    public let albumReleaseDate: String?
    public let sourceService: MusicServiceType
    public let isExplicit: Bool

    public var id: String { key }

    public init(
        key: String,
        title: String,
        artist: String,
        album: String,
        artwork: String,
        uri: String,
        catalogId: String? = nil,
        isrc: String? = nil,
        duration: Int? = nil,
        trackNumber: Int? = nil,
        albumReleaseDate: String? = nil,
        sourceService: MusicServiceType,
        isExplicit: Bool = false
    ) {
        self.key = key
        self.title = title
        self.artist = artist
        self.album = album
        self.artwork = artwork
        self.uri = uri
        self.catalogId = catalogId
        self.isrc = isrc
        self.duration = duration
        self.trackNumber = trackNumber
        self.albumReleaseDate = albumReleaseDate
        self.sourceService = sourceService
        self.isExplicit = isExplicit
    }
}
