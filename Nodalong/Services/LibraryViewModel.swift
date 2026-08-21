import Foundation
import NodalongKit

/// Mirrors the user's saved Nodalong library in memory.
///
/// Holds `tracks` (the LibraryTrackDocs) plus two derived lookup sets
/// (`catalogIds`, `uris`) for O(1) "is this saved?" checks from the UI.
/// `toggleLibrary` writes through to Firestore with optimistic UI + rollback
/// on failure, so the heart icon flips instantly.
///
/// Reads: Firestore `users/{uid}/library/{catalogId}`.
/// Drives: Shelf tab, TrackCard like-button state across the app.
@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var tracks:    [LibraryTrackDoc] = [] {
        didSet { recomputeDerived() }
    }

    // MARK: - Derived views of the library
    //
    // Computed ONCE per library change, here, rather than inside a view body.
    // `groupByAlbum`/`groupByArtist` normalise every track's album and artist
    // strings (regex + ICU case-insensitive searches), which measured 13.5 ms
    // for a 441-track library — most of a 16.7 ms frame budget. They were
    // previously invoked from `HomeView.recentShelfAlbums` and
    // `ShelfViewModel.albums`/`.artists`, both uncached computed properties,
    // so they re-ran on EVERY re-render of those screens — and `HomeView`
    // observes nine app-wide objects, so almost anything could trigger it.
    // That was the scroll stutter.
    //
    // A `didSet` on `tracks` is deliberate over recomputing at each call
    // site: `tracks` is mutated in five places (load + four remove paths),
    // and this way none of them can forget.

    /// The library grouped into albums — backs Shelf's Albums grid.
    @Published private(set) var albumGroups: [AlbumGroup] = []

    /// The library grouped by primary artist — backs Shelf's Artists list.
    @Published private(set) var artistEntries: [ArtistEntry] = []

    /// Flat song list, most-recently-saved first — backs Shelf's "Liked".
    @Published private(set) var recentlyLiked: [LibraryTrackDoc] = []

    /// The 10 most-recently-added albums — backs Home's "Recently Added".
    /// Sorted by each group's newest `savedAt`, computed with a single pass
    /// per group; the previous version recomputed `.map(\.savedAt).max()`
    /// (two array allocations) on both sides of every sort comparison.
    @Published private(set) var recentAlbumGroups: [AlbumGroup] = []

    private func recomputeDerived() {
        albumGroups   = groupByAlbum(tracks)
        artistEntries = groupByArtist(tracks)
        recentlyLiked = tracks.sorted { $0.savedAt > $1.savedAt }
        recentAlbumGroups = albumGroups
            .map { (group: $0, savedAt: $0.tracks.reduce(0.0) { Swift.max($0, $1.savedAt) }) }
            .sorted { $0.savedAt > $1.savedAt }
            .prefix(10)
            .map(\.group)
    }

    @Published private(set) var catalogIds: Set<String>      = []
    @Published private(set) var uris:       Set<String>      = []
    @Published private(set) var isLoading = false

    /// UID for which data is currently loaded. Prevents redundant Firestore
    /// reads when `.task` fires again on tab re-visit within the same session.
    private var loadedForUid: String? = nil

    /// Loads the library for `uid`. Skips the fetch if data for this UID is
    /// already loaded — call `reload(uid:)` to force a refresh.
    /// Two-phase by design.
    ///
    /// **Phase 1 (blocking, one round trip)** loads the raw library docs and
    /// publishes `catalogIds` — which is all every heart icon in the app
    /// actually needs, since `isInLibrary` prefers `catalogId`. Eleven of the
    /// thirteen consumers of this view model never read `tracks` at all.
    ///
    /// **Phase 2 (background, ~13 round trips)** joins the catalog for display
    /// metadata. Only Shelf and Home's "Recently Added" need it, and both
    /// update reactively when it lands. On device this half measured 2450ms
    /// for a 441-track library and used to block Home, Feed *and* Search.
    func load(uid: String) async {
        guard !isLoading, loadedForUid != uid else { return }
        isLoading = true
        diagLog("LibraryViewModel.load: start")
        let t0 = Date()

        let raw = (try? await getLibraryTracksRaw(uid: uid)) ?? []
        diagLog("LibraryViewModel.load: PHASE 1 raw \(raw.count) docs in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
        tracks       = raw
        catalogIds   = Set(raw.map { $0.catalogId })
        loadedForUid = uid
        isLoading    = false

        // `uris` is the fallback matcher for search results (which carry no
        // catalogId of their own), and it only exists after enrichment —
        // slim library docs don't store `uri`. So those specific hearts fill
        // in when this lands rather than being wrong permanently; everything
        // matching by catalogId is already correct above.
        Task { [weak self] in
            let enrichStart = Date()
            let enriched = await enrichLibrary(raw)
            guard let self, self.loadedForUid == uid else { return }
            self.tracks = enriched
            self.uris   = Set(enriched.map { $0.uri }.filter { !$0.isEmpty })
            diagLog("LibraryViewModel.load: PHASE 2 enrich in \(Int(Date().timeIntervalSince(enrichStart) * 1000))ms")
        }
    }

    /// Force-reloads from Firestore — used after a shelf toggle to keep the
    /// in-memory state in sync. Does not block on `isLoading`.
    func reload(uid: String) async {
        loadedForUid = nil
        await load(uid: uid)
    }

    /// Saves all `tracks` from an album that aren't already in the library.
    ///
    /// Uses a single Firestore `WriteBatch` so the whole album lands in one
    /// network round-trip. Optimistic: in-memory state is updated before the
    /// write and rolled back on error.
    func saveAlbum(uid: String, tracks: [LibraryTrackDoc]) async {
        // Ensure a shared-catalog row exists for each track and re-key it by the
        // canonical catalogId (concurrently). Tracks that fail to resolve are
        // dropped rather than saved as broken "Singles" entries.
        let canonical: [LibraryTrackDoc] = await withTaskGroup(of: LibraryTrackDoc?.self) { group in
            for t in tracks {
                group.addTask {
                    guard let id = try? await ensureCatalogId(forLibrary: t), !id.isEmpty else { return nil }
                    return t.withCatalogId(id)
                }
            }
            var out: [LibraryTrackDoc] = []
            for await doc in group { if let doc { out.append(doc) } }
            return out
        }

        // Skip anything already in the library (by canonical id or uri).
        let newTracks = canonical.filter { !catalogIds.contains($0.catalogId) && !uris.contains($0.uri) }
        guard !newTracks.isEmpty else { return }

        // Optimistic update
        for t in newTracks {
            catalogIds.insert(t.catalogId)
            uris.insert(t.uri)
            self.tracks.insert(t, at: 0)
        }
        do {
            try await batchUpsertLibraryTracks(uid: uid, docs: newTracks)
            // Drop any cached copies of the rows we just saved, unconditionally.
            //
            // `CatalogCache` is disk-persisted and never refreshes a row it
            // already holds, so a copy cached back when the row was wrong
            // keeps being served on every cold launch even after Firestore
            // has been corrected — the confirmed cause of a saved EP track
            // splitting back out into its own Shelf tile on reopen. Doing
            // this on EVERY save (not only when a repair fires) is what
            // actually heals an already-stale entry: by the time the row is
            // correct there is nothing left to repair, so a repair-triggered
            // invalidation alone would never run.
            await CatalogCache.shared.invalidate(canonical.map(\.catalogId))
            reconcileAlbumContextInCatalog(tracks)
        } catch {
            // Rollback
            for t in newTracks {
                catalogIds.remove(t.catalogId)
                uris.remove(t.uri)
                self.tracks.removeAll { $0.catalogId == t.catalogId }
            }
        }
    }

    /// Best-effort, fire-and-forget correction of each saved track's shared
    /// catalog row, using the album context this save actually had.
    ///
    /// Why this is needed at all: a library doc stores only `catalogId` /
    /// `savedAt` / `sourceService` — the album name is overlaid on read from
    /// the shared `tracks` catalog, which is keyed by **ISRC**. A recording
    /// released both as a standalone single and on an album/EP therefore
    /// shares ONE catalog row, and whichever release was ingested first owns
    /// its album name. Save the EP after having played the single and the
    /// track keeps the single's album name, which strands it outside its
    /// album in Shelf (`groupByAlbum` keys on album name) — reported as
    /// "3 of 4 tracks saved to the EP, the 4th became its own single".
    ///
    /// `ensureCatalogId(forLibrary:)` can't do this itself: it deliberately
    /// short-circuits on a known `catalogId` or a `TrackCache` hit, so
    /// `upsertCatalogTrack` — and with it the `isBetterRelease` repair branch
    /// — never runs for an already-known track.
    ///
    /// Deliberately NOT awaited: `saveAlbum` was optimised so the Save button
    /// flips without waiting on a per-track Firestore transaction, and
    /// nothing user-visible depends on this completing. Failures are ignored;
    /// the repair is idempotent and one-directional, so a later save just
    /// tries again.
    private func reconcileAlbumContextInCatalog(_ tracks: [LibraryTrackDoc]) {
        // Only worth doing when there IS real album context to assert.
        let withAlbum = tracks.filter { !$0.album.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !withAlbum.isEmpty else { return }
        Task.detached(priority: .utility) {
            for t in withAlbum {
                _ = try? await upsertCatalogTrack(CatalogTrackInput(
                    title:             t.title,
                    artist:            t.artist,
                    album:             t.album,
                    artwork:           t.artwork,
                    duration:          t.duration,
                    isrc:              t.isrc,
                    trackNumber:       t.trackNumber,
                    albumReleaseDate:  t.albumReleaseDate,
                    appleMusicUri:     t.uri,
                    appleMusicTrackId: t.uri
                ))
            }
        }
    }

    /// Removes an album's tracks from the library.
    ///
    /// Takes the (possibly un-canonicalized) docs shown in the album view and
    /// resolves each to its stored library doc by catalogId **or** uri, so the
    /// correct stored canonical ids are removed even when the incoming docs
    /// carry an empty catalogId (search-sourced). One `WriteBatch`; optimistic
    /// with rollback on error.
    func removeAlbum(uid: String, tracks toRemove: [LibraryTrackDoc]) async {
        let existing = Array(Set(toRemove.compactMap { incoming in
            tracks.first {
                (!incoming.catalogId.isEmpty && $0.catalogId == incoming.catalogId) ||
                (!incoming.uri.isEmpty && $0.uri == incoming.uri)
            }?.catalogId
        }))
        guard !existing.isEmpty else { return }

        // Optimistic update
        for id in existing {
            catalogIds.remove(id)
            tracks.removeAll { $0.catalogId == id }
        }
        // Purge URIs for removed tracks
        uris = Set(tracks.map { $0.uri })

        do {
            try await batchRemoveLibraryTracks(uid: uid, catalogIds: existing)
        } catch {
            // Rollback — reload from Firestore to get back to a consistent state
            loadedForUid = nil
            await load(uid: uid)
        }
    }

    func isInLibrary(catalogId: String?, uri: String?) -> Bool {
        if let id = catalogId, !id.isEmpty { return catalogIds.contains(id) }
        if let u  = uri,       !u.isEmpty  { return uris.contains(u) }
        return false
    }

    #if DEBUG
    fileprivate func applyMockPreviewState(tracks: [LibraryTrackDoc]) {
        self.tracks     = tracks
        self.catalogIds = Set(tracks.map { $0.catalogId })
        self.uris       = Set(tracks.map { $0.uri })
    }
    #endif

    /// Optimistically toggles save state and writes to Firestore.
    ///
    /// On save, first ensures a shared-catalog row exists and keys the stored
    /// doc by the returned **canonical** catalogId (`ensureCatalogId(forLibrary:)`)
    /// — this is the fix for tracks saved from Search/Album showing up as
    /// "Singles / Unknown Artist" because their catalog row was never created.
    /// Membership is matched by catalogId OR uri, since a search track arrives
    /// with an empty catalogId until it's canonicalized here.
    func toggleLibrary(uid: String, track: LibraryTrackDoc) async {
        // Already saved? Match on the stored canonical id or the uri.
        let existing = tracks.first {
            (!track.catalogId.isEmpty && $0.catalogId == track.catalogId) ||
            (!track.uri.isEmpty && $0.uri == track.uri)
        }

        if let existing {
            // Remove by the stored canonical id.
            let id = existing.catalogId
            catalogIds.remove(id)
            uris.remove(existing.uri)
            tracks.removeAll { $0.catalogId == id }
            do {
                try await removeLibraryTrack(uid: uid, catalogId: id)
            } catch {
                catalogIds.insert(id)
                uris.insert(existing.uri)
                tracks.insert(existing, at: 0)
            }
            return
        }

        // Add: resolve the canonical catalogId (ensuring the catalog row) before
        // writing, so read-time enrichment can overlay real metadata.
        guard let canonicalId = try? await ensureCatalogId(forLibrary: track),
              !canonicalId.isEmpty else { return }
        let canonical = track.withCatalogId(canonicalId)

        catalogIds.insert(canonicalId)
        uris.insert(canonical.uri)
        tracks.insert(canonical, at: 0)
        do {
            try await upsertLibraryTrack(uid: uid, catalogId: canonicalId, doc: canonical)
        } catch {
            catalogIds.remove(canonicalId)
            uris.remove(canonical.uri)
            tracks.removeAll { $0.catalogId == canonicalId }
        }
    }
}

#if DEBUG
extension LibraryViewModel {
    /// Library VM pre-populated with fixture tracks for previews.
    static var mockPreview: LibraryViewModel {
        let vm = LibraryViewModel()
        vm.applyMockPreviewState(tracks: PreviewFixtures.libraryTracks)
        return vm
    }
}
#endif
