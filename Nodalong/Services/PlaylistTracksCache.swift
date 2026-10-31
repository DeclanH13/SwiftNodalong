import Foundation
import NodalongKit

/// Track lists for the user's own playlists, kept in memory AND on disk so
/// opening one shows its tracks on the very first frame instead of a spinner.
///
/// **Freshness.** A generated playlist only ever changes through
/// `upsertGeneratedPlaylist`, which bumps `updatedAt` and `trackCount` in the
/// same step — so `(updatedAt, trackCount)` is an exact version key and an
/// entry that matches needs no network at all. Editable playlists (manual,
/// party) are shown from cache but always revalidated, because their track
/// edits don't reliably move `updatedAt`.
///
/// Reads are synchronous and lock-protected (`entry(for:)`) so a view can seed
/// its state in `init`; an actor hop would paint the first frame empty.
/// Only the signed-in user's own playlists are stored.
enum PlaylistTracksCache {
    struct Entry: Codable, Sendable {
        var updatedAt: Double
        var trackCount: Int
        /// Firestore doc ids, parallel to `tracks`. `PlaylistTrack.id` is not part
        /// of its Codable payload, so without this every restored track had an
        /// empty id and SwiftUI collapsed the list into one repeated row.
        var ids: [String]
        var tracks: [PlaylistTrack]

        /// Tracks with ids restored, or nil if the entry is malformed.
        var restored: [PlaylistTrack]? {
            guard ids.count == tracks.count, !ids.contains(""), Set(ids).count == ids.count else { return nil }
            return zip(ids, tracks).map { id, track in var t = track; t.id = id; return t }
        }
    }

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var uid: String?
        var entries: [String: Entry] = [:]
        /// Other people's playlists, opened or prefetched this session.
        /// Memory only — never written to disk, and not version-checked on
        /// read beyond what `sessionTracks(for:)` does.
        var sessionEntries: [String: Entry] = [:]
        /// Playlists a prefetch has already been attempted for this session,
        /// hit or miss — so a rail re-appearing never re-reads Firestore.
        var attempted: Set<String> = []
    }
    private static let box = Box()
    private static let key = "playlistTracks2"

    /// Loads this account's entries from disk. Call once after sign-in.
    static func configure(uid: String) {
        let loaded = SnapshotStore.load([String: Entry].self, key: key, uid: uid) ?? [:]
        box.lock.lock(); box.uid = uid; box.entries = loaded; box.lock.unlock()
    }

    static func reset() {
        box.lock.lock()
        box.uid = nil; box.entries = [:]; box.sessionEntries = [:]; box.attempted = []
        box.lock.unlock()
    }

    /// Someone else's playlist, if it was fetched this session for exactly
    /// this version. Unlike your own, it is never shown stale: you can't
    /// see them edit it, so an out-of-date list would just be wrong.
    nonisolated static func sessionTracks(for playlist: Playlist) -> [PlaylistTrack]? {
        box.lock.lock(); defer { box.lock.unlock() }
        guard let e = box.sessionEntries[playlist.id],
              e.updatedAt == playlist.updatedAt, e.trackCount == playlist.trackCount else { return nil }
        return e.restored
    }

    static func storeSession(_ tracks: [PlaylistTrack], for playlist: Playlist) {
        box.lock.lock()
        box.sessionEntries[playlist.id] = Entry(updatedAt: playlist.updatedAt, trackCount: playlist.trackCount,
                                                ids: tracks.map(\.id), tracks: tracks)
        box.lock.unlock()
    }

    /// Warms the track lists of playlist tiles that are on screen, so tapping
    /// one opens on its tracks. Unlike Apple Music data this costs billed
    /// Firestore reads (each track doc, plus the catalog join), so it is
    /// bounded three ways: only the first `limit` playlists, each at most
    /// once per session, and nothing already cached for its current version.
    /// Your own playlists go to the persisted entries (where
    /// `PlaylistDetailView` already looks); anyone else's to the session map.
    static func prefetch(_ playlists: [Playlist], viewerUid: String?, limit: Int = 6) async {
        let candidates = playlists.prefix(limit).filter { p in
            let owned = p.ownerUid == viewerUid
            if owned ? entry(for: p.id) != nil : sessionTracks(for: p) != nil { return false }
            box.lock.lock(); defer { box.lock.unlock() }
            return box.attempted.insert(p.id).inserted
        }
        guard !candidates.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for playlist in candidates {
                group.addTask {
                    guard let tracks = try? await getPlaylistTracks(playlistId: playlist.id) else { return }
                    if playlist.ownerUid == viewerUid { store(tracks, for: playlist) }
                    else { storeSession(tracks, for: playlist) }
                }
            }
        }
    }

    /// Whatever is stored for this playlist, fresh or not.
    nonisolated static func entry(for playlistId: String) -> Entry? {
        box.lock.lock(); defer { box.lock.unlock() }
        guard let e = box.entries[playlistId], e.restored != nil else { return nil }
        return e
    }

    /// The stored tracks only if they were built for exactly this version.
    nonisolated static func freshTracks(for playlist: Playlist) -> [PlaylistTrack]? {
        guard let e = entry(for: playlist.id),
              e.updatedAt == playlist.updatedAt, e.trackCount == playlist.trackCount else { return nil }
        return e.restored
    }

    static func store(_ tracks: [PlaylistTrack], for playlist: Playlist) {
        mutate { $0[playlist.id] = Entry(updatedAt: playlist.updatedAt, trackCount: playlist.trackCount, ids: tracks.map(\.id), tracks: tracks) }
    }

    static func invalidate(_ playlistId: String) {
        mutate { $0[playlistId] = nil }
    }

    private static func mutate(_ change: (inout [String: Entry]) -> Void) {
        box.lock.lock()
        change(&box.entries)
        let snapshot = box.entries
        let uid = box.uid
        box.lock.unlock()
        if let uid { SnapshotStore.save(snapshot, key: key, uid: uid) }
    }

    /// Fetches tracks for any generated playlist whose stored version is out of
    /// date (a rebuild, or a fresh install), a few at a time, and drops entries
    /// for playlists that no longer exist. On most launches nothing is stale, so
    /// this costs no reads.
    static func warm(_ playlists: [Playlist]) async {
        let ids = Set(playlists.map(\.id))
        mutate { entries in for id in entries.keys where !ids.contains(id) { entries[id] = nil } }

        let stale = playlists.filter { $0.source == .generated && freshTracks(for: $0) == nil }
        for chunk in stale.chunked(into: 3) {
            guard !Task.isCancelled else { return }
            await withTaskGroup(of: Void.self) { group in
                for playlist in chunk {
                    group.addTask {
                        guard let tracks = try? await getPlaylistTracks(playlistId: playlist.id) else { return }
                        store(tracks, for: playlist)
                    }
                }
            }
        }
    }
}
