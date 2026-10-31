/// One album a user has recently played from, deduped across however many
/// individual tracks they played off it — powers Home's "Jump Back In" rail.
/// Lighter than `AlbumGroup`/`groupByAlbum` (which target `LibraryTrackDoc`
/// and need `trackNumber`/`albumReleaseDate` for a full in-album track
/// listing): this only needs enough to show a resume tile and resolve the
/// real catalog album on tap.
public struct RecentAlbum: Identifiable, Hashable, Sendable {
    /// Stable within one `recentAlbums(from:)` call — not a persistent identifier.
    public let id: String
    public let albumName: String
    public let artistName: String
    public let artwork: String
    /// Catalog id of the representative (most recently played) track — this
    /// is Nodalong's own internal id (the `tracks/{catalogId}` Firestore doc),
    /// NOT a real Apple Music identifier, so it's unusable for a direct
    /// MusicKit catalog lookup on its own.
    public let catalogId: String
    /// The representative track's real Apple Music id (`Post.uri`, once
    /// merged with its catalog row) — this is what actually resolves via
    /// `AppleMusicService.resolveAlbum`'s `catalogTrackId` parameter.
    /// Without this, resolving fell back to a fuzzy text search treating the
    /// ALBUM'S OWN NAME as if it were a song title (Apple's catalog has no
    /// song literally titled e.g. "Salt of the Lee EP Some Artist"), which
    /// silently failed or mismatched for many real album/EP titles — the
    /// confirmed cause of Jump Back In taps resolving to an empty or wrong
    /// track list (Save Album then had nothing to save).
    public let uri: String
    /// Representative track's ISRC — the reliable anchor for
    /// `resolveAlbum`, which used to be handed `isrc: nil` here. See
    /// `Post.isrc`.
    public let isrc: String?
    /// Representative track's own TITLE (not the album name) — needed
    /// because `resolveAlbum` looks the track up by song title as its
    /// last-resort anchor, and feeding it the album name there could never
    /// match.
    public let trackTitle: String
    public let mostRecentPlayedAt: Double
    /// Sum of `Post.replayCount` across every track in this group — folds
    /// the "On Repeat" signal into the album tile instead of its own shelf
    /// (the two read as duplicates: both are "recent activity," just sliced
    /// at album vs. track level).
    public let totalReplayCount: Int
    /// `true` when ANY track on the album is explicit — the convention music
    /// apps use for an album-level mark.
    ///
    /// Note `false` is ambiguous: it means "no explicit track" OR "explicit
    /// data not captured yet" (see `CatalogTrack.isExplicit`). Treating both
    /// the same way is deliberate — marking an album explicit on incomplete
    /// data would be worse than marking it late.
    public let isExplicit: Bool
}

/// Dedupes recent posts into "which album did I most recently play from,"
/// keeping each group's most-recently-played track as the representative
/// (artwork/catalogId).
///
/// Also runs the album name through `stripSearchNoise(_:)` before keying —
/// confirmed on device: the same release can arrive with an inconsistent
/// edition suffix depending on which context resolved it (e.g. "SKAGABOO"
/// vs "SKAGABOO - EP"), splitting one album into two tiles. Only the
/// GROUPING KEY is normalized; `albumName` below still uses the real,
/// untouched `latest.album` for display, so the tile shows whatever title
/// that specific play actually carried.
///
/// The key is the album name ALONE — no artist component. A various-
/// artists compilation's tracks are genuinely credited to different
/// primary artists by design; keying on (album, artist) used to split one
/// real album into several spurious "single" tiles (confirmed on device,
/// "HELP(2)"). `albumArtistLabel` below folds a featured-artist credit
/// (e.g. "Jamie xx & Honey Dijon" on an otherwise-"Jamie xx" album) down to
/// the shared primary artist as before, and only shows "Various Artists"
/// when the group's tracks genuinely disagree on primary artist.
public func recentAlbums(from posts: [Post]) -> [RecentAlbum] {
    var groups: [String: [Post]] = [:]
    for post in posts where !post.album.isEmpty {
        let key = stripSearchNoise(post.album).lowercased()
        groups[key, default: []].append(post)
    }
    return groups.compactMap { key, groupPosts -> RecentAlbum? in
        guard let latest = groupPosts.max(by: { $0.createdAt < $1.createdAt }) else { return nil }
        let artistLabel = albumArtistLabel(
            defaultLabel: latest.artist,
            trackArtists: groupPosts.map(\.artist)
        )
        return RecentAlbum(
            id: key,
            albumName: latest.album,
            artistName: artistLabel,
            artwork: latest.artwork,
            catalogId: latest.catalogId,
            uri: latest.uri,
            isrc: latest.isrc,
            trackTitle: latest.title,
            mostRecentPlayedAt: latest.createdAt,
            totalReplayCount: groupPosts.reduce(0) { $0 + $1.replayCount },
            isExplicit: groupPosts.contains(where: \.isExplicit)
        )
    }.sorted { $0.mostRecentPlayedAt > $1.mostRecentPlayedAt }
}
