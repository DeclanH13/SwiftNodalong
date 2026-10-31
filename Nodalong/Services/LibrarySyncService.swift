import Foundation
import NodalongKit

/// One-shot Apple Music → Firestore library sync.
///
/// Fetches the user's saved + recently-played tracks via `MusicService`,
/// dedupes by `trackId`, ensures each track has a global catalog entry
/// (creating one via ISRC if needed), then writes the recently-played subset
/// to `users/{uid}/recent_tracks/` — that subcollection is what powers Feed
/// and NearMe spotlights.
@MainActor
final class LibrarySyncService: ObservableObject {
    @Published private(set) var isSyncing    = false
    @Published private(set) var lastSyncedAt: Date? = nil

    private var task: Task<Void, Never>? = nil

    /// Caps how many `ingestToCatalogOnly` calls run concurrently. Unbounded
    /// fan-out was self-defeating on a cold cache: per-track
    /// `upsertCatalogTrack` measured climbing from 748ms (first to finish)
    /// to 3089ms (last), i.e. later transactions spent most of their time
    /// simply queued behind earlier ones on the same connection — batching
    /// gets the overlap benefit without every transaction contending at
    /// once. Irrelevant once `TrackCache` is warm (see its own doc comment)
    /// — most launches never reach the network for these at all.
    private static let maxConcurrentIngests = 4

    /// Fire-and-forget sync. Safe to call repeatedly — re-entry is guarded.
    func sync(uid: String, service: AppleMusicService) {
        guard !isSyncing else { return }
        task?.cancel()
        task = Task {
            isSyncing = true
            defer { isSyncing = false }
            await runSync(uid: uid, service: service)
            if !Task.isCancelled { lastSyncedAt = Date() }
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Starts a sync (if not already running) and awaits completion.
    /// Safe to call from a SwiftUI `.refreshable` block.
    func syncAndWait(uid: String, service: AppleMusicService) async {
        if !isSyncing { sync(uid: uid, service: service) }
        await task?.value
    }

    /// Fire-and-forget Spotify sync — parallel to the Apple path above, not a
    /// generalization of it. Kept separate because `ingestToCatalogOnly`
    /// calls the Apple-only `resolveCatalogArtwork` artwork-repair step;
    /// Spotify's own artwork URLs (`images[].url`) are always fetchable
    /// `https` already, so that repair doesn't apply. Shares `isSyncing`/
    /// `task` with the Apple path — only one service is ever "active" at a
    /// time per this app's design, so sequential (not concurrent) syncing is
    /// the correct behavior, not a limitation.
    func syncSpotify(uid: String, service: SpotifyMusicService) {
        guard !isSyncing else { return }
        task?.cancel()
        task = Task {
            isSyncing = true
            defer { isSyncing = false }
            await runSpotifySync(uid: uid, service: service)
            if !Task.isCancelled { lastSyncedAt = Date() }
        }
    }

    /// Starts a Spotify sync (if not already running) and awaits completion.
    func syncSpotifyAndWait(uid: String, service: SpotifyMusicService) async {
        if !isSyncing { syncSpotify(uid: uid, service: service) }
        await task?.value
    }

    // MARK: - Private

    private func runSync(uid: String, service: AppleMusicService) async {
        diagLog("runSync: start")
        // Shelf = tracks the user explicitly saves inside Nodalong.
        // We do NOT import the user's Apple Music library here — that would
        // flood the shelf for every new user. getSavedTracks() is intentionally
        // excluded from this sync path.
        //
        // This sync only handles recent_tracks (powers Feed + Profile recents).
        let fetchStart = Date()
        let recent = (try? await service.getRecentlyPlayed()) ?? []
        diagLog("runSync: getRecentlyPlayed returned \(recent.count) in \(Int(Date().timeIntervalSince(fetchStart) * 1000))ms")
        let validRecent = recent.filter { isValidTrack($0) }
        guard !validRecent.isEmpty else { diagLog("runSync: no valid recent tracks, exiting"); return }

        let cache = TrackCache.shared
        let ingestStart = Date()
        // Was a sequential `for song in validRecent { await ingestToCatalogOnly(...) }`
        // loop — on a fresh install EVERY track is a `TrackCache` miss (it's
        // a fresh in-memory actor with nothing in it yet), so all ~25 recent
        // tracks each pay the full cost: a MusicKit catalog search
        // (`resolveCatalogArtwork`) plus a Firestore TRANSACTION
        // (`upsertCatalogTrack`), one after another. This is the single
        // biggest contributor found to "fresh install, Search tab feels
        // frozen for several seconds" — this sync starts automatically at
        // cold launch (`ContentView.swift`), running well before/during the
        // moment the user reaches Search, and each iteration's dominant
        // cost is network/Firestore round-trip latency, which — unlike raw
        // CPU work — genuinely overlaps when issued concurrently instead of
        // one at a time, even though the individual calls still touch the
        // MainActor briefly (both `AppleMusicService` and this class are
        // `@MainActor`; only the ACTUAL WAITING overlaps, not confirmed to
        // eliminate main-thread contention entirely — see the decisions log
        // entry for the honest caveat on that).
        var recentWithCatalog: [(song: Song, catalogId: String)] = []
        for batch in validRecent.chunked(into: Self.maxConcurrentIngests) {
            let batchResults: [(song: Song, catalogId: String)] = await withTaskGroup(
                of: (Song, String)?.self
            ) { group in
                for song in batch {
                    group.addTask { [weak self] in
                        guard let self, !Task.isCancelled else { return nil }
                        guard let catalogId = await self.ingestToCatalogOnly(song, cache: cache, service: service)
                        else { return nil }
                        return (song, catalogId)
                    }
                }
                var out: [(song: Song, catalogId: String)] = []
                for await pair in group {
                    if let (song, catalogId) = pair { out.append((song: song, catalogId: catalogId)) }
                }
                return out
            }
            recentWithCatalog += batchResults
        }
        diagLog("runSync: batched ingest of \(validRecent.count) tracks done (\(recentWithCatalog.count) ok) in \(Int(Date().timeIntervalSince(ingestStart) * 1000))ms")

        if !recentWithCatalog.isEmpty {
            try? await syncRecentTracks(uid: uid, tracks: recentWithCatalog)
        }
        diagLog("runSync: complete")
    }

    /// Ensures the track exists in the global catalog and returns its catalogId.
    /// Does NOT touch the user's library — shelf saves are driven exclusively
    /// by the explicit heart-button tap in the UI (`LibraryViewModel.toggleLibrary`).
    @discardableResult
    private func ingestToCatalogOnly(_ song: Song, cache: TrackCache, service: AppleMusicService) async -> String? {
        let t0 = Date()
        do {
            if let cached = await cache.lookup(isrc: song.isrc, title: song.title, artist: song.artist) {
                diagLog("ingest '\(song.title)': cache hit, \(Int(Date().timeIntervalSince(t0) * 1000))ms")
                return cached
            }
            // The catalog is the single source of truth for artwork, so make
            // sure it's a fetchable https URL before writing. Library-matched
            // plays arrive with a `musicKit://` reference (filtered to "" by
            // `artworkURL`) or empty art — resolve the real catalog artwork now
            // so no surface ever reads a broken row.
            var artwork = song.artwork
            if !ArtworkURL.isFetchable(artwork) {
                let tArt = Date()
                artwork = await service.resolveCatalogArtwork(
                    appleMusicTrackId: song.trackId, isrc: song.isrc,
                    title: song.title, artist: song.artist, album: song.album
                ) ?? artwork
                diagLog("ingest '\(song.title)': resolveCatalogArtwork \(Int(Date().timeIntervalSince(tArt) * 1000))ms")
            }
            let input = CatalogTrackInput(
                title:             song.title,
                artist:            song.artist,
                album:             song.album,
                artwork:           artwork,
                duration:          song.duration,
                isrc:              song.isrc,
                trackNumber:       song.trackNumber,
                albumReleaseDate:  song.albumReleaseDate,
                genres:            song.genres,
                isExplicit:        song.isExplicit,
                appleMusicUri:     song.uri,
                appleMusicTrackId: song.trackId
            )
            let tUpsert = Date()
            let catalogId = try await upsertCatalogTrack(input)
            diagLog("ingest '\(song.title)': upsertCatalogTrack \(Int(Date().timeIntervalSince(tUpsert) * 1000))ms, total \(Int(Date().timeIntervalSince(t0) * 1000))ms")
            await cache.store(catalogId: catalogId, isrc: song.isrc, title: song.title, artist: song.artist)
            return catalogId
        } catch {
            return nil
        }
    }

    private func runSpotifySync(uid: String, service: SpotifyMusicService) async {
        let recent = (try? await service.getRecentlyPlayed()) ?? []
        let validRecent = recent.filter { isValidTrack($0) }
        guard !validRecent.isEmpty else { return }

        let cache = TrackCache.shared
        var recentWithCatalog: [(song: Song, catalogId: String)] = []
        for batch in validRecent.chunked(into: Self.maxConcurrentIngests) {
            let batchResults: [(song: Song, catalogId: String)] = await withTaskGroup(
                of: (Song, String)?.self
            ) { group in
                for song in batch {
                    group.addTask { [weak self] in
                        guard let self, !Task.isCancelled else { return nil }
                        guard let catalogId = await self.ingestSpotifyToCatalogOnly(song, cache: cache)
                        else { return nil }
                        return (song, catalogId)
                    }
                }
                var out: [(song: Song, catalogId: String)] = []
                for await pair in group {
                    if let (song, catalogId) = pair { out.append((song: song, catalogId: catalogId)) }
                }
                return out
            }
            recentWithCatalog += batchResults
        }

        if !recentWithCatalog.isEmpty {
            try? await syncRecentTracks(uid: uid, tracks: recentWithCatalog)
        }
    }

    /// Same contract as `ingestToCatalogOnly` — ensures a catalog row exists
    /// and returns its id — minus the Apple-only artwork-repair step, which
    /// doesn't apply to Spotify's already-fetchable artwork URLs.
    @discardableResult
    private func ingestSpotifyToCatalogOnly(_ song: Song, cache: TrackCache) async -> String? {
        do {
            if let cached = await cache.lookup(isrc: song.isrc, title: song.title, artist: song.artist) {
                return cached
            }
            let input = CatalogTrackInput(
                title:            song.title,
                artist:           song.artist,
                album:            song.album,
                artwork:          song.artwork,
                duration:         song.duration,
                isrc:             song.isrc,
                trackNumber:      song.trackNumber,
                albumReleaseDate: song.albumReleaseDate,
                genres:           song.genres,
                isExplicit:       song.isExplicit,
                spotifyUri:       song.uri,
                spotifyTrackId:   song.trackId
            )
            let catalogId = try await upsertCatalogTrack(input)
            await cache.store(catalogId: catalogId, isrc: song.isrc, title: song.title, artist: song.artist)
            return catalogId
        } catch {
            return nil
        }
    }
}

private func isValidTrack(_ song: Song) -> Bool {
    !song.title.isEmpty && !song.artist.isEmpty && !song.uri.isEmpty
}
