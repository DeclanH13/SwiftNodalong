import Foundation
import NodalongKit

/// Warms `MusicDetailCache` for an artist or album that is currently ON
/// SCREEN and tappable, but not yet tapped — so the push lands on a
/// populated screen instead of a spinner.
///
/// Every entry point here reuses the EXACT fetch closure the corresponding
/// detail screen calls on its own `.task`. That matters more than it looks:
/// `MusicDetailCache` shares in-flight work, so a real tap arriving mid-
/// prefetch JOINS that fetch rather than starting a second one. A prefetch
/// can therefore never duplicate work, only ever front-run it.
///
/// **Call this from a per-tile `.task`, not from a screen-level one.** The
/// prefetch this replaced was a screen-level `prefix(6)` — which meant
/// scrolling past the sixth result got nothing, while the first six were
/// fetched whether or not they were ever on screen. A `.task` attached to a
/// cell inside a `LazyHStack`/`LazyVGrid` only runs for cells the stack
/// actually builds, and is cancelled the moment one scrolls away. Combined
/// with `settleDelay` below, a tile flicked past during a fast scroll costs
/// nothing at all; only tiles the user paused on issue a request.
///
/// Requests here are free (MusicKit catalog, unlike the billed Firestore
/// reads `SocialCache.prefetch` caps at 6) but they are not weightless —
/// they share one connection with playback, which device logs have shown
/// to be genuinely fragile under load. `settleDelay` and cancellation are
/// load-bearing, not decoration.
@MainActor
enum CatalogPrefetch {
    /// How long a tile must stay on screen before its prefetch actually
    /// issues a request. Long enough that a fast scroll costs nothing,
    /// short enough to still be warm by the time someone reads a row and
    /// taps it.
    private static let settleDelay: UInt64 = 400_000_000   // 0.4s

    /// Warms an artist's detail screen (`albums` + `topTracks`) — what
    /// `ArtistDetailSearchView` reads on `.task`.
    ///
    /// `settle` is how long the tile must linger before a request issues.
    /// Pass 0 for "this is the likeliest thing to be tapped" (a search's top
    /// hit); the default suits a row that merely scrolled into view.
    static func artist(id: String, service: AppleMusicService, settle: UInt64 = settleDelay) async {
        guard !id.isEmpty else { return }
        if settle > 0 { try? await Task.sleep(nanoseconds: settle) }
        guard !Task.isCancelled else { return }
        await PrefetchGate.shared.run {
            guard !Task.isCancelled else { return }
            _ = await MusicDetailCache.shared.core(artistId: id) {
                guard let c = try? await service.getArtistCore(artistId: id) else { return nil }
                return ArtistCoreDetails(albums: c.albums, topTracks: c.topTracks)
            }
        }
    }

    /// `artist(id:)` for callers holding the full `ArtistResult`. With
    /// `includeHero`, also decodes the artist page's hero photo — a larger
    /// rendition than any tile shows. Only for high-intent callers: doing it
    /// for every browsed tile turned one small data request per tile into
    /// large image downloads that competed with real taps.
    static func artist(_ artist: ArtistResult, service: AppleMusicService,
                       settle: UInt64 = settleDelay, includeHero: Bool = false) async {
        await self.artist(id: artist.id, service: service, settle: settle)
        guard includeHero, !Task.isCancelled else { return }
        await ArtworkMemoryCache.prefetch(artist.imageUrl, points: ArtistDetailSearchView.heroArtworkPoints)
    }

    /// Warms an album's track list — what `AlbumDetailSearchView` reads on
    /// `.task`.
    static func album(id: String, name: String, artwork: String, releaseDate: String? = nil,
                      artist: String = "", service: AppleMusicService, settle: UInt64 = settleDelay) async {
        guard !id.isEmpty else { return }
        if settle > 0 { try? await Task.sleep(nanoseconds: settle) }
        guard !Task.isCancelled else { return }
        _ = await MusicDetailCache.shared.tracks(
            albumId: id, releaseDate: releaseDate, name: name, artist: artist, artwork: artwork
        ) {
            (try? await service.getAlbumTracks(albumId: id, albumName: name, artwork: artwork)) ?? []
        }
    }

    /// Warms a `resolveAlbum` OUTCOME under `key` — for a tile that only
    /// knows a track and a display name (Jump Back In, Friends Listening),
    /// whose destination resolves through `MusicDetailCache.resolvedAlbum`
    /// with the same key. `resolveAlbum` warms the album's tracks itself, so
    /// a hit here means the album screen is populated too.
    ///
    /// Replaces a private copy in `HomeView` that waited a full second
    /// before starting — the See All grid now needs it as well, and the
    /// shared `settleDelay` is what every other tile uses.
    static func albumResolve(key: String, uri: String, isrc: String?, albumName: String,
                             artistName: String, trackTitle: String, artwork: String,
                             service: AppleMusicService) async {
        guard !key.isEmpty else { return }
        try? await Task.sleep(nanoseconds: settleDelay)
        guard !Task.isCancelled else { return }
        _ = await MusicDetailCache.shared.resolvedAlbum(forKey: key) {
            await service.resolveAlbum(catalogTrackId: uri, isrc: isrc, title: albumName,
                                       artist: artistName, trackTitle: trackTitle)
        }
    }

    /// Warms both of a TRACK's "go to" destinations — its album and its
    /// artist — under the keys `resolvePendingAlbum`/`resolvePendingArtists`
    /// read, then chains into the artist's own page. For surfaces where the
    /// user has signalled intent on a specific track: the "…" menu being
    /// opened, or a party's now-playing hero.
    ///
    /// No settle delay — the caller IS the intent signal. The two resolves
    /// run in turn, not together, so the second hits
    /// `resolveDetailedSong`'s memo instead of repeating its lookup.
    static func pending(song: Song, playerVM: PlayerViewModel, service: AppleMusicService) async {
        guard playerVM.activeService == .appleMusic, !song.uri.isEmpty else { return }
        if !song.album.isEmpty {
            // High intent, so the album page's hero is worth decoding now.
            let artwork = song.artwork
            Task(priority: .utility) {
                await ArtworkMemoryCache.prefetchHero(artwork, points: AlbumDetailSearchView.heroArtworkSize)
            }
            _ = await resolvePendingAlbum(
                for: PendingAlbumResolve(albumName: song.album, artist: song.artist, artwork: song.artwork,
                                         catalogId: song.catalogId, isrc: song.isrc, uri: song.uri,
                                         trackTitle: song.title),
                playerVM: playerVM, musicService: service, activeService: service
            )
        }
        guard !Task.isCancelled else { return }
        let artists = await resolvePendingArtists(
            for: PendingArtistResolve(trackTitle: song.title, artist: song.artist,
                                      catalogId: song.catalogId, isrc: song.isrc, uri: song.uri),
            playerVM: playerVM, musicService: service, activeService: service
        )
        guard !Task.isCancelled, let first = artists.first else { return }
        await artist(first, service: service, settle: 0, includeHero: true)
    }

    /// Warms an Apple Music playlist's track list — what
    /// `PlaylistDetailSearchView` reads on open.
    static func playlist(id: String, service: AppleMusicService, settle: UInt64 = settleDelay) async {
        guard !id.isEmpty else { return }
        if settle > 0 { try? await Task.sleep(nanoseconds: settle) }
        guard !Task.isCancelled else { return }
        _ = await MusicDetailCache.shared.playlistTracks(id: id) {
            (try? await service.getPlaylistTracks(playlistId: id)) ?? []
        }
    }

    /// Cache key for an album that is only identifiable by its DISPLAYED
    /// name + artist (a Shelf album's header tap, which has no catalog id to
    /// work from). Both the prefetch and the real tap's resolve must derive
    /// the key the same way or the prefetch is invisible to the tap, so it
    /// lives here rather than being spelled out at each site.
    static func nameAlbumKey(name: String, artist: String) -> String {
        "byname:\(name.lowercased())|\(artist.lowercased())"
    }

    /// Warms the catalog album behind a plain album-name tap.
    /// `AppleMusicService.resolveAlbum` chains into the album's track list
    /// itself, so this warms both identity and content in one go.
    /// RETURNS the resolved album so a caller can skip the resolving
    /// screen entirely — see `artistByName`'s note, which applies equally
    /// here.
    @discardableResult
    static func albumByName(name: String, artist: String, service: AppleMusicService) async -> AlbumResult? {
        guard !name.isEmpty else { return nil }
        try? await Task.sleep(nanoseconds: settleDelay)
        guard !Task.isCancelled else { return nil }
        return await MusicDetailCache.shared.resolvedAlbum(forKey: nameAlbumKey(name: name, artist: artist)) {
            await service.resolveAlbum(catalogTrackId: nil, isrc: nil, title: name, artist: artist)
        }
    }

    /// Alternate editions of `album` (clean vs. explicit, deluxe, remaster),
    /// found by matching it against its artist's discography.
    ///
    /// `dedupeAlbumEditions` needs SIBLING albums to group, so it only ever
    /// ran where a list of them exists — inside `getArtistCore` and
    /// `getArtistAlbumsFull`. A single `AlbumResult` arriving from Search, a
    /// resolve, Home, or recommendations therefore had `alternates: []`, and
    /// the same album showed its other editions when reached from an artist
    /// page and not when reached any other way.
    ///
    /// This does no grouping of its own: `getArtistCore` has already run the
    /// artist's discography through `dedupeAlbumEditions`, so the work is
    /// done and this only has to locate the right group. Matching goes
    /// through `canonicalAlbumTitle` rather than raw names — collapsing
    /// "X", "X (Explicit)" and "X (Deluxe Edition)" onto one key is exactly
    /// what that function exists for.
    ///
    /// Reads the same two cache keys `artistByName` warms, and all three
    /// album screens prefetch, so in the common case this is a pure cache
    /// read with no network at all.
    ///
    /// Returns `[]` for an album absent from its artist's discography
    /// relationship (compilations, "appears on") — no section shown, same as
    /// before.
    static func alternates(for album: AlbumResult, service: AppleMusicService) async -> [AlbumResult] {
        // Already carries them — came straight from a discography list.
        if !album.alternates.isEmpty { return album.alternates }
        guard !album.artistName.isEmpty else { return [] }

        let name = album.artistName
        guard let artist = await MusicDetailCache.shared.resolveArtistByName(name, fetch: {
            (try? await service.searchAll(name, maxPerType: 1))?.artists.first
        }) else { return [] }

        let artistId = artist.id
        guard let core = await MusicDetailCache.shared.core(artistId: artistId, fetch: {
            guard let c = try? await service.getArtistCore(artistId: artistId) else { return nil }
            return ArtistCoreDetails(albums: c.albums, topTracks: c.topTracks)
        }) else { return [] }

        let target = canonicalAlbumTitle(album.name)
        return core.albums.first { canonicalAlbumTitle($0.name) == target }?.alternates ?? []
    }

    /// Resolves an artist BY NAME (the only handle a plain artist-name tap
    /// has) and then immediately warms their detail too.
    ///
    /// The chain is the whole point. `AppleMusicService.resolveAlbum`
    /// already awaits the album's tracks before returning, which is why an
    /// album tap reads as one continuous load — there was no artist
    /// equivalent, so every artist-name tap resolved identity, swapped in
    /// `ArtistDetailSearchView`, and then sat on a SECOND cold fetch. Two
    /// spinners back to back.
    /// RETURNS the resolved artist, and callers should hold onto it.
    ///
    /// A warm cache is NOT enough to avoid the resolving screen. Both
    /// `ResolvingArtistView` and `ResolvingAlbumView` start with their
    /// `resolved` state nil and only fill it in from a `.task`, which runs
    /// AFTER the first render — so the placeholder is guaranteed at least
    /// one frame no matter how instant the lookup is, and an explicit
    /// `.animation(.easeOut(duration: 0.25))` then cross-fades out of it.
    /// That is a ~250ms loading screen that prefetching alone can never
    /// remove. The only way past it is to not push the pending marker at
    /// all: once a caller holds the real `ArtistResult`/`AlbumResult`, it
    /// can push that instead and land straight on the detail screen.
    @discardableResult
    static func artistByName(_ name: String, service: AppleMusicService) async -> ArtistResult? {
        guard !name.isEmpty else { return nil }
        try? await Task.sleep(nanoseconds: settleDelay)
        guard !Task.isCancelled else { return nil }
        let resolved = await MusicDetailCache.shared.resolveArtistByName(name) {
            (try? await service.searchAll(name, maxPerType: 1))?.artists.first
        }
        guard let resolved, !Task.isCancelled else { return nil }
        // Already past `settleDelay`; go straight to the detail fetch.
        await artist(resolved, service: service, settle: 0)
        return resolved
    }
}

/// Caps how many artist prefetches run at once.
///
/// An artist's detail is now fetched COMPLETE (two concurrent requests plus
/// pagination — see `AppleMusicService.getArtistCore`), so it is a heavier
/// request than it used to be, and a screen full of artist tiles used to be
/// able to start all of them together on the one MusicKit connection that
/// playback shares. A real tap is unaffected: it calls the cache directly
/// and never waits here.
private actor PrefetchGate {
    static let shared = PrefetchGate(limit: 3)

    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func run(_ operation: @Sendable () async -> Void) async {
        if running >= limit {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            running += 1
        }
        // A slot is now ours (handed over directly by `release`, or taken
        // above), so the count is already correct.
        await operation()
        release()
    }

    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            // Hand the slot straight to the next waiter; `running` is unchanged.
            waiters.removeFirst().resume()
        }
    }
}
