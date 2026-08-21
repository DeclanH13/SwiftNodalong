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
        self.appleMusicUri = appleMusicUri
        self.appleMusicTrackId = appleMusicTrackId
        self.spotifyUri = spotifyUri
        self.spotifyTrackId = spotifyTrackId
    }
}
