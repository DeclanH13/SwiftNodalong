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
    /// False for a pre-release album's unreleased tracks — see
    /// `Song.isPlayable`. Drives the dimmed, undated, untappable row in
    /// `AlbumDetailSearchView` and keeps them out of the play queue.
    public let isPlayable: Bool
    /// This track's own release date ("yyyy-MM-dd"), shown in place of the
    /// duration on a row that isn't playable yet.
    public let releaseDate: String?
    /// The track's genre tags when the service supplied them — used only to
    /// break ties in search ranking toward genres the user listens to.
    public let genres: [String]

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
        isExplicit: Bool = false,
        isPlayable: Bool = true,
        releaseDate: String? = nil,
        genres: [String] = []
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
        self.isPlayable = isPlayable
        self.releaseDate = releaseDate
        self.genres = genres
    }
}
