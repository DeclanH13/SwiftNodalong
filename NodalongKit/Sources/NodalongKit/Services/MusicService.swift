/// Result of a service-specific track lookup (by ISRC or title + artist).
///
/// Used by the cross-service catalog resolver to bridge a track known on one
/// service (e.g. a friend's Spotify-sourced track) into the currently active
/// service's playable identifier.
public struct SearchResult: Sendable {
    /// Service-native URI for the matched track (e.g. `spotify:track:xxx`,
    /// or an Apple Music catalog URL).
    public let uri: String

    /// Service-native track identifier (the bare ID portion of `uri`).
    public let trackId: String

    /// International Standard Recording Code, when the service exposes it.
    /// Carried through for downstream cross-service catalog dedup.
    public let isrc: String?

    /// - Parameters:
    ///   - uri: Service-native track URI.
    ///   - trackId: Service-native track identifier.
    ///   - isrc: ISRC if known, otherwise `nil`.
    public init(uri: String, trackId: String, isrc: String? = nil) {
        self.uri = uri
        self.trackId = trackId
        self.isrc = isrc
    }
}

/// Abstracts over a music streaming backend (Spotify, Apple Music, future
/// services). Implementations own their own auth state and HTTP client; the
/// protocol exposes only semantic operations.
///
/// Implementation details that **must not** leak through this protocol:
/// access tokens, device IDs, refresh scheduling, retry/backoff handling.
/// Callers that need to play a track call `play(_:)` — they never thread a
/// token through.
///
/// Implementations should also conform to `ObservableObject` so SwiftUI views
/// can observe `isAuthenticated` via `@EnvironmentObject`.
public protocol MusicService: AnyObject, Sendable {
    /// Which backend this implementation talks to. Used by callers that need
    /// to disambiguate cross-service catalog entries (e.g. `Song.sourceService`).
    var serviceType: MusicServiceType { get }

    /// `true` when the user has completed authorization and the service can
    /// make calls on their behalf.
    var isAuthenticated: Bool { get }

    // MARK: - Authorization

    /// Run the implementation's authorization flow — PKCE OAuth for Spotify,
    /// `MusicAuthorization.request()` for Apple Music. Returns when auth is
    /// complete or the user cancels. Idempotent — calling when already
    /// authorized is a no-op.
    func authorize() async throws

    /// Revoke local auth state and clear any persisted tokens.
    func logout() async throws

    // MARK: - Library

    /// Fetch the user's saved tracks from the service's own library.
    /// - Returns: Tracks the user has liked or added in the service.
    func getSavedTracks() async throws -> [Song]

    /// Fetch the user's recently-played tracks from the service.
    /// - Returns: Most recent tracks, reverse chronological.
    func getRecentlyPlayed() async throws -> [Song]

    // MARK: - Playback

    /// Begin playback of a specific track.
    ///
    /// The `song` may have originated on a different service (e.g. a friend
    /// posted it from Spotify and the local user is on Apple Music). The
    /// implementation is responsible for resolving `song.uri` /
    /// `song.catalogId` / `song.isrc` to a playable identifier in its own
    /// catalog, falling back through ISRC and then title + artist as needed.
    ///
    /// - Parameter song: The track to play.
    func play(_ song: Song) async throws

    /// Resume playback of the current track if paused. No-op if nothing is
    /// loaded.
    func resume() async throws

    /// Pause playback. No-op if nothing is playing.
    func pause() async throws

    // MARK: - Search

    /// Free-text track search against the service's catalog.
    /// - Parameters:
    ///   - query: User-entered search text.
    ///   - maxResults: Cap on returned tracks; services may return fewer.
    /// - Returns: Tracks ranked by service relevance.
    func searchTracks(_ query: String, maxResults: Int) async throws -> [Song]

    /// Free-text artist search. Use when the UI is filtered to artists only —
    /// avoids fetching album/song data the caller will discard.
    /// - Parameters:
    ///   - query: User-entered search text.
    ///   - maxResults: Cap on returned artists.
    /// - Returns: Artists ranked by service relevance.
    func searchArtists(_ query: String, maxResults: Int) async throws -> [ArtistResult]

    /// Free-text album search. Use when the UI is filtered to albums only —
    /// avoids fetching artist/song data the caller will discard.
    /// - Parameters:
    ///   - query: User-entered search text.
    ///   - maxResults: Cap on returned albums.
    /// - Returns: Albums ranked by service relevance.
    func searchAlbums(_ query: String, maxResults: Int) async throws -> [AlbumResult]

    /// Look up a single track by ISRC. Primary cross-service catalog bridge.
    /// - Parameter isrc: International Standard Recording Code.
    /// - Returns: Best match, or `nil` if no track with this ISRC exists in
    ///   the service's catalog.
    func searchByIsrc(_ isrc: String) async throws -> SearchResult?

    /// Look up a single track by title and artist. Fallback used when ISRC
    /// is unavailable or yields no match.
    /// - Returns: Best fuzzy match, or `nil` if nothing reasonable is found.
    func searchByTitleArtist(title: String, artist: String) async throws -> SearchResult?

    /// Multi-type catalog search returning artists, albums, and tracks.
    /// - Parameters:
    ///   - query: User-entered search text.
    ///   - maxPerType: Cap applied independently to each result category.
    func searchAll(
        _ query: String,
        maxPerType: Int
    ) async throws -> (artists: [ArtistResult], albums: [AlbumResult], tracks: [Song])

    // MARK: - Browse

    /// Fetch all albums released by a given artist.
    /// - Parameter artistId: Service-native artist identifier (from a prior
    ///   search or browse result).
    func getArtistAlbums(artistId: String) async throws -> [AlbumResult]

    /// Fetch the artist's top / most-played tracks from the service's catalog.
    /// Uses the service's native "top songs" relationship (e.g. MusicKit's
    /// `Artist.topSongs`) rather than a search-and-filter approximation.
    /// - Parameter artistId: Service-native artist identifier.
    /// - Returns: Top tracks in service-defined relevance order, typically up to 20.
    func getArtistTopTracks(artistId: String) async throws -> [Song]

    /// Fetch the track listing of an album.
    /// - Parameters:
    ///   - albumId: Service-native album identifier.
    ///   - albumName: Album title — embedded in the returned `Song`s so
    ///     callers don't need a second lookup.
    ///   - artwork: Album artwork URL — embedded in the returned `Song`s
    ///     for the same reason.
    func getAlbumTracks(albumId: String, albumName: String, artwork: String) async throws -> [Song]
}
