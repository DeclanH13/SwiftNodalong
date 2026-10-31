import Foundation
import UIKit
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

    // Every dictionary a screen reads at INIT time is mirrored into a
    // lock-protected `Peek` (see `Peek`'s doc comment) via `didSet`, so the
    // mirror can never drift from the actor's own copy — every mutation
    // site, including `ReleaseWatch`'s, goes through the setter. `didSet`
    // does not fire for assignments inside `init`, which is why snapshot
    // restore mirrors them by hand.
    private var albumTracks: [String: [Song]] = [:] { didSet { Self.albumTracksPeek.setAll(albumTracks) } }

    /// Albums whose cached track list is incomplete (some track unplayable) and
    /// when to re-fetch them. A pre-release list was previously served from disk
    /// forever, so a pre-saved album stayed "unreleased" after release day.
    /// See `albumRefreshAfter`.
    struct PendingAlbum: Codable, Sendable, Equatable {
        let id: String
        let name: String
        let artist: String
        let artwork: String
        let releaseDate: String?
        var refreshAfter: Double   // epoch seconds
        /// Re-fetches so far — caps albums with no known date, which would
        /// otherwise be re-checked forever (optional so it decodes from older files).
        var attempts: Int? = nil
    }
    private var albumPending: [String: PendingAlbum] = [:] { didSet { Self.albumPendingPeek.setAll(albumPending) } }
    private var albumInFlight: [String: Task<[Song], Never>] = [:]

    private var artistCore: [String: ArtistCoreDetails] = [:] { didSet { Self.artistCorePeek.setAll(artistCore) } }
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
    private var artistByName: [String: ArtistResult] = [:] { didSet { Self.artistByNamePeek.setAll(artistByName) } }
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
    private var resolvedAlbums: [String: AlbumResult] = [:] { didSet { Self.resolvedAlbumPeek.setAll(resolvedAlbums) } }

    /// `resolveArtists` outcomes keyed by a caller-supplied identity — the
    /// artist twin of `resolvedAlbums`, used by track-anchored taps (the
    /// player, the "…" menu, a party) via `resolvePendingArtists`. Session
    /// only: deliberately not in `Snapshot`, so adding it needs no schema bump.
    private var resolvedArtistsByKey: [String: [ArtistResult]] = [:] { didSet { Self.resolvedArtistsPeek.setAll(resolvedArtistsByKey) } }
    private var resolvedArtistsInFlight: [String: Task<[ArtistResult], Never>] = [:]

    // MARK: - Synchronous peeks

    private static let albumTracksPeek     = Peek<[Song]>()
    private static let albumPendingPeek    = Peek<PendingAlbum>()
    private static let artistCorePeek      = Peek<ArtistCoreDetails>()
    private static let artistByNamePeek    = Peek<ArtistResult>()
    private static let resolvedAlbumPeek   = Peek<AlbumResult>()
    private static let resolvedArtistsPeek = Peek<[ArtistResult]>()

    /// Cached tracks for an album, readable from a view's `init`. Returns nil
    /// for an incomplete (pre-release) list that is due a re-fetch, so the
    /// screen goes through `tracks(albumId:)` and picks up the fresh one.
    nonisolated static func peekAlbumTracks(albumId: String) -> [Song]? {
        guard let songs = albumTracksPeek.get(albumId), !songs.isEmpty else { return nil }
        if let pending = albumPendingPeek.get(albumId), pending.refreshAfter <= Date().timeIntervalSince1970 { return nil }
        return songs
    }
    /// Cached COMPLETE artist core, readable from a view's `init`.
    nonisolated static func peekCoreSync(artistId: String) -> ArtistCoreDetails? { artistCorePeek.get(artistId) }
    nonisolated static func peekArtistByName(_ name: String) -> ArtistResult? { artistByNamePeek.get(name) }
    nonisolated static func peekResolvedAlbum(key: String) -> AlbumResult? { resolvedAlbumPeek.get(key) }
    nonisolated static func peekResolvedArtists(key: String) -> [ArtistResult]? {
        guard let hit = resolvedArtistsPeek.get(key), !hit.isEmpty else { return nil }
        return hit
    }

    private var resolvedAlbumsInFlight: [String: Task<AlbumResult?, Never>] = [:]

    /// Bumped whenever a model persisted in here gains a field whose absence
    /// changes behaviour rather than merely losing detail.
    ///
    /// 🔴 Added after a real failure. `Song` gained `isPlayable`, decoded
    /// tolerantly as `?? true` (correct — assuming an unknown track is
    /// unplayable would dim real music). But this cache had ~300 albums on
    /// disk written before that field existed, so every cached album's tracks
    /// restored as "playable" and the unreleased-track handling silently did
    /// nothing on exactly the albums the user had already opened. A tolerant
    /// default and a versionless disk cache combine into a fix that appears
    /// not to work.
    ///
    /// v3: `artistCore` entries used to hold only a FIRST page of top songs
    /// and albums, which the artist screen topped up afterwards. They now
    /// hold the complete lists, so an older entry would be served forever as
    /// if it were complete.
    private static let schemaVersion = 3

    private struct Snapshot: Codable {
        /// Absent in v1 snapshots, which is precisely how they're detected.
        var schemaVersion:  Int?
        var albumTracks:    [String: [Song]]
        var artistCore:     [String: ArtistCoreDetails]
        var artistExtras:   [String: ArtistExtraDetails]
        var artistByName:   [String: ArtistResult]
        var resolvedAlbums: [String: AlbumResult]
        /// Optional so snapshots written before it existed still load.
        var albumPending:   [String: PendingAlbum]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, albumTracks, artistCore, artistExtras, artistByName, resolvedAlbums, albumPending
        }

        init(albumTracks: [String: [Song]], artistCore: [String: ArtistCoreDetails],
             artistExtras: [String: ArtistExtraDetails], artistByName: [String: ArtistResult],
             resolvedAlbums: [String: AlbumResult], albumPending: [String: PendingAlbum]) {
            self.albumPending = albumPending
            self.schemaVersion = MusicDetailCache.schemaVersion
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
            schemaVersion  = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
            albumTracks    = try c.decode([String: [Song]].self, forKey: .albumTracks)
            artistCore     = try c.decode([String: ArtistCoreDetails].self, forKey: .artistCore)
            artistExtras   = try c.decode([String: ArtistExtraDetails].self, forKey: .artistExtras)
            artistByName   = try c.decode([String: ArtistResult].self, forKey: .artistByName)
            resolvedAlbums = try c.decodeIfPresent([String: AlbumResult].self, forKey: .resolvedAlbums) ?? [:]
            albumPending   = try c.decodeIfPresent([String: PendingAlbum].self, forKey: .albumPending) ?? [:]
        }
    }

    private init() {
        // Don't lose a pending write if iOS suspends or kills the app.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { _ in Task { await MusicDetailCache.shared.flushPending() } }
        if let snap = SnapshotStore.load(Snapshot.self, key: Self.snapshotKey, uid: Self.catalogSnapshotUid) {
            // A snapshot from an older schema is discarded rather than
            // restored: its rows decode "successfully" with defaults for any
            // field added since, which is worse than a cache miss because the
            // defaults are silently wrong. Everything here is re-fetchable
            // catalog data, so throwing it away costs one cold load per album.
            guard snap.schemaVersion == Self.schemaVersion else {
                diagLog("MusicDetailCache: discarding v\(snap.schemaVersion.map(String.init) ?? "1") snapshot (current v\(Self.schemaVersion))")
                return
            }
            albumTracks    = snap.albumTracks
            artistCore     = snap.artistCore
            artistExtras   = snap.artistExtras
            artistByName   = snap.artistByName
            resolvedAlbums = snap.resolvedAlbums
            albumPending   = snap.albumPending
            // Lists cached BEFORE pending-tracking existed (the pre-saved album
            // that prompted it) have unplayable tracks but no entry, so would
            // never expire. Adopt them as due now; the watch re-checks them on
            // the next foreground / Home load and drops the entry once they're
            // fully playable.
            for (id, songs) in albumTracks where albumPending[id] == nil && songs.contains(where: { !$0.isPlayable }) {
                guard let first = songs.first else { continue }
                albumPending[id] = PendingAlbum(
                    id: id, name: first.album, artist: first.artist, artwork: first.artwork,
                    releaseDate: nil, refreshAfter: Date().timeIntervalSince1970, attempts: 0
                )
            }
            // `didSet` doesn't run for assignments made in `init`, so the
            // restored dictionaries are mirrored here by hand.
            Self.albumTracksPeek.setAll(albumTracks)
            Self.albumPendingPeek.setAll(albumPending)
            Self.artistCorePeek.setAll(artistCore)
            Self.artistByNamePeek.setAll(artistByName)
            Self.resolvedAlbumPeek.setAll(resolvedAlbums)
            diagLog("MusicDetailCache: restored \(albumTracks.count) albums, \(artistCore.count) artists from disk")
        }
    }

    /// Coalesced: a prefetch burst fills the cache dozens of times, and each
    /// fill used to re-encode and atomically rewrite the WHOLE ~11 MB snapshot —
    /// ≈1 GB of disk writes in a day (MetricKit disk-write exception). Writes now
    /// happen at most once per `persistDelay`, and `flushPending()` (called when
    /// the app backgrounds) guarantees nothing is lost to a kill.
    private var persistTask: Task<Void, Never>?
    private var persistDirty = false
    private static let persistDelay: UInt64 = 5_000_000_000

    private func persist() {
        persistDirty = true
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.persistDelay)
            guard !Task.isCancelled else { return }
            await self?.flushPending()
        }
    }

    /// Writes immediately if anything changed since the last write.
    func flushPending() {
        persistTask?.cancel()
        persistTask = nil
        guard persistDirty else { return }
        persistDirty = false
        persistNow()
    }

    private func persistNow() {
        func capped<V>(_ dict: [String: V]) -> [String: V] {
            guard dict.count > Self.maxPersistedEntries else { return dict }
            return Dictionary(uniqueKeysWithValues: Array(dict.prefix(Self.maxPersistedEntries)))
        }
        let snap = Snapshot(
            albumTracks:    capped(albumTracks),
            artistCore:     capped(artistCore),
            artistExtras:   capped(artistExtras),
            artistByName:   capped(artistByName),
            resolvedAlbums: capped(resolvedAlbums),
            albumPending:   albumPending
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

    /// `resolvedAlbum`'s artist twin — see `resolvedArtistsByKey`.
    func resolvedArtists(forKey key: String, fetch: @escaping @Sendable () async -> [ArtistResult]) async -> [ArtistResult] {
        if let hit = resolvedArtistsByKey[key], !hit.isEmpty { return hit }
        if let inFlight = resolvedArtistsInFlight[key] { return await inFlight.value }
        let task = Task { await fetch() }
        resolvedArtistsInFlight[key] = task
        let result = await task.value
        resolvedArtistsInFlight[key] = nil
        if !result.isEmpty { resolvedArtistsByKey[key] = result }
        return result
    }

    /// Seeds a resolve result that was obtained elsewhere (the player's own
    /// prefetch), so every entry point sharing `key` sees it.
    func seedResolved(album: AlbumResult?, artists: [ArtistResult], forKey key: String) {
        if let album { resolvedAlbums[key] = album; persist() }
        if !artists.isEmpty { resolvedArtistsByKey[key] = artists }
    }

    /// Returns the cached tracks for `albumId`, or runs `fetch` — shared
    /// across any concurrent callers for the same id (e.g. a
    /// `ResolvingAlbumView` warm-up racing the detail screen's own `.task`).
    ///
    /// **Incomplete lists expire.** If the fetched list has any unplayable track
    /// (an unreleased or partly released album) the album is remembered in
    /// `albumPending` with a `refreshAfter` time — the release date, or hourly
    /// once that has passed — and a hit past that time is treated as a miss. Pass
    /// the album's `releaseDate` (and name/artist/artwork, so `ReleaseWatch` can
    /// re-fetch it without a screen open); all optional so existing callers work.
    func tracks(
        albumId: String,
        releaseDate: String? = nil, name: String = "", artist: String = "", artwork: String = "",
        fetch: @escaping @Sendable () async -> [Song]
    ) async -> [Song] {
        if let hit = albumTracks[albumId] {
            let due = albumPending[albumId].map { $0.refreshAfter <= Date().timeIntervalSince1970 } ?? false
            if !due {
                diagLog("MusicDetailCache.tracks(\(albumId)): cache hit")
                return hit
            }
            diagLog("MusicDetailCache.tracks(\(albumId)): pending album is due — refetching")
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
            let known = albumPending[albumId]
            let attempts = (known?.attempts ?? 0) + (known == nil ? 0 : 1)
            let knownDate = releaseDate ?? known?.releaseDate
            // No date to anchor on and already re-checked a few times: give up.
            let giveUp = knownDate == nil && attempts >= 3
            if !giveUp, let after = albumRefreshAfter(
                releaseDate: knownDate,
                hasUnplayable: result.contains { !$0.isPlayable }
            ) {
                albumPending[albumId] = PendingAlbum(
                    id: albumId,
                    name: name.isEmpty ? (known?.name ?? "") : name,
                    artist: artist.isEmpty ? (known?.artist ?? "") : artist,
                    artwork: artwork.isEmpty ? (known?.artwork ?? "") : artwork,
                    releaseDate: releaseDate ?? known?.releaseDate,
                    refreshAfter: after.timeIntervalSince1970,
                    attempts: attempts
                )
            } else {
                albumPending[albumId] = nil
            }
            persist()
        }
        return result
    }

    // MARK: - Apple playlist tracks (session-only)

    /// Lock-protected mirror so a view can seed its state in `init` without an
    /// actor hop (an `await` here always paints the first frame empty).
    private static let playlistPeek = Peek<[Song]>()
    private var playlistInFlight: [String: Task<[Song], Never>] = [:]

    nonisolated static func peekPlaylistTracks(id: String) -> [Song]? { playlistPeek.get(id) }

    /// Tracks of an Apple Music playlist (a Made For You mix etc.), shared across
    /// concurrent callers like the album/artist caches. Session-only: Apple
    /// updates these playlists, and nothing here is expensive to re-fetch.
    func playlistTracks(id: String, fetch: @escaping @Sendable () async -> [Song]) async -> [Song] {
        if let hit = Self.playlistPeek.get(id) { return hit }
        if let inFlight = playlistInFlight[id] { return await inFlight.value }
        let task = Task { await fetch() }
        playlistInFlight[id] = task
        let result = await task.value
        playlistInFlight[id] = nil
        if !result.isEmpty { Self.playlistPeek.set(id, result) }
        return result
    }

    /// Albums whose incomplete list is now due to be re-fetched.
    func pendingDue(now: Date = Date()) -> [PendingAlbum] {
        albumPending.values.filter { $0.refreshAfter <= now.timeIntervalSince1970 && !$0.name.isEmpty }
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

/// Lock-protected key/value mirror so a view can seed its state in `init`
/// without an actor hop — an `await` always paints the first frame empty,
/// which is the difference between a warm screen and one that flashes a
/// skeleton for a frame and cross-fades out of it.
final class Peek<V: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: V] = [:]
    func get(_ key: String) -> V? { lock.lock(); defer { lock.unlock() }; return store[key] }
    func set(_ key: String, _ value: V) { lock.lock(); store[key] = value; lock.unlock() }
    func setAll(_ all: [String: V]) { lock.lock(); store = all; lock.unlock() }
}
