import Foundation
import NodalongKit

/// Albums + top tracks — the primary content of an artist screen. Fetched
/// and cached independently of `ArtistExtraDetails` (see
/// `AppleMusicService.getArtistCore`'s doc comment for why they're split).
struct ArtistCoreDetails: Sendable, Codable {
    let albums: [AlbumResult]
    let topTracks: [Song]
}

/// Similar artists + "features on" albums — secondary content, fetched
/// separately so it never blocks `ArtistCoreDetails` from rendering first.
struct ArtistExtraDetails: Sendable, Codable {
    let similarArtists: [ArtistResult]
    let featuresOn: [AlbumResult]
}

/// Session-scoped cache for the album/artist detail screens (mirrors
/// `CatalogCache`'s actor + in-flight-sharing pattern) — now also
/// disk-persisted, so a previously-viewed artist/album is instant even after
/// force-quitting the app, not just within one session.
///
/// Before this, revisiting an already-open album or artist re-ran the full
/// MusicKit fetch every time — no memory of "I already have this." The
/// fetch itself is injected as a closure so this actor never has to import
/// `MusicKit` (the seam rule in CLAUDE.md §2/§9 keeps MusicKit types inside
/// `AppleMusicService` only).
///
/// Empty results are deliberately NOT cached — a transient failure (network
/// blip, MusicKit hiccup) should retry on the next visit rather than being
/// remembered as "this album/artist has nothing."
///
/// **Persistence.** Catalog data (an artist's albums, an album's tracks) is
/// genuinely user-independent, unlike Home/Feed's per-account snapshots — so
/// this is stored under a fixed pseudo-uid (`catalogSnapshotUid`) rather than
/// the signed-in user's uid, via the same `SnapshotStore` every other
/// snapshot uses. Two consequences, both deliberate: (1) it survives a
/// sign-out/sign-in of a *different* account, since `SnapshotStore.clear`
/// only ever wipes the real uid's own directory and nothing calls it for
/// this pseudo-uid — there's no plausible "last write after clear
/// resurrects stale data" race here the way there would be for a real,
/// clearable uid. (2) It's saved on every successful cache-populating
/// operation (`SnapshotStore.save` is already a cheap, detached, off-main
/// write) rather than debounced — simpler, and the payload stays small
/// enough in practice (see `maxPersistedEntries`) that this hasn't been
/// worth the added complexity of coalescing.
///
/// **Known, accepted limitation:** persisted dictionaries are capped at
/// `maxPersistedEntries` each with a crude "drop the overflow" trim, not a
/// real LRU — the in-memory cache for the CURRENT session is never capped.
/// Good enough for a personal app's realistic browsing volume; revisit with
/// real recency tracking if this cache is ever seen growing unreasonably.
actor MusicDetailCache {
    static let shared = MusicDetailCache()

    private static let catalogSnapshotUid = "_catalog"
    private static let snapshotKey = "musicDetailCache"
    private static let maxPersistedEntries = 300

    private var albumTracks: [String: [Song]] = [:]
    private var albumInFlight: [String: Task<[Song], Never>] = [:]

    private var artistCore: [String: ArtistCoreDetails] = [:]
    private var artistCoreInFlight: [String: Task<ArtistCoreDetails?, Never>] = [:]

    private var artistExtras: [String: ArtistExtraDetails] = [:]
    private var artistExtrasInFlight: [String: Task<ArtistExtraDetails?, Never>] = [:]

    /// Name-keyed (not id-keyed, deliberately a separate identity space from
    /// `artistCore`) — backs the album-header artist-name tap, which only
    /// ever knows a plain display string, not a resolved id. Lets
    /// `AlbumDetailSearchView` speculatively warm this the instant its own
    /// tracks load (the artist name is already known then), so the actual
    /// tap — routed through the identical cache key — is often already a hit
    /// instead of paying the ~260ms `searchAll` fuzzy-lookup cold.
    private var artistByName: [String: ArtistResult] = [:]
    private var artistByNameInFlight: [String: Task<ArtistResult?, Never>] = [:]

    /// Caches a full `AppleMusicService.resolveAlbum` RESULT (not just the
    /// eventual track list this cache already handles via `tracks(albumId:)`)
    /// — keyed by a caller-supplied stable identity, not an id, since the
    /// whole point is caching the outcome of figuring out which real catalog
    /// album a tile even denotes. Lets a browse-time speculative resolve for
    /// a Home rail tile (Jump Back In / Friends Listening — the two surfaces
    /// that only ever start with a display name, never a known catalog
    /// album id) be reused by the real tap instead of re-running the whole
    /// id/ISRC/text-search cascade cold. `resolveAlbum` already awaits its
    /// own track prewarm internally, so a hit here means `tracks(albumId:)`
    /// is warm too.
    private var resolvedAlbums: [String: AlbumResult] = [:]
    private var resolvedAlbumsInFlight: [String: Task<AlbumResult?, Never>] = [:]

    private struct Snapshot: Codable {
        var albumTracks:    [String: [Song]]
        var artistCore:     [String: ArtistCoreDetails]
        var artistExtras:   [String: ArtistExtraDetails]
        var artistByName:   [String: ArtistResult]
        var resolvedAlbums: [String: AlbumResult]

        private enum CodingKeys: String, CodingKey {
            case albumTracks, artistCore, artistExtras, artistByName, resolvedAlbums
        }

        init(albumTracks: [String: [Song]], artistCore: [String: ArtistCoreDetails],
             artistExtras: [String: ArtistExtraDetails], artistByName: [String: ArtistResult],
             resolvedAlbums: [String: AlbumResult]) {
            self.albumTracks = albumTracks
            self.artistCore = artistCore
            self.artistExtras = artistExtras
            self.artistByName = artistByName
            self.resolvedAlbums = resolvedAlbums
        }

        // `resolvedAlbums` is decoded tolerantly (defaulting to empty) — a
        // snapshot persisted before this dict existed has no such key at
        // all, and a synthesized decoder would fail the WHOLE restore over
        // one missing key, silently discarding every already-cached album/
        // artist entry rather than just starting this one dict fresh.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            albumTracks    = try c.decode([String: [Song]].self, forKey: .albumTracks)
            artistCore     = try c.decode([String: ArtistCoreDetails].self, forKey: .artistCore)
            artistExtras   = try c.decode([String: ArtistExtraDetails].self, forKey: .artistExtras)
            artistByName   = try c.decode([String: ArtistResult].self, forKey: .artistByName)
            resolvedAlbums = try c.decodeIfPresent([String: AlbumResult].self, forKey: .resolvedAlbums) ?? [:]
        }
    }

    private init() {
        if let snap = SnapshotStore.load(Snapshot.self, key: Self.snapshotKey, uid: Self.catalogSnapshotUid) {
            albumTracks    = snap.albumTracks
            artistCore     = snap.artistCore
            artistExtras   = snap.artistExtras
            artistByName   = snap.artistByName
            resolvedAlbums = snap.resolvedAlbums
            diagLog("MusicDetailCache: restored \(albumTracks.count) albums, \(artistCore.count) artists from disk")
        }
    }

    private func persist() {
        func capped<V>(_ dict: [String: V]) -> [String: V] {
            guard dict.count > Self.maxPersistedEntries else { return dict }
            return Dictionary(uniqueKeysWithValues: Array(dict.prefix(Self.maxPersistedEntries)))
        }
        let snap = Snapshot(
            albumTracks:    capped(albumTracks),
            artistCore:     capped(artistCore),
            artistExtras:   capped(artistExtras),
            artistByName:   capped(artistByName),
            resolvedAlbums: capped(resolvedAlbums)
        )
        SnapshotStore.save(snap, key: Self.snapshotKey, uid: Self.catalogSnapshotUid)
    }

    func resolveArtistByName(_ name: String, fetch: @escaping @Sendable () async -> ArtistResult?) async -> ArtistResult? {
        if let hit = artistByName[name] {
            diagLog("MusicDetailCache.resolveArtistByName('\(name)'): cache hit")
            return hit
        }
        if let inFlight = artistByNameInFlight[name] {
            diagLog("MusicDetailCache.resolveArtistByName('\(name)'): joined in-flight fetch")
            return await inFlight.value
        }
        let task = Task { await fetch() }
        artistByNameInFlight[name] = task
        let result = await task.value
        artistByNameInFlight[name] = nil
        if let result {
            artistByName[name] = result
            persist()
        }
        return result
    }

    /// Caches a full `resolveAlbum` result under a caller-supplied `key`
    /// (not a real catalog id — see `resolvedAlbums`'s own doc comment).
    /// Shared across concurrent callers for the same key, same shape as
    /// `resolveArtistByName` — e.g. a Home rail's background prefetch racing
    /// the actual tap on the same tile.
    func resolvedAlbum(forKey key: String, fetch: @escaping @Sendable () async -> AlbumResult?) async -> AlbumResult? {
        if let hit = resolvedAlbums[key] {
            diagLog("MusicDetailCache.resolvedAlbum('\(key)'): cache hit")
            return hit
        }
        if let inFlight = resolvedAlbumsInFlight[key] {
            diagLog("MusicDetailCache.resolvedAlbum('\(key)'): joined in-flight fetch")
            return await inFlight.value
        }
        let t0 = Date()
        let task = Task { await fetch() }
        resolvedAlbumsInFlight[key] = task
        let result = await task.value
        diagLog("MusicDetailCache.resolvedAlbum('\(key)'): fetch \(Int(Date().timeIntervalSince(t0) * 1000))ms")
        resolvedAlbumsInFlight[key] = nil
        if let result {
            resolvedAlbums[key] = result
            persist()
        }
        return result
    }

    /// Returns the cached tracks for `albumId`, or runs `fetch` — shared
    /// across any concurrent callers for the same id (e.g. a
    /// `ResolvingAlbumView` warm-up racing the detail screen's own `.task`).
    func tracks(albumId: String, fetch: @escaping @Sendable () async -> [Song]) async -> [Song] {
        if let hit = albumTracks[albumId] {
            diagLog("MusicDetailCache.tracks(\(albumId)): cache hit")
            return hit
        }
        if let inFlight = albumInFlight[albumId] { return await inFlight.value }
        let t0 = Date()
        let task = Task { await fetch() }
        albumInFlight[albumId] = task
        let result = await task.value
        diagLog("MusicDetailCache.tracks(\(albumId)): fetch \(Int(Date().timeIntervalSince(t0) * 1000))ms")
        albumInFlight[albumId] = nil
        if !result.isEmpty {
            albumTracks[albumId] = result
            persist()
        }
        return result
    }

    func core(artistId: String, fetch: @escaping @Sendable () async -> ArtistCoreDetails?) async -> ArtistCoreDetails? {
        if let hit = artistCore[artistId] {
            diagLog("MusicDetailCache.core(\(artistId)): cache hit")
            return hit
        }
        if let inFlight = artistCoreInFlight[artistId] {
            diagLog("MusicDetailCache.core(\(artistId)): joined in-flight fetch")
            return await inFlight.value
        }
        let t0 = Date()
        let task = Task { await fetch() }
        artistCoreInFlight[artistId] = task
        let result = await task.value
        diagLog("MusicDetailCache.core(\(artistId)): fetch \(Int(Date().timeIntervalSince(t0) * 1000))ms")
        artistCoreInFlight[artistId] = nil
        if let result, !(result.albums.isEmpty && result.topTracks.isEmpty) {
            artistCore[artistId] = result
            persist()
        }
        return result
    }

    /// Merges a background top-up of top tracks (first page → up to 30) into
    /// an already-cached artist's core details, so a later revisit gets the
    /// full list too. No-op if this artist was never core-cached — the
    /// top-up simply has nothing to merge into.
    func updateTopTracks(artistId: String, topTracks: [Song]) {
        guard let existing = artistCore[artistId] else { return }
        artistCore[artistId] = ArtistCoreDetails(albums: existing.albums, topTracks: topTracks)
        persist()
    }

    /// Merges a background top-up of the full (paginated) album list into an
    /// already-cached artist's core details — the `albums` counterpart to
    /// `updateTopTracks` above, closing the identical gap `getArtistCore`'s
    /// own `.albums` relationship had (see `getArtistAlbumsFull`'s doc
    /// comment). No-op if this artist was never core-cached.
    func updateAlbums(artistId: String, albums: [AlbumResult]) {
        guard let existing = artistCore[artistId] else { return }
        artistCore[artistId] = ArtistCoreDetails(albums: albums, topTracks: existing.topTracks)
        persist()
    }

    func extras(artistId: String, fetch: @escaping @Sendable () async -> ArtistExtraDetails?) async -> ArtistExtraDetails? {
        if let hit = artistExtras[artistId] { return hit }
        if let inFlight = artistExtrasInFlight[artistId] { return await inFlight.value }
        let task = Task { await fetch() }
        artistExtrasInFlight[artistId] = task
        let result = await task.value
        artistExtrasInFlight[artistId] = nil
        if let result, !(result.similarArtists.isEmpty && result.featuresOn.isEmpty) {
            artistExtras[artistId] = result
            persist()
        }
        return result
    }
}
