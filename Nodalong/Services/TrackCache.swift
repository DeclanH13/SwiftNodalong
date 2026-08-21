import Foundation

/// Cache that maps ISRC / title+artist → catalogId. Eliminates redundant
/// Firestore lookups + MusicKit resolves during library sync.
///
/// **Disk-persisted**, mirroring `MusicDetailCache`'s pattern exactly (same
/// `SnapshotStore`, same `_catalog` pseudo-uid — this mapping is genuinely
/// user-independent, so it can and should survive across launches and even
/// a sign-out/sign-in of a different account). Before this, the cache was
/// pure in-memory: on every launch, every one of a user's ~25 recently-
/// played tracks was a guaranteed miss, each paying a full MusicKit catalog
/// search PLUS a Firestore transaction (`upsertCatalogTrack`) to re-derive
/// an id this device had already resolved on a previous run — measured at
/// 3466ms of redone work on a cold launch, entirely avoidable once the
/// mapping itself is remembered.
///
/// **Accepted risk:** a persisted mapping could in principle point at a
/// catalog row later deleted. This is the same risk the in-memory cache
/// already carried within a single session, just extended across launches —
/// the keys (ISRC, title+artist) don't change and `upsertCatalogTrack` is
/// idempotent, so the realistic failure mode is a stale-but-still-valid id,
/// not corruption.
actor TrackCache {
    static let shared = TrackCache()

    private static let catalogSnapshotUid = "_catalog"
    private static let snapshotKey = "trackCache"
    private static let maxPersistedEntries = 1000

    private var byIsrc: [String: String] = [:]
    private var byKey:  [String: String] = [:]

    private struct Snapshot: Codable {
        var byIsrc: [String: String]
        var byKey:  [String: String]
    }

    private init() {
        if let snap = SnapshotStore.load(Snapshot.self, key: Self.snapshotKey, uid: Self.catalogSnapshotUid) {
            byIsrc = snap.byIsrc
            byKey  = snap.byKey
            diagLog("TrackCache: restored \(byIsrc.count) isrc / \(byKey.count) title+artist entries from disk")
        }
    }

    func lookup(isrc: String?, title: String, artist: String) -> String? {
        if let isrc, !isrc.isEmpty, let id = byIsrc[isrc] { return id }
        return byKey[makeKey(title: title, artist: artist)]
    }

    func store(catalogId: String, isrc: String?, title: String, artist: String) {
        if let isrc, !isrc.isEmpty { byIsrc[isrc] = catalogId }
        byKey[makeKey(title: title, artist: artist)] = catalogId
        persist()
    }

    func clear() {
        byIsrc.removeAll()
        byKey.removeAll()
        persist()
    }

    nonisolated func makeKey(title: String, artist: String) -> String {
        "\(title.lowercased())|\(artist.lowercased())"
    }

    /// Fire-and-forget write via `SnapshotStore` (already off-main/detached).
    /// Called on every mutation rather than debounced — mirrors
    /// `MusicDetailCache`'s own accepted simplification; payload sizes here
    /// are small enough in practice that coalescing hasn't been worth the
    /// added complexity.
    private func persist() {
        func capped(_ dict: [String: String]) -> [String: String] {
            guard dict.count > Self.maxPersistedEntries else { return dict }
            return Dictionary(uniqueKeysWithValues: Array(dict.prefix(Self.maxPersistedEntries)))
        }
        let snap = Snapshot(byIsrc: capped(byIsrc), byKey: capped(byKey))
        SnapshotStore.save(snap, key: Self.snapshotKey, uid: Self.catalogSnapshotUid)
    }
}
