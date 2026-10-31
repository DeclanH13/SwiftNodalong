import SwiftUI
import NodalongKit

/// Marker pushed onto the current tab's `NavigationPath` the instant an
/// artist name is tapped (from the player or a party queue row) — mirrors
/// the app's own established `PendingArtistLookup`/`PendingCatalogArtistLookup`
/// pattern (`AlbumDetailSearchView.swift`/`ShelfView.swift`): a
/// `.navigationDestination(for:)` shows a `ResolvingArtistsView` instantly
/// with the already-known name, resolving for real in the background.
///
/// Deliberately its own struct rather than pushing `NowPlayingTrack`/
/// `PartyQueueTrack` directly — the SAME track drives two different
/// destinations (artist vs. album resolve), so a second wrapper would be
/// needed regardless, and `PartyView`'s artist tap needs to feed this exact
/// path from a different source type (`PartyQueueTrack`) than
/// `NowPlayingView` does (`NowPlayingTrack`) — a marker holding just the
/// primitive fields both share is the natural common currency.
struct PendingArtistResolve: Hashable {
    /// Needed alongside `artist` for the MusicKit relationship lookup;
    /// never shown anywhere.
    let trackTitle: String
    /// Doubles as the resolve query AND `ResolvingArtistsView`'s
    /// immediately-shown provisional name.
    let artist: String
    let catalogId: String?
    let isrc: String?
    let uri: String
}

/// Same shape, for an album tap.
struct PendingAlbumResolve: Hashable {
    let albumName: String
    let artist: String
    let artwork: String
    let catalogId: String?
    let isrc: String?
    let uri: String
    /// The TRACK's own title. `resolveAlbum`'s fallback is a song search,
    /// and without this it searched for a song named after the ALBUM — the
    /// same mistake fixed for Home on 2026-08-19, still live on this path
    /// (a cold album tap from the player or the "…" menu).
    var trackTitle: String? = nil
}

/// `MusicDetailCache` key for a track-anchored resolve (an album or artist
/// tap that starts from a TRACK, not a known catalog item). Keyed by the
/// track's uri so the player's prefetch, the "…" menu's prefetch, a party's
/// prefetch and the real tap all land on one cache entry — before, only the
/// currently playing track was ever warm, and every other track's result
/// was thrown away the moment it was used.
func pendingResolveKey(_ uri: String) -> String { "pending:\(uri)" }

/// Resolves the artist(s) actually credited on a track — MusicKit's exact
/// `Song.artists` relationship on Apple Music, a fuzzy `searchAll` fallback
/// otherwise — preferring an already-warm
/// `PlayerViewModel.prefetchedArtistsForUri` cache hit over either.
///
/// Shared by `NowPlayingView` (player artist tap) and `PartyView` (queue /
/// now-playing artist tap) so both consult the SAME cache-then-fallback
/// cascade instead of two independently-maintained copies — `PartyView`'s
/// own artist tap previously only did the fuzzy `searchAll` path with a
/// blocking wait, never the precise MusicKit-relationship lookup or the
/// prefetch-cache check, so routing it through here is a precision AND
/// latency upgrade, not just deduplication.
///
/// Named to avoid any confusion with `AppleMusicService`'s own instance
/// methods of similar names (`resolveArtists(catalogTrackId:...)`), which
/// this calls internally.
@MainActor
func resolvePendingArtists(
    for pending: PendingArtistResolve,
    playerVM: PlayerViewModel,
    musicService: AppleMusicService,
    activeService: any MusicService
) async -> [ArtistResult] {
    if let cached = playerVM.prefetchedArtistsForUri, cached.uri == pending.uri {
        return cached.artists
    }
    guard playerVM.activeService == .appleMusic else {
        guard let results = try? await activeService.searchAll(pending.artist, maxPerType: 1),
              let artist = results.artists.first else { return [] }
        return [artist]
    }
    return await MusicDetailCache.shared.resolvedArtists(forKey: pendingResolveKey(pending.uri)) {
        await musicService.resolveArtists(
            catalogTrackId: pending.catalogId, isrc: pending.isrc,
            title: pending.trackTitle, artist: pending.artist
        )
    }
}

/// Same shape for albums — currently only `NowPlayingView` has an
/// album-tap surface, but this lives alongside `resolvePendingArtists` for
/// symmetry so a future party album tap doesn't reinvent it.
@MainActor
func resolvePendingAlbum(
    for pending: PendingAlbumResolve,
    playerVM: PlayerViewModel,
    musicService: AppleMusicService,
    activeService: any MusicService
) async -> AlbumResult? {
    if let cached = playerVM.prefetchedAlbumForUri, cached.uri == pending.uri {
        return cached.album
    }
    guard playerVM.activeService == .appleMusic else {
        let q = "\(pending.albumName) \(pending.artist)"
        return (try? await activeService.searchAll(q, maxPerType: 1))?.albums.first
    }
    return await MusicDetailCache.shared.resolvedAlbum(forKey: pendingResolveKey(pending.uri)) {
        await musicService.resolveAlbum(
            catalogTrackId: pending.catalogId, isrc: pending.isrc,
            title: pending.albumName, artist: pending.artist,
            trackTitle: pending.trackTitle ?? ""
        )
    }
}

/// Synchronous cache read for a pending album tap — the player's own
/// prefetch first, then the shared cache. For seeding a resolving screen in
/// `init`, so a warm tap never shows its placeholder.
@MainActor
func cachedPendingAlbum(_ pending: PendingAlbumResolve, playerVM: PlayerViewModel) -> AlbumResult? {
    if let cached = playerVM.prefetchedAlbumForUri, cached.uri == pending.uri { return cached.album }
    return MusicDetailCache.peekResolvedAlbum(key: pendingResolveKey(pending.uri))
}

/// Artist twin of `cachedPendingAlbum`.
@MainActor
func cachedPendingArtists(_ pending: PendingArtistResolve, playerVM: PlayerViewModel) -> [ArtistResult]? {
    if let cached = playerVM.prefetchedArtistsForUri, cached.uri == pending.uri { return cached.artists }
    return MusicDetailCache.peekResolvedArtists(key: pendingResolveKey(pending.uri))
}
