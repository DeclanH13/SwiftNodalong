import Foundation
import MusicKit
import NodalongKit

/// MusicKit-backed implementation of `MusicService`.
///
/// Replaces the Spotify Web Playback SDK + REST glue with Apple's first-party
/// music framework. Auth is tied to the device's Apple ID (no token storage),
/// playback goes through `ApplicationMusicPlayer.shared` (system handles
/// Control Center + lock-screen metadata), and catalog calls use the
/// `MusicCatalogSearchRequest` / `MusicCatalogResourceRequest` family.
///
/// **Cross-service track resolution:** `play(_:)` accepts a `Song` from any
/// source (including legacy Spotify-sourced posts in other users' feeds).
/// Resolution falls back in order: native Apple Music ID → ISRC →
/// title + artist text search.
@MainActor
final class AppleMusicService: ObservableObject, MusicService {

    // MARK: - Identity

    /// Returns `.appleMusic` — this conformer is permanently single-service.
    /// A future Spotify (or other) service would be a separate type that
    /// also conforms to `MusicService` and returns its own service tag.
    nonisolated var serviceType: MusicServiceType { .appleMusic }

    // MARK: - Authorization state

    /// Current Apple Music permission as reported by the OS. Updates live via
    /// `authorize()` and on foreground via `refreshAuthStatus()`.
    @Published private(set) var authStatus: MusicAuthorization.Status = .notDetermined

    /// `true` when the user has granted Apple Music access. Distinct from
    /// "has an active subscription" — see `canPlayFullTracks`.
    var isAuthenticated: Bool { authStatus == .authorized }

    /// `true` when access is permanently denied (user tapped Don't Allow, or
    /// parental controls restrict it). Recovery requires Settings — the
    /// system prompt will not reappear.
    var isDenied: Bool { authStatus == .denied || authStatus == .restricted }

    /// `true` when the user hasn't decided yet — i.e. the system prompt is
    /// still available. Used by `ContentView` to gate the onboarding cover.
    var isUndecided: Bool { authStatus == .notDetermined }

    // MARK: - Subscription state

    /// Snapshot of the user's Apple Music subscription as reported by
    /// MusicKit. Kept in sync via an async observer on
    /// `MusicSubscription.subscriptionUpdates`. `nil` before the observer
    /// has emitted its first value (typically the first moment after auth).
    @Published private(set) var subscription: MusicSubscription? = nil

    /// `true` when the user has an active Apple Music subscription and can
    /// stream full-length tracks via `ApplicationMusicPlayer`. Use this to
    /// gate playback affordances in the UI.
    var canPlayFullTracks: Bool {
        subscription?.canPlayCatalogContent == true
    }

    /// `true` when the user does not currently have a subscription but is
    /// eligible to start one (most regions). Drives the "Subscribe to Apple
    /// Music" button in Profile.
    var canBecomeSubscriber: Bool {
        subscription?.canBecomeSubscriber == true
    }

    /// Background task watching `MusicSubscription.subscriptionUpdates`.
    /// Cancelled and restarted by `refreshSubscriptionObserver()` when auth
    /// state changes (the stream only emits once authorised).
    private var subscriptionTask: Task<Void, Never>? = nil

    // MARK: - Init / deinit

    init() {
        authStatus = MusicAuthorization.currentStatus
        // Skip live observers inside the Xcode preview agent — they'd try to
        // talk to MusicKit which isn't available in the preview sandbox.
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" {
            startSubscriptionObserver()
        }
    }

    deinit {
        subscriptionTask?.cancel()
    }

    // MARK: - Authorization

    /// Triggers the system Apple Music permission prompt (first call) or
    /// reflects the current status. Idempotent — safe to call repeatedly.
    ///
    /// On a successful grant, restarts the subscription observer so we pick
    /// up the user's current Apple Music plan without waiting for the next
    /// system push.
    func authorize() async throws {
        let status = await MusicAuthorization.request()
        authStatus = status
        if status == .authorized {
            startSubscriptionObserver()
        }
        if status != .authorized {
            throw AppleMusicServiceError.notAuthorized(status)
        }
    }

    /// MusicKit auth is system-level — there's no per-app revoke. This just
    /// flips local state so the UI returns to the unauth flow until the user
    /// re-grants. The system permission stays granted in Settings.
    func logout() async throws {
        authStatus = .notDetermined
        subscription = nil
        subscriptionTask?.cancel()
        subscriptionTask = nil
    }

    /// Re-reads the system Apple Music permission and refreshes subscription
    /// observation. Call on foreground so the app picks up changes the user
    /// made in Settings (auth) or to their plan (subscription) while away.
    func refreshAuthStatus() {
        let prior = authStatus
        authStatus = MusicAuthorization.currentStatus
        // If access was just granted while we were backgrounded, kick the
        // subscription observer so it starts emitting.
        if prior != .authorized && authStatus == .authorized {
            startSubscriptionObserver()
        }
    }

    // MARK: - Subscription observation

    /// Spawns an async loop watching `MusicSubscription.subscriptionUpdates`
    /// and writing each emission into `subscription`. Cancels any prior
    /// task so we never have two observers running.
    ///
    /// Safe to call repeatedly. The async sequence yields the current
    /// subscription state on subscribe and again whenever it changes.
    ///
    /// The consuming loop is routed through `observeSubscriptionUpdates`, a
    /// `nonisolated` function, deliberately — NOT run inline here. On-device
    /// diagnostic logging (main-thread hang detector, see the decisions log)
    /// caught this exact call as the dominant cause of several-second UI
    /// freezes, repeatedly, throughout a session: MusicKit's subscription
    /// status can fall back to a deprecated, synchronous, in-process
    /// resolution path (confirmed via the console warning "it has recently
    /// become deprecated to request the music subscription status in
    /// process... you need to add
    /// com.apple.security.exception.mach-lookup.global-name
    /// com.apple.itunescloud.music-subscription-status-service to your
    /// sandbox" — a private entitlement not grantable to third-party apps,
    /// so the deprecated path can't be avoided). Because this `Task` used to
    /// be written directly inside this `@MainActor` method, Swift's closure
    /// isolation inference made the whole `for await` loop — including that
    /// synchronous fallback's blocking daemon IPC — run on the actual main
    /// thread. Moving just the loop into a `nonisolated` function keeps that
    /// blocking work off the main thread; only the per-update publish hops
    /// back to MainActor.
    private func startSubscriptionObserver() {
        subscriptionTask?.cancel()
        subscriptionTask = Task { [weak self] in
            await Self.observeSubscriptionUpdates { sub in
                self?.subscription = sub
            }
        }
    }

    /// Consumes `MusicSubscription.subscriptionUpdates` off the MainActor —
    /// see `startSubscriptionObserver`'s doc comment for why this must not
    /// run inline on the caller's actor. `onUpdate` is `@MainActor` so the
    /// only actor-hop is the cheap publish, not the resolution itself.
    nonisolated private static func observeSubscriptionUpdates(
        onUpdate: @escaping @Sendable @MainActor (MusicSubscription) -> Void
    ) async {
        for await sub in MusicSubscription.subscriptionUpdates {
            if Task.isCancelled { break }
            await onUpdate(sub)
        }
    }

    // MARK: - Library

    func getSavedTracks() async throws -> [NodalongKit.Song] {
        var req = MusicLibraryRequest<MusicKit.Song>()
        req.limit = 100
        let resp = try await req.response()
        return resp.items.compactMap { Self.toSong($0) }
    }

    func getRecentlyPlayed() async throws -> [NodalongKit.Song] {
        // Default for `MusicRecentlyPlayedRequest` is ~10 items, which is
        // why the user's Profile recent-tracks list had so few entries —
        // the source data was capped at the API layer before we ever wrote
        // it to Firestore. Bumping to 25 gives us comfortably 2 pages of 12
        // in the swipeable carousel, with headroom for de-dup against the
        // saved-tracks set during sync.
        var req = MusicRecentlyPlayedRequest<MusicKit.Song>()
        req.limit = 25
        let resp = try await req.response()
        // Artwork isn't resolved here — the catalog is the single source of
        // truth and is healed at ingest time (`LibrarySyncService`), so a
        // library-matched track's `musicKit://`/empty artwork is fixed once,
        // on the catalog row, rather than per-listen.
        return resp.items.compactMap { Self.toSong($0) }
    }

    // When an ISRC matches multiple catalog releases (original album, deluxe
    // reissue, "Greatest Hits" compilation), prefers the one whose album name
    // matches `album` (when known) over an unfiltered `.items.first` — see
    // `NodalongKit`'s `ReleaseMatching.swift`.
    private static func resolveCatalogArtwork(isrc: String, album: String? = nil) async -> String? {
        let req = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.isrc, equalTo: isrc)
        guard let items = try? await req.response().items, !items.isEmpty else { return nil }
        let idx = bestReleaseIndex(albumNames: items.map { $0.albumTitle ?? "" }, expectedAlbum: album) ?? 0
        let artwork = artworkURL(items[idx].artwork)
        return artwork.isEmpty ? nil : artwork
    }

    /// Resolve a fetchable catalog artwork URL for a track, trying the most
    /// precise anchor first: direct catalog-id → ISRC → title+artist search.
    /// Returns `nil` if none yields a usable `https://` URL. Used by the
    /// one-time catalog artwork repair to replace `musicKit://` / empty art.
    ///
    /// The title+artist search is the *only* viable anchor for library-matched
    /// tracks — they carry a library-scoped id (invalid for a catalog id
    /// lookup) and usually no ISRC. It's the same fallback `resolve()` uses for
    /// playback, so a match here means the track is genuinely findable in the
    /// catalog. Artwork-only, so a wrong-release match at worst swaps art, never
    /// identity.
    ///
    /// `album`, when known, lets `bestReleaseIndex` prefer the release that
    /// actually matches over an arbitrary first result (e.g. a "Greatest
    /// Hits" compilation sharing the same ISRC as the original album track).
    func resolveCatalogArtwork(
        appleMusicTrackId: String?,
        isrc: String?,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil
    ) async -> String? {
        // `i.`-prefixed ids are LIBRARY-scoped, not catalog ids — a catalog
        // lookup for one is a guaranteed 404 (plus MusicKit's own automatic
        // retry). `PlayerViewModel.resolve` already skips them for this
        // exact reason; this path didn't, so every library-matched recent
        // play paid two dead round trips before falling through to the
        // search that was always going to be the one that worked.
        if let id = appleMusicTrackId, !id.isEmpty, !id.hasPrefix("i.") {
            let req = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.id, equalTo: MusicItemID(id))
            if let song = try? await req.response().items.first {
                let art = Self.artworkURL(song.artwork)
                if !art.isEmpty { return art }
            }
        }
        if let isrc, !isrc.isEmpty, let art = await Self.resolveCatalogArtwork(isrc: isrc, album: album) {
            return art
        }
        if let title, !title.isEmpty {
            let term = [title, artist].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
            var search = MusicCatalogSearchRequest(term: term, types: [MusicKit.Song.self])
            search.limit = 5
            if let songs = try? await search.response().songs, !songs.isEmpty {
                let idx = bestReleaseIndex(albumNames: songs.map { $0.albumTitle ?? "" }, expectedAlbum: album) ?? 0
                let art = Self.artworkURL(songs[idx].artwork)
                if !art.isEmpty { return art }
            }
        }
        return nil
    }

    // MARK: - Playback

    /// Resolve and enqueue a single track. Calls `play()` on
    /// `ApplicationMusicPlayer.shared`; the system handles audio, lock screen,
    /// Control Center. Subscription gating + preview fallback lives in
    /// `PlayerViewModel`, not here.
    func play(_ song: NodalongKit.Song) async throws {
        let musicKitSong = try await resolve(song)
        let player = ApplicationMusicPlayer.shared
        player.queue = [musicKitSong]
        try await player.play()
    }

    func resume() async throws {
        try await ApplicationMusicPlayer.shared.play()
    }

    func pause() async throws {
        ApplicationMusicPlayer.shared.pause()
    }

    // MARK: - Search

    func searchTracks(_ query: String, maxResults: Int) async throws -> [NodalongKit.Song] {
        var req = MusicCatalogSearchRequest(term: query, types: [MusicKit.Song.self])
        req.limit = maxResults
        let resp = try await req.response()
        return resp.songs.compactMap { Self.toSong($0) }
    }

    func searchArtists(_ query: String, maxResults: Int) async throws -> [ArtistResult] {
        var req = MusicCatalogSearchRequest(term: query, types: [MusicKit.Artist.self])
        req.limit = maxResults
        let resp = try await req.response()
        return resp.artists.compactMap { Self.toArtistResult($0) }
    }

    func searchAlbums(_ query: String, maxResults: Int) async throws -> [AlbumResult] {
        var req = MusicCatalogSearchRequest(term: query, types: [MusicKit.Album.self])
        req.limit = maxResults
        let resp = try await req.response()
        return resp.albums.compactMap { Self.toAlbumResult($0) }
    }

    func searchByIsrc(_ isrc: String) async throws -> SearchResult? {
        let req = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.isrc, equalTo: isrc)
        let resp = try await req.response()
        guard let song = resp.items.first else { return nil }
        return SearchResult(uri: song.id.rawValue, trackId: song.id.rawValue, isrc: song.isrc)
    }

    func searchByTitleArtist(title: String, artist: String) async throws -> SearchResult? {
        var req = MusicCatalogSearchRequest(term: "\(title) \(artist)", types: [MusicKit.Song.self])
        req.limit = 1
        let resp = try await req.response()
        guard let song = resp.songs.first else { return nil }
        return SearchResult(uri: song.id.rawValue, trackId: song.id.rawValue, isrc: song.isrc)
    }

    func searchAll(
        _ query: String,
        maxPerType: Int
    ) async throws -> (artists: [ArtistResult], albums: [AlbumResult], tracks: [NodalongKit.Song]) {
        var req = MusicCatalogSearchRequest(
            term: query,
            types: [MusicKit.Song.self, MusicKit.Artist.self, MusicKit.Album.self]
        )
        req.limit = maxPerType
        let resp = try await req.response()
        return (
            artists: resp.artists.compactMap { Self.toArtistResult($0) },
            albums:  resp.albums.compactMap  { Self.toAlbumResult($0) },
            tracks:  resp.songs.compactMap   { Self.toSong($0) }
        )
    }

    // MARK: - Browse

    /// Apple Music's own personalized recommendations
    /// (`MusicPersonalRecommendationsRequest`), grouped into their real
    /// titled shelves (e.g. "New Music Mix") instead of flattened — powers
    /// Home's "Recommended for You" section and the "See All" detail screen.
    /// v1 surfaces ALBUMS ONLY per shelf — the payload also includes
    /// playlists and stations, deferred (would need their own model types +
    /// UI). Shelves with no albums (e.g. a playlist/station-only group) are
    /// dropped rather than shown empty. Subscriber + real-device only;
    /// callers should gate on `canPlayFullTracks` before calling (an
    /// unsubscribed account simply gets nothing back to show).
    ///
    /// Apple's own engine sometimes dynamically titles one of these shelves
    /// "Recently Played" — confirmed on-device (screenshot) showing
    /// noticeably STALER content than Home's own "Jump Back In", which is
    /// built from Nodalong's own freshly-synced data. Since it duplicates
    /// Jump Back In's job with less-fresh, Apple-controlled content, that
    /// specific shelf is filtered out here — at the source, so both Home's
    /// inline section and the "See All" detail screen get the fix for free.
    func getPersonalRecommendations(maxGroups: Int) async throws -> [RecommendationShelf] {
        let response = try await personalRecommendations(maxGroups: maxGroups)
        return response.recommendations.compactMap { rec -> RecommendationShelf? in
            let title = rec.title ?? "Recommended"
            guard title.trimmingCharacters(in: .whitespaces).lowercased() != "recently played" else { return nil }
            let albums = rec.albums.compactMap { Self.toAlbumResult($0) }
            guard !albums.isEmpty else { return nil }
            return RecommendationShelf(id: rec.id.rawValue, title: title, albums: albums)
        }
    }

    /// Apple's curated playlist mixes ("New Music Mix", "Chill Mix") — the
    /// `playlists` relationship on the same `MusicPersonalRecommendationsRequest`
    /// payload `getPersonalRecommendations` already reads for albums, previously
    /// discarded. A genuinely different content type (curated playlists, not
    /// albums), so surfaced as its own "Made For You" section rather than folded
    /// into "Recommended for You". Subscriber + real-device only, same gate as
    /// `getPersonalRecommendations`.
    func getMadeForYouPlaylists(maxGroups: Int) async throws -> [PlaylistResult] {
        let response = try await personalRecommendations(maxGroups: maxGroups)
        // The same playlist can legitimately appear in more than one
        // recommendation group — flattening without a dedupe produced
        // duplicate ids in Home's Made For You `ForEach` ("the ID pl.pm-…
        // occurs multiple times within the collection", undefined SwiftUI
        // behavior). Keep first occurrence, preserve order.
        var seen = Set<String>()
        return response.recommendations
            .flatMap { $0.playlists }
            .compactMap { Self.toPlaylistResult($0) }
            .filter { seen.insert($0.id).inserted }
    }

    /// `getPersonalRecommendations` (albums) and `getMadeForYouPlaylists`
    /// (playlists) read DIFFERENT relationships off the SAME
    /// `MusicPersonalRecommendationsRequest` payload, and Home fires both
    /// concurrently at launch — two identical, expensive MusicKit round trips
    /// (measured 1671ms + 1990ms on a cold launch, contending with everything
    /// else Home/Feed/Library/runSync were also doing at that moment) for one
    /// payload's worth of data.
    ///
    /// Shares only the IN-FLIGHT request, not a completed result: the memo is
    /// cleared once the first caller returns, so the launch race collapses to
    /// one request while a later pull-to-refresh still genuinely re-fetches
    /// instead of replaying a stale session-cached payload.
    private var recommendationsMemo: (groups: Int, task: Task<MusicPersonalRecommendationsResponse, Error>)?

    private func personalRecommendations(maxGroups: Int) async throws -> MusicPersonalRecommendationsResponse {
        if let memo = recommendationsMemo, memo.groups == maxGroups {
            diagLog("personalRecommendations(\(maxGroups)): joined in-flight/memoed request")
            return try await memo.task.value
        }
        let task = Task { () throws -> MusicPersonalRecommendationsResponse in
            var request = MusicPersonalRecommendationsRequest()
            request.limit = maxGroups
            return try await request.response()
        }
        recommendationsMemo = (maxGroups, task)
        defer { if recommendationsMemo?.groups == maxGroups { recommendationsMemo = nil } }
        return try await task.value
    }

    /// Tracks for a Made For You playlist tile tap — mirrors `getAlbumTracks`'s
    /// relationship-loading shape exactly.
    func getPlaylistTracks(playlistId: String) async throws -> [NodalongKit.Song] {
        guard !playlistId.isEmpty else { return [] }
        let req = MusicCatalogResourceRequest<MusicKit.Playlist>(matching: \.id, equalTo: MusicItemID(playlistId))
        let resp = try await req.response()
        guard let playlist = resp.items.first else { return [] }
        let detailed = try await playlist.with([.tracks])
        return (detailed.tracks ?? []).compactMap { track in
            guard case .song(let song) = track else { return nil }
            return Self.toSong(song)
        }
    }

    /// Global/storefront Top Charts (`MusicCatalogChartsRequest`, no genre —
    /// overall chart) — the one Home section with zero personalization,
    /// what's trending right now rather than anything about this user. Not
    /// subscription-gated (a catalog browse, same as `searchTracks`).
    func getTopChartSongs(limit: Int) async throws -> [NodalongKit.Song] {
        let req = MusicCatalogChartsRequest(types: [MusicKit.Song.self])
        let resp = try await req.response()
        guard let chart = resp.songCharts.first else { return [] }
        return chart.items.prefix(limit).compactMap { Self.toSong($0) }
    }

    /// Global/storefront popular-albums chart (`MusicCatalogChartsRequest`,
    /// `resp.albumCharts` — verified via a typecheck probe before writing
    /// this, mirroring `getTopChartSongs`'s song-chart sibling). Deliberately
    /// labeled "Popular albums" wherever it's shown, not "New releases" —
    /// this is a popularity chart, not a recency feed, and MusicKit's public
    /// API has no genuine "new releases" endpoint to back that label
    /// honestly. Not subscription-gated, same as `getTopChartSongs`.
    func getPopularAlbums(limit: Int) async throws -> [AlbumResult] {
        let req = MusicCatalogChartsRequest(types: [MusicKit.Album.self])
        let resp = try await req.response()
        guard let chart = resp.albumCharts.first else { return [] }
        return chart.items.prefix(limit).compactMap { Self.toAlbumResult($0) }
    }

    func getArtistAlbums(artistId: String) async throws -> [AlbumResult] {
        guard !artistId.isEmpty else { return [] }
        let req = MusicCatalogResourceRequest<MusicKit.Artist>(
            matching: \.id,
            equalTo: MusicItemID(artistId)
        )
        let resp = try await req.response()
        guard let artist = resp.items.first else { return [] }
        let detailed = try await artist.with([.albums])
        return (detailed.albums ?? []).compactMap { Self.toAlbumResult($0) }
    }

    func getArtistTopTracks(artistId: String) async throws -> [NodalongKit.Song] {
        guard !artistId.isEmpty else { return [] }
        let req = MusicCatalogResourceRequest<MusicKit.Artist>(
            matching: \.id,
            equalTo: MusicItemID(artistId)
        )
        let resp = try await req.response()
        guard let artist = resp.items.first else { return [] }
        let detailed = try await artist.with([.topSongs])
        return (detailed.topSongs ?? []).compactMap { Self.toSong($0) }
    }

    /// Combined artist-detail fetch — ONE round trip requesting the artist
    /// plus its `.albums`/`.topSongs`/`.similarArtists`/`.appearsOnAlbums`
    /// relationships together (via `properties`, not separate `.with([...])`
    /// calls after), instead of `getArtistAlbums`/`getArtistTopTracks` each
    /// separately re-fetching the same `Artist` resource (4 round trips
    /// where 1 now suffices). Kept off the `MusicService` protocol —
    /// Apple-only, same precedent as `getPersonalRecommendations`; the
    /// Spotify path (suspended, but must keep compiling) still uses the
    /// separate pair via the protocol and has no similar-artists/appears-on
    /// equivalent.
    ///
    /// `appearsOnAlbums` is ALBUM-shaped, not song-shaped — MusicKit has no
    /// per-track credit relationship, so there's no reliable way to know
    /// which specific track on a compilation actually features this artist.
    /// Surfacing it as albums (not a guessed song list) is the honest
    /// option.
    /// Albums + top songs only — the two things an artist screen needs to
    /// render its primary content. Split from what used to be one combined
    /// `getArtistDetails` request also fetching `.similarArtists`/
    /// `.appearsOnAlbums` — on-device diagnostic timing showed the combined
    /// fetch taking 1.5–2.1s, with the whole screen (including Discography/
    /// Top Songs) gated behind ALL FOUR relationships resolving even though
    /// only two of them are needed for what's visible first. See
    /// `getArtistExtras` for the other two, fetched separately so Discography/
    /// Top Songs can render as soon as THIS finishes, not waiting on Similar
    /// Artists/Features On too.
    /// One round trip, deliberately WITHOUT paginating top songs — see
    /// `getArtistTopSongsFull` for why. On-device timing showed
    /// `paginatedTopSongs` alone eating 55–74% of this call's total time
    /// across three different artists (507–1104ms of 925–1488ms), even
    /// though a screen only needs ~10 songs to render something real —
    /// paginating to 30 inside the critical path was pure added latency for
    /// content that's mostly below the fold anyway.
    func getArtistCore(artistId: String) async throws -> (
        albums: [AlbumResult],
        topTracks: [NodalongKit.Song]
    ) {
        guard !artistId.isEmpty else { return ([], []) }
        let t0 = Date()
        defer { diagLog("getArtistCore(\(artistId)): \(Int(Date().timeIntervalSince(t0) * 1000))ms") }
        var req = MusicCatalogResourceRequest<MusicKit.Artist>(
            matching: \.id,
            equalTo: MusicItemID(artistId)
        )
        req.properties = [.albums, .topSongs]
        let resp = try await req.response()
        guard let artist = resp.items.first else { return ([], []) }

        let rawAlbums = (artist.albums ?? []).compactMap { Self.toAlbumResult($0) }
        let firstPage = (artist.topSongs ?? []).compactMap { Self.toSong($0) }
        return (dedupeAlbumEditions(rawAlbums), firstPage)
    }

    /// Background-only top-up: pages the SAME artist's `.albums` relationship
    /// out to `limit`, mirroring `getArtistTopSongsFull`/`paginatedTopSongs`
    /// exactly — `getArtistCore`'s own `artist.albums` was found to have the
    /// identical "one unpaginated page from Apple, nothing tops it up"
    /// limitation `topSongs` already had, just never given the same fix:
    /// confirmed on a real, never-before-viewed artist (not a warm-cache
    /// one, which is what an earlier diagnosis pass mistakenly generalized
    /// from) that the Discography grid's first page could genuinely be
    /// short — not a rendering bug, an incomplete fetch. `dedupeAlbumEditions`
    /// re-runs over the FULL paginated set here (not just the first page),
    /// so editions that only show up once paginated far enough still
    /// collapse correctly.
    func getArtistAlbumsFull(artistId: String, limit: Int = 50) async throws -> [AlbumResult] {
        guard !artistId.isEmpty else { return [] }
        let t0 = Date()
        defer { diagLog("getArtistAlbumsFull(\(artistId)): \(Int(Date().timeIntervalSince(t0) * 1000))ms") }
        var req = MusicCatalogResourceRequest<MusicKit.Artist>(
            matching: \.id,
            equalTo: MusicItemID(artistId)
        )
        req.properties = [.albums]
        let resp = try await req.response()
        guard let artist = resp.items.first else { return [] }
        let albums = await Self.paginatedAlbums(artist.albums, limit: limit)
        return dedupeAlbumEditions(albums.compactMap { Self.toAlbumResult($0) })
    }

    private static func paginatedAlbums(
        _ initial: MusicItemCollection<MusicKit.Album>?,
        limit: Int
    ) async -> [MusicKit.Album] {
        guard var page = initial else { return [] }
        var items = Array(page)
        var extraBatches = 0
        let t0 = Date()
        while items.count < limit, page.hasNextBatch, extraBatches < 5 {
            guard let next = try? await page.nextBatch() else { break }
            page = next
            items.append(contentsOf: page)
            extraBatches += 1
        }
        if extraBatches > 0 {
            diagLog("paginatedAlbums: \(extraBatches) extra batches, \(Int(Date().timeIntervalSince(t0) * 1000))ms")
        }
        return Array(items.prefix(limit))
    }

    /// Background-only top-up: pages the SAME artist's top songs out to
    /// `limit`, run *after* `getArtistCore` has already let the screen render
    /// with the first page. Does its own lighter fetch (`.topSongs` only, not
    /// `.albums` too) rather than threading `getArtistCore`'s own
    /// `MusicItemCollection` continuation through — that state can't cross
    /// `MusicDetailCache`'s actor boundary cleanly (the cache only ever holds
    /// plain `Codable`-shaped results, never live MusicKit types, per the
    /// project's seam rule). The cost is one small extra artist-resource
    /// fetch; the win is that it happens off the critical path entirely.
    func getArtistTopSongsFull(artistId: String, limit: Int = 30) async throws -> [NodalongKit.Song] {
        guard !artistId.isEmpty else { return [] }
        let t0 = Date()
        defer { diagLog("getArtistTopSongsFull(\(artistId)): \(Int(Date().timeIntervalSince(t0) * 1000))ms") }
        var req = MusicCatalogResourceRequest<MusicKit.Artist>(
            matching: \.id,
            equalTo: MusicItemID(artistId)
        )
        req.properties = [.topSongs]
        let resp = try await req.response()
        guard let artist = resp.items.first else { return [] }
        let topSongs = await Self.paginatedTopSongs(artist.topSongs, limit: limit)
        return topSongs.compactMap { Self.toSong($0) }
    }

    /// Similar artists + "features on" albums — the two secondary
    /// relationships, fetched independently of `getArtistCore` so a slower
    /// (or less commonly viewed) part of the screen never blocks the primary
    /// content. See `getArtistCore`'s doc comment for the split rationale.
    func getArtistExtras(artistId: String) async throws -> (
        similarArtists: [ArtistResult],
        featuresOn: [AlbumResult]
    ) {
        guard !artistId.isEmpty else { return ([], []) }
        let t0 = Date()
        defer { diagLog("getArtistExtras(\(artistId)): \(Int(Date().timeIntervalSince(t0) * 1000))ms") }
        var req = MusicCatalogResourceRequest<MusicKit.Artist>(
            matching: \.id,
            equalTo: MusicItemID(artistId)
        )
        req.properties = [.similarArtists, .appearsOnAlbums]
        let resp = try await req.response()
        guard let artist = resp.items.first else { return ([], []) }

        return (
            (artist.similarArtists ?? []).compactMap { Self.toArtistResult($0) },
            (artist.appearsOnAlbums ?? []).compactMap { Self.toAlbumResult($0) }
        )
    }

    /// `Artist.topSongs` comes back as one page (Apple's own relationship
    /// default, ~10 items) — pages forward via `MusicItemCollection`'s own
    /// `nextBatch()` until either `limit` is reached or the catalog runs out.
    /// Bounded to a handful of extra round trips regardless of `limit`, so a
    /// mis-set `hasNextBatch` can't spin forever.
    private static func paginatedTopSongs(
        _ initial: MusicItemCollection<MusicKit.Song>?,
        limit: Int
    ) async -> [MusicKit.Song] {
        guard var page = initial else { return [] }
        var items = Array(page)
        var extraBatches = 0
        let t0 = Date()
        while items.count < limit, page.hasNextBatch, extraBatches < 5 {
            guard let next = try? await page.nextBatch() else { break }
            page = next
            items.append(contentsOf: page)
            extraBatches += 1
        }
        if extraBatches > 0 {
            diagLog("paginatedTopSongs: \(extraBatches) extra batches, \(Int(Date().timeIntervalSince(t0) * 1000))ms")
        }
        return Array(items.prefix(limit))
    }

    func getAlbumTracks(
        albumId: String,
        albumName: String,
        artwork: String
    ) async throws -> [NodalongKit.Song] {
        guard !albumId.isEmpty else { return [] }
        let t0 = Date()
        defer { diagLog("getAlbumTracks(\(albumId)): \(Int(Date().timeIntervalSince(t0) * 1000))ms") }
        // `properties` requests the `.tracks` relationship as part of THIS
        // fetch instead of a separate `.with([.tracks])` round trip after —
        // one network call instead of two. This is the code path EVERY
        // album screen in the app hits on a cache miss (direct pushes from
        // Search/Home rails/Shelf's own `AlbumResult` destinations skip
        // `ResolvingAlbumView`'s resolve step entirely and land here cold),
        // so halving its round trips speeds up every album open, not just
        // the ones that go through `resolveAlbum`'s prefetch.
        var req = MusicCatalogResourceRequest<MusicKit.Album>(
            matching: \.id,
            equalTo: MusicItemID(albumId)
        )
        req.properties = [.tracks]
        let resp = try await req.response()
        guard let album = resp.items.first else { return [] }
        return (album.tracks ?? []).compactMap { track in
            guard case .song(let song) = track else { return nil }
            return Self.toSong(song, overrideAlbum: albumName, overrideArtwork: artwork)
        }
    }

    // MARK: - Resolution

    /// Maps a generic `Song` (which may be Apple-Music-sourced, Spotify-sourced
    /// from a legacy post, or freshly searched) onto a playable
    /// `MusicKit.Song`. Tries direct ID first, then ISRC, then text search.
    private func resolve(_ song: NodalongKit.Song) async throws -> MusicKit.Song {
        if song.sourceService == .appleMusic, !song.uri.isEmpty {
            let req = MusicCatalogResourceRequest<MusicKit.Song>(
                matching: \.id,
                equalTo: MusicItemID(song.uri)
            )
            if let hit = try? await req.response().items.first { return hit }
        }
        if let isrc = song.isrc, !isrc.isEmpty {
            let req = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.isrc, equalTo: isrc)
            if let hit = try? await req.response().items.first { return hit }
        }
        var search = MusicCatalogSearchRequest(
            term: "\(song.title) \(song.artist)",
            types: [MusicKit.Song.self]
        )
        search.limit = 1
        if let hit = try? await search.response().songs.first { return hit }
        throw AppleMusicServiceError.trackNotFound
    }

    /// Resolves the exact album a track belongs to via MusicKit's `Song.albums`
    /// relationship rather than a fuzzy text search — this is what Now
    /// Playing's album tap uses, so a shared album name (e.g. a deluxe
    /// reissue) can never resolve to the wrong release the way
    /// `searchAll(...).albums.first` could.
    func resolveAlbum(
        catalogTrackId: String?,
        isrc: String?,
        title: String,
        artist: String,
        trackTitle: String = ""
    ) async -> AlbumResult? {
        // THE app-wide album resolver — every "open the album named X"
        // surface (Now Playing's album tap, Home's Jump Back In / Friends
        // Listening, Shelf's Apple path) routes here so they all behave
        // identically. `title` is the album name the UI is ALREADY
        // DISPLAYING, sourced from MusicKit's own `Song.albumTitle` (or a
        // persisted copy of it) — so the NAME is trustworthy; what needs
        // resolving is which catalog release it denotes. Strategy, in
        // confidence order:
        //
        // 1. An EXACT-name release from the resolved track's `.albums`
        //    RELATIONSHIP — highest confidence, guaranteed to both contain
        //    the track AND be the exact named release.
        // 2. A direct catalog ALBUM search by the known name + artist,
        //    gated on an exact-ish match — covers the true release not
        //    being in the relationship at all (a pre-release single whose
        //    song only lists its upcoming parent album) by searching the
        //    WHOLE catalog rather than settling for whatever this one
        //    recording's own relationship happens to contain.
        // 3. A looser, containment-level match within the relationship
        //    ("- Single"/"- EP" store-suffix variance) — ONLY tried after
        //    (1) and (2) have both failed to find an exact release. Trying
        //    this before (2) was an earlier bug: a recording whose OWN
        //    relationship contains only a promotional single/feat. edit of
        //    an album (e.g. "We Will Always Love You (feat. Blood Orange)
        //    - Single" for a recording that's really off "We Will Always
        //    Love You") would win here via containment before the catalog
        //    search — which could have found the real, full album — ever
        //    got a chance to run.
        //
        // There is deliberately NO step 4 "best of what's left" fallback —
        // an earlier version of this cascade took `bestReleaseIndex`'s
        // top-scored candidate with no match check at all when steps 1–3
        // all failed, which meant it could silently return a release with
        // ZERO relationship to `title` (confirmed bug: tapping "Place -
        // Single" opened "Like I Used To (Deluxe Edition)" — the two names
        // share nothing, but the deluxe edition was the only album in that
        // recording's relationship, so it won by being "the best of a bad
        // lot"). A UI that shows a specific name before resolving and then
        // silently swaps to a different one after is worse than an honest
        // failure — when nothing here genuinely matches `title`, that's a
        // resolve MISS, not a substitution; the caller's `ResolvingAlbumView`
        // already has a "Couldn't find this album" state for exactly this.
        // `trackTitle`, NOT `title`. `title` here is the ALBUM name, and
        // `resolveDetailedSong`'s last-resort step is a **Song** text search —
        // so passing `title` made it search for a song called e.g. "Place -
        // Single", which doesn't exist (the song is "Place"). That step could
        // therefore essentially never succeed on this path, leaving album
        // resolution dependent entirely on the id/ISRC anchors; when both were
        // weak (a library-scoped uri, no stored ISRC) the whole resolve failed
        // — the confirmed "Couldn't find this album" case. The workaround
        // comment on `resolveArtists` describes this same parameter misuse;
        // this fixes the cause instead of routing around it.
        let song = await resolveDetailedSong(
            catalogTrackId: catalogTrackId, isrc: isrc,
            title: trackTitle.isEmpty ? title : trackTitle, artist: artist
        )
        let relationshipAlbums = Array(song?.albums ?? [])

        // Diagnostic for the "Couldn't find this album" reports. Logs the
        // ANCHORS this resolve actually had (a weak/absent id + missing ISRC
        // is the difference between a reliable lookup and a text search) and
        // which cascade step answered — so a failure produces facts instead
        // of another hypothesis. Cheap and only fires on a real resolve.
        diagLog("[Nodalong.ResolveAlbum] album='\(title)' artist='\(artist)' trackTitle='\(trackTitle)' id=\(catalogTrackId ?? "nil") isrc=\(isrc ?? "nil") song=\(song != nil ? "resolved" : "NIL") relAlbums=\(relationshipAlbums.map(\.title))")

        let result: AlbumResult?
        if let idx = relationshipAlbums.firstIndex(where: { albumNamesExactMatch($0.title, title) }) {
            result = Self.toAlbumResult(relationshipAlbums[idx])
            diagLog("[Nodalong.ResolveAlbum] → step 1 (relationship exact): '\(relationshipAlbums[idx].title)'")
        } else if let searched = await searchAlbumCatalog(named: title, artist: artist) {
            result = searched
            diagLog("[Nodalong.ResolveAlbum] → step 2 (catalog album search): '\(searched.name)'")
        } else if let idx = bestReleaseIndex(albumNames: relationshipAlbums.map(\.title), expectedAlbum: title),
                  albumNamesMatch(relationshipAlbums[idx].title, title) {
            result = Self.toAlbumResult(relationshipAlbums[idx])
            diagLog("[Nodalong.ResolveAlbum] → step 3 (relationship containment): '\(relationshipAlbums[idx].title)'")
        } else {
            result = nil
            diagLog("[Nodalong.ResolveAlbum] → ALL STEPS FAILED for album='\(title)'")
        }

        // Prewarm the track list before returning, so every caller of this
        // resolver (Now Playing's album tap, Home's Jump Back In, Shelf) —
        // which each present a `ResolvingAlbumView` spinner while this runs,
        // then swap to `AlbumDetailSearchView` once it returns — hands off
        // to a screen that's already populated instead of one that starts
        // its OWN separate `getAlbumTracks` fetch with its own skeleton
        // rows. Without this, resolving-then-fetching reads as two
        // back-to-back loading screens instead of one continuous load.
        // Awaited (not fire-and-forget) so the combined wait is covered by
        // the resolver's own caller, not split across two visible states.
        // `MusicDetailCache.tracks` shares in-flight work, so this can never
        // duplicate `AlbumDetailSearchView`'s own subsequent call — it just
        // arrives to a warm (or already in-flight) cache.
        if let result {
            let (id, name, artwork) = (result.id, result.name, result.artwork)
            let tracks = await MusicDetailCache.shared.tracks(albumId: id) { [weak self] in
                guard let self else { return [] }
                return (try? await self.getAlbumTracks(albumId: id, albumName: name, artwork: artwork)) ?? []
            }

            // Also prewarm each track's canonical catalogId into `TrackCache`
            // — a real Firestore transaction (`upsertCatalogTrack`) per
            // unsaved track was the cause of a noticeable delay between
            // tapping "Save Album" and the button flipping, since
            // `LibraryViewModel.saveAlbum` had to resolve every track's
            // catalogId before its optimistic UI update could run.
            //
            // Deliberately NOT awaited: it only needs to finish before the
            // user taps "Save Album," not before this resolver returns —
            // awaiting it here would extend the loading screen by up to N
            // more Firestore transactions, undoing the "resolve + track
            // fetch reads as one continuous load" fix directly above. It
            // runs quietly in the background while the user is looking at
            // the (already-loaded) track list; by the time they actually
            // tap Save, `ensureCatalogId(forLibrary:)` normally finds a
            // cache hit instead of a fresh round trip. Best-effort — a
            // failure here just means Save falls back to its own slower but
            // correct resolution, same as before this existed.
            Task {
                await withTaskGroup(of: Void.self) { group in
                    for track in tracks {
                        group.addTask { _ = try? await ensureCatalogId(for: track) }
                    }
                }
            }
        }
        return result
    }

    /// Step 2 of `resolveAlbum`: a catalog album search by name + artist,
    /// returning a hit only when its name genuinely matches — a fuzzy search
    /// result that *doesn't* name-match is worse than falling through, since
    /// landing on an arbitrary similarly-worded release is the exact failure
    /// this resolver exists to prevent.
    private func searchAlbumCatalog(named albumName: String, artist: String) async -> AlbumResult? {
        guard !albumName.isEmpty else { return nil }

        // Two query attempts: the name as given, then the name with store
        // noise stripped ("Place - Single" -> "Place").
        //
        // Why the second one matters, from a real device capture: for
        // album='Place - Single' artist='Lucy Rose' this step searched Apple
        // for the literal term "Place - Single Lucy Rose" and came back with
        // nothing, so the whole resolve failed ("Couldn't find this album")
        // even though the release exists. The " - Single" suffix is a STORE
        // decoration, not part of how the album is indexed — it pollutes the
        // query. Matching is unaffected: candidates are still checked against
        // the ORIGINAL `albumName`, and `albumNamesMatch` already tolerates
        // suffix variance in either direction, so a "Place" or a
        // "Place - Single" candidate both match while an unrelated release
        // still doesn't. Ordered so the exact term wins when it works —
        // the stripped query only runs if the first found nothing usable.
        let stripped = stripSearchNoise(albumName)
        var terms = ["\(albumName) \(artist)"]
        if stripped != albumName, !stripped.isEmpty {
            terms.append("\(stripped) \(artist)")
        }

        for term in terms {
            var search = MusicCatalogSearchRequest(term: term, types: [MusicKit.Album.self])
            search.limit = 10
            guard let resp = try? await search.response() else { continue }
            let candidates = resp.albums.compactMap { Self.toAlbumResult($0) }
            guard let idx = bestReleaseIndex(albumNames: candidates.map(\.name), expectedAlbum: albumName),
                  albumNamesMatch(candidates[idx].name, albumName) else {
                diagLog("[Nodalong.ResolveAlbum]   searchAlbumCatalog term='\(term)' -> no usable match among \(candidates.map(\.name))")
                continue
            }
            diagLog("[Nodalong.ResolveAlbum]   searchAlbumCatalog term='\(term)' -> '\(candidates[idx].name)'")
            return candidates[idx]
        }
        return nil
    }

    /// Resolves every artist actually credited on a track via MusicKit's
    /// `Song.artists` relationship — returns more than one `ArtistResult` when
    /// a track has multiple credited artists (e.g. "Jamie xx & Honey Dijon"),
    /// so the caller can offer a choice instead of silently picking one.
    ///
    /// `resolveDetailedSong`'s own last-resort text-search step has no
    /// confidence check on which SONG it lands on (it can't — it's shared
    /// with `resolveAlbum`, whose callers pass an ALBUM name into it, so a
    /// title-match check at that level would break the album path). Filters
    /// the resolved song's artist list against the expected `artist` credit
    /// string before returning, so a wrong-song pick here can't silently
    /// surface an unrelated artist the way it did for albums — same bug
    /// class, same fix shape. Reuses `albumNamesMatch(_:_:)` (a generic
    /// normalized equality-or-containment check, despite the name) rather
    /// than a strict equality check — for a multi-credit string like "Jamie
    /// xx & Honey Dijon", the credit string CONTAINS each individual
    /// artist's name, so both keep matching and the multi-artist picker
    /// still works. Falls back to the unfiltered list only when `artist` is
    /// itself empty (nothing to check against); otherwise an empty match
    /// means an honest not-found — `ResolvingArtistsView` already treats an
    /// empty result that way.
    func resolveArtists(
        catalogTrackId: String?,
        isrc: String?,
        title: String,
        artist: String
    ) async -> [ArtistResult] {
        guard let song = await resolveDetailedSong(
            catalogTrackId: catalogTrackId, isrc: isrc, title: title, artist: artist
        ) else { return [] }
        let resolved = (song.artists ?? []).compactMap { Self.toArtistResult($0) }
        guard !artist.isEmpty else { return resolved }
        return resolved.filter { albumNamesMatch($0.name, artist) }
    }

    /// Shared id → ISRC → title/artist cascade, mirroring
    /// `resolveCatalogArtwork`'s cascade exactly (a library-matched
    /// recently-played track's own id is frequently a library-scoped id, not a
    /// real catalog id — text search is the only anchor that works for
    /// those). Returns the matched song with `.albums`/`.artists`
    /// relationships loaded.
    /// Single-entry memo — tapping artist then album (or vice versa) on the
    /// same Now Playing track used to run this whole id→ISRC→text cascade
    /// twice, since `resolveAlbum`/`resolveArtists` never shared their
    /// result. The memoed song already has `.albums`/`.artists` loaded, so
    /// the second tap costs zero round trips. One entry is deliberate — the
    /// player shows exactly one track at a time, so there's never a reason
    /// to remember more than the current one; a new track invalidates it
    /// automatically since its cascade key won't match.
    private var detailedSongMemo: (key: String, song: MusicKit.Song)?

    private func resolveDetailedSong(
        catalogTrackId: String?,
        isrc: String?,
        title: String,
        artist: String
    ) async -> MusicKit.Song? {
        let key = "\(catalogTrackId ?? "")|\(isrc ?? "")|\(title)|\(artist)"
        if let memo = detailedSongMemo, memo.key == key {
            diagLog("resolveDetailedSong('\(title)'): memo hit")
            return memo.song
        }
        let t0 = Date()
        defer { diagLog("resolveDetailedSong('\(title)'): total \(Int(Date().timeIntervalSince(t0) * 1000))ms") }

        // Both `MusicCatalogResourceRequest` branches request the
        // `.albums`/`.artists` relationships as part of the SAME round trip
        // via `properties`, instead of a separate `.with([...])` call after
        // — halves the cost of the two most-hit branches of this cascade
        // (every `resolveAlbum`/`resolveArtists` call — i.e. every
        // `ResolvingAlbumView`/`ResolvingArtistView` open — runs this).
        // `MusicCatalogSearchRequest` (the text-search fallback below) has
        // no `properties` field, so that branch stays two round trips —
        // acceptable since it's only reached when both id and ISRC fail.
        if let id = catalogTrackId, !id.isEmpty {
            var req = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.id, equalTo: MusicItemID(id))
            req.properties = [.albums, .artists]
            if let detailed = try? await req.response().items.first {
                detailedSongMemo = (key, detailed)
                return detailed
            }
        }
        if let isrc, !isrc.isEmpty {
            var req = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.isrc, equalTo: isrc)
            req.properties = [.albums, .artists]
            if let detailed = try? await req.response().items.first {
                detailedSongMemo = (key, detailed)
                return detailed
            }
        }
        guard !title.isEmpty else { return nil }
        var search = MusicCatalogSearchRequest(term: "\(title) \(artist)", types: [MusicKit.Song.self])
        search.limit = 1
        if let song = try? await search.response().songs.first,
           let detailed = try? await song.with([.albums, .artists]) {
            detailedSongMemo = (key, detailed)
            return detailed
        }
        return nil
    }

    // MARK: - MusicKit → NodalongKit conversion

    /// Maps a MusicKit catalog `Song` to our domain `Song`.
    ///
    /// Returns `nil` when the underlying `MusicItemID` is empty — MusicKit
    /// occasionally surfaces records with incomplete identifier sets and
    /// passing those through the rest of the app makes downstream playback
    /// look broken. Callers should `compactMap` over this.
    private static func toSong(
        _ s: MusicKit.Song,
        overrideAlbum: String? = nil,
        overrideArtwork: String? = nil
    ) -> NodalongKit.Song? {
        let id = s.id.rawValue
        guard !id.isEmpty else { return nil }
        let artwork = overrideArtwork?.nonEmpty ?? artworkURL(s.artwork)
        let album   = overrideAlbum?.nonEmpty ?? (s.albumTitle ?? "")
        return NodalongKit.Song(
            id:               id,
            title:            s.title,
            artist:           s.artistName,
            album:            album,
            artwork:          artwork,
            trackId:          id,
            uri:              id,
            sourceService:    .appleMusic,
            isrc:             s.isrc,
            duration:         s.duration.map { Int($0 * 1000) },
            trackNumber:      s.trackNumber,
            albumReleaseDate: s.releaseDate.map { dateFormatter.string(from: $0) },
            isExplicit:       s.contentRating == .explicit
        )
    }

    /// Same contract as `toSong` — returns `nil` for empty-identifier
    /// records so they never enter the rest of the app.
    private static func toArtistResult(_ a: MusicKit.Artist) -> ArtistResult? {
        let id = a.id.rawValue
        guard !id.isEmpty else { return nil }
        return ArtistResult(
            id:            id,
            name:          a.name,
            imageUrl:      artworkURL(a.artwork),
            genres:        (a.genreNames ?? []).joined(separator: ", "),
            followers:     0,
            sourceService: .appleMusic
        )
    }

    /// Same contract as `toSong` — returns `nil` for empty-identifier
    /// records so they never enter the rest of the app.
    private static func toAlbumResult(_ a: MusicKit.Album) -> AlbumResult? {
        let id = a.id.rawValue
        guard !id.isEmpty else { return nil }
        let releaseDate = a.releaseDate.map { dateFormatter.string(from: $0) } ?? ""
        let albumType: String = {
            if a.isSingle == true      { return "single" }
            if a.isCompilation == true { return "compilation" }
            // MusicKit's own `isSingle` flag isn't always set correctly —
            // a "(feat. X)"-titled or "- Single"/"- EP"-suffixed release
            // can come back `isSingle == false`, landing it in the
            // artist's own "Albums" instead of "Discovery" — see
            // `titleIndicatesSingleOrEP`'s own doc comment for why the
            // title itself is a reliable extra signal.
            if titleIndicatesSingleOrEP(a.title) { return "single" }
            return "album"
        }()
        return AlbumResult(
            id:            id,
            name:          a.title,
            artistName:    a.artistName,
            artwork:       artworkURL(a.artwork),
            releaseDate:   releaseDate,
            totalTracks:   a.trackCount,
            albumType:     albumType,
            sourceService: .appleMusic,
            isExplicit:    a.contentRating == .explicit
        )
    }

    /// Same contract as `toSong` — returns `nil` for empty-identifier
    /// records so they never enter the rest of the app.
    private static func toPlaylistResult(_ p: MusicKit.Playlist) -> PlaylistResult? {
        let id = p.id.rawValue
        guard !id.isEmpty else { return nil }
        return PlaylistResult(
            id: id,
            name: p.name,
            curatorName: p.curator?.name ?? "",
            artwork: artworkURL(p.artwork),
            sourceService: .appleMusic
        )
    }

    private static func artworkURL(_ artwork: MusicKit.Artwork?) -> String {
        guard let url = artwork?.url(width: 600, height: 600) else { return "" }
        // Some recently-played/library-matched items resolve to a
        // `musicKit://artwork/library/...` scheme instead of an https mzstatic
        // CDN URL — that's an on-device-only artwork catalog reference that
        // MPArtworkResizeDomain can't serve over plain networking, so every
        // AsyncImage load of it fails immediately. Treat it as "no artwork"
        // at the source rather than persisting a URL that can never load.
        guard url.scheme == "http" || url.scheme == "https" else { return "" }
        return url.absoluteString
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone   = TimeZone(identifier: "UTC")
        return f
    }()
}

// MARK: - Errors

enum AppleMusicServiceError: LocalizedError {
    case trackNotFound
    case notAuthorized(MusicAuthorization.Status)
    case subscriptionRequired

    var errorDescription: String? {
        switch self {
        case .trackNotFound:
            return "Couldn't find this track in Apple Music."
        case .notAuthorized:
            return "Apple Music access is required. Enable it in Settings."
        case .subscriptionRequired:
            return "An Apple Music subscription is required for full playback."
        }
    }
}

// MARK: - Helpers

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

#if DEBUG
extension AppleMusicService {
    /// Authorised-state instance for SwiftUI previews. No network or
    /// MusicKit calls happen — `authStatus` is just toggled to `.authorized`
    /// so views render the post-auth path.
    static var mockPreview: AppleMusicService {
        let svc = AppleMusicService()
        svc.authStatus = .authorized
        return svc
    }
}
#endif
