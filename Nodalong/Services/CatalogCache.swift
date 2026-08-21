import Foundation
import FirebaseFirestore
import NodalongKit

/// Session-scoped cache of catalog metadata, keyed by `catalogId`.
///
/// The `tracks/{catalogId}` catalog is the single source of truth for track
/// metadata (title/artist/album/artwork/…); per-user docs store only a
/// `catalogId` + event data. Every read surface joins to the catalog through
/// this cache, so the same recurring tracks are fetched once per session rather
/// than re-read on every feed refresh / screen revisit.
///
/// Mirrors the `TrackCache` actor pattern, including disk persistence
/// (`SnapshotStore`, same `_catalog` pseudo-uid — this is genuinely
/// user-independent catalog data, same reasoning as `TrackCache`/
/// `MusicDetailCache`). Before persistence, every launch re-fetched every
/// referenced catalog row from scratch — the log that motivated this pass
/// showed 632 + 98 + 30 rows across 22+ batched Firestore queries on a
/// single cold launch (1302ms / 1546ms), all of it identical to what the
/// previous launch already fetched.
///
/// `invalidate(_:)` also persists (unlike `TrackCache`, which never removes
/// entries) so a catalog write can't leave a now-stale row surviving across
/// a relaunch.
actor CatalogCache {
    static let shared = CatalogCache()

    private static let catalogSnapshotUid = "_catalog"
    private static let snapshotKey = "catalogCache"
    private static let maxPersistedEntries = 2000

    private var cache: [String: CatalogTrack] = [:]
    private let tracks = Firestore.firestore().collection("tracks")

    private struct Snapshot: Codable {
        var cache: [String: CatalogTrack]
    }

    private init() {
        if let snap = SnapshotStore.load(Snapshot.self, key: Self.snapshotKey, uid: Self.catalogSnapshotUid) {
            cache = snap.cache
            diagLog("CatalogCache: restored \(cache.count) rows from disk")
        }
    }

    /// Returns catalog metadata for the given ids. Cached ids are served from
    /// memory; misses are fetched in batches of 30 (the Firestore `in`-query
    /// cap), CONCURRENTLY, and cached. Ids with no catalog row simply aren't
    /// in the result — callers keep whatever the event doc already had.
    ///
    /// Batches used to be awaited one at a time in a `for` loop — harmless
    /// for a small library, but for a large one (e.g. a fresh install
    /// syncing an existing account's already-large saved library for the
    /// first time on this device — the exact scenario reported as "search
    /// tab feels frozen for several seconds after a fresh install") that's
    /// N sequential Firestore round trips stacked end to end instead of
    /// running at once.
    func metadata(for ids: [String]) async -> [String: CatalogTrack] {
        let unique = Set(ids.filter { !$0.isEmpty })
        var result: [String: CatalogTrack] = [:]
        var missing: [String] = []
        for id in unique {
            if let hit = cache[id] { result[id] = hit } else { missing.append(id) }
        }
        guard !missing.isEmpty else { return result }
        diagLog("CatalogCache.metadata: \(unique.count) requested, \(missing.count) missing (\(missing.chunked(into: 30).count) batches)")
        let t0 = Date()
        defer { diagLog("CatalogCache.metadata: done in \(Int(Date().timeIntervalSince(t0) * 1000))ms") }

        let collection = tracks
        var fetchedAny = false
        await withTaskGroup(of: [(String, CatalogTrack)].self) { group in
            for chunk in missing.chunked(into: 30) {
                group.addTask {
                    guard let snap = try? await collection
                        .whereField(FieldPath.documentID(), in: chunk)
                        .getDocuments()
                    else { return [] }
                    return snap.documents.compactMap { doc -> (String, CatalogTrack)? in
                        guard let track = try? Firestore.Decoder().decode(CatalogTrack.self, from: doc.data())
                        else { return nil }
                        return (doc.documentID, track)
                    }
                }
            }
            for await pairs in group {
                for (id, track) in pairs {
                    cache[id] = track
                    result[id] = track
                    fetchedAny = true
                }
            }
        }
        if fetchedAny { persist() }
        return result
    }

    /// Drops cached rows so the next read re-fetches them (e.g. after a catalog
    /// write changes metadata). Also persists, so a since-invalidated row
    /// can't survive a relaunch as stale data.
    func invalidate(_ ids: [String]) {
        for id in ids { cache[id] = nil }
        persist()
    }

    func clear() {
        cache.removeAll()
        persist()
    }

    /// Fire-and-forget write via `SnapshotStore` (already off-main/detached).
    /// Called on every mutation rather than debounced — mirrors
    /// `TrackCache`/`MusicDetailCache`'s own accepted simplification.
    private func persist() {
        var capped = cache
        if capped.count > Self.maxPersistedEntries {
            capped = Dictionary(uniqueKeysWithValues: Array(capped.prefix(Self.maxPersistedEntries)))
        }
        SnapshotStore.save(Snapshot(cache: capped), key: Self.snapshotKey, uid: Self.catalogSnapshotUid)
    }
}
