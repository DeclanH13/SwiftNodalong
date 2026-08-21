import FirebaseFirestore
import NodalongKit

private func libraryCollection(uid: String) -> CollectionReference {
    Firestore.firestore().collection("users").document(uid).collection("library")
}

/// Raw library docs with **no** catalog enrichment — a single Firestore round
/// trip.
///
/// The stored doc carries `catalogId`/`savedAt`/`sourceService`, which is
/// everything shelf-membership checks need. Display metadata (title, artist,
/// artwork) lives in the catalog and requires `enrichLibrary`, which costs one
/// batched query per 30 tracks — 13 extra round trips and ~2.4s for a
/// 441-track library, measured on device. `LibraryViewModel.load` deliberately
/// splits those two phases so the blocking half stays a single request.
func getLibraryTracksRaw(uid: String) async throws -> [LibraryTrackDoc] {
    let snap = try await libraryCollection(uid: uid).getDocuments()
    return snap.documents.compactMap { doc in
        try? Firestore.Decoder().decode(LibraryTrackDoc.self, from: doc.data())
    }
}

func getLibraryTracks(uid: String) async throws -> [LibraryTrackDoc] {
    await enrichLibrary(try await getLibraryTracksRaw(uid: uid))
}

/// Overlays catalog metadata (incl. album-sort fields) onto library docs built
/// from slim event docs. The catalog is the single source of truth; joins
/// through `CatalogCache`.
func enrichLibrary(_ docs: [LibraryTrackDoc]) async -> [LibraryTrackDoc] {
    let ids = docs.map(\.catalogId).filter { !$0.isEmpty }
    guard !ids.isEmpty else { return docs }
    let meta = await CatalogCache.shared.metadata(for: ids)
    let merged = docs.map { $0.merged(withCatalog: meta[$0.catalogId]) }

    // Permanent, low-noise health signal for the split-album bug class.
    //
    // Flags only rows whose album name — AFTER the catalog overlay —
    // describes the track's own single release rather than a real album.
    // Those are exactly the tracks `groupByAlbum` strands into their own
    // Shelf tile, so a rising count here is the earliest warning that
    // catalog rows are drifting again. This is how the Salt of the Lee bug
    // was finally caught: the same catalogId read as "Salt of the Lee - EP"
    // at save time and "Dungarvan Bay - Single" on the next cold load,
    // which pinned it on a stale `CatalogCache` entry rather than a bad
    // write. Capped at 5 examples so a large library can't flood the log.
    let suspect = merged.filter { isSingleLikeAlbum(album: $0.album, trackTitle: $0.title) }
    if !suspect.isEmpty {
        diagLog("[Nodalong.Enrich] \(suspect.count)/\(merged.count) tracks carry a single-like album after catalog overlay")
        for t in suspect.prefix(5) {
            diagLog("[Nodalong.Enrich]   e.g. title='\(t.title)' album='\(t.album)' catalogId='\(t.catalogId)'")
        }
    }
    return merged
}

/// Guarantees a shared-catalog row exists for a track being saved, returning
/// the **canonical** catalogId to key the slim library doc by.
///
/// This is the step the Shelf save path used to skip — which left library docs
/// keyed by an Apple Music id with no `tracks/{id}` row, so read-time
/// enrichment came back empty and tracks collapsed into the "Singles / Unknown
/// Artist" bucket. Mirrors the recents-sync (`ingestToCatalogOnly`) and
/// Playlists (`ensureCatalogId(for:)`) paths.
///
/// A non-empty `catalogId` is trusted (it's a real Nodalong id sourced from a
/// Post/Song that already has a catalog row); otherwise the catalog is upserted
/// from the doc's own metadata — which is fully populated at save time (the doc
/// is built from a search/album result, before it gets slimmed for storage).
func ensureCatalogId(forLibrary doc: LibraryTrackDoc) async throws -> String {
    if !doc.catalogId.isEmpty { return doc.catalogId }
    // Same `TrackCache` (isrc/title+artist → catalogId) `ensureCatalogId(for
    // song:)` uses — a real Firestore transaction (`upsertCatalogTrack`) per
    // unresolved track was the cause of a noticeable delay between tapping
    // "Save Album" and the button actually flipping, since every track in
    // the album had to resolve before the optimistic UI update could run.
    // `AppleMusicService.resolveAlbum` now prewarms this cache for the whole
    // album while its own loading screen is up (see its doc comment), so by
    // the time the user taps Save, this is normally already a cache hit.
    if let cached = await TrackCache.shared.lookup(isrc: doc.isrc, title: doc.title, artist: doc.artist) {
        return cached
    }
    let catalogId = try await upsertCatalogTrack(CatalogTrackInput(
        title:             doc.title,
        artist:            doc.artist,
        album:             doc.album,
        artwork:           doc.artwork,
        duration:          doc.duration,
        isrc:              doc.isrc,
        trackNumber:       doc.trackNumber,
        albumReleaseDate:  doc.albumReleaseDate,
        appleMusicUri:     doc.uri,
        appleMusicTrackId: doc.uri
    ))
    await TrackCache.shared.store(catalogId: catalogId, isrc: doc.isrc, title: doc.title, artist: doc.artist)
    return catalogId
}

/// Slim library event doc — metadata lives in the catalog (single source of
/// truth) and is overlaid on read. Store only catalogId + event data.
private func slimLibraryData(_ doc: LibraryTrackDoc) -> [String: Any] {
    [
        "catalogId":     doc.catalogId,
        "savedAt":       doc.savedAt,
        "sourceService": doc.sourceService.rawValue,
    ]
}

func upsertLibraryTrack(uid: String, catalogId: String, doc: LibraryTrackDoc) async throws {
    try await libraryCollection(uid: uid).document(catalogId)
        .setData(slimLibraryData(doc), merge: true)
}

func removeLibraryTrack(uid: String, catalogId: String) async throws {
    try await libraryCollection(uid: uid).document(catalogId).delete()
}

/// Writes all `docs` in a single Firestore `WriteBatch` — one round-trip
/// regardless of album size. Idempotent: existing tracks are overwritten
/// with `merge: true`.
func batchUpsertLibraryTracks(uid: String, docs: [LibraryTrackDoc]) async throws {
    guard !docs.isEmpty else { return }
    let db  = Firestore.firestore()
    let col = libraryCollection(uid: uid)
    let batch = db.batch()
    for doc in docs {
        batch.setData(slimLibraryData(doc), forDocument: col.document(doc.catalogId), merge: true)
    }
    try await batch.commit()
}

/// Deletes all specified catalogIds in a single Firestore `WriteBatch`.
func batchRemoveLibraryTracks(uid: String, catalogIds: [String]) async throws {
    guard !catalogIds.isEmpty else { return }
    let db  = Firestore.firestore()
    let col = libraryCollection(uid: uid)
    let batch = db.batch()
    for id in catalogIds {
        batch.deleteDocument(col.document(id))
    }
    try await batch.commit()
}
