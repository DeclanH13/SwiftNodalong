import FirebaseFirestore
import NodalongKit

private let tracksCollection    = Firestore.firestore().collection("tracks")
/// Deterministic secondary index `{sanitizedIsrc}` → `{catalogId}`. Exists
/// solely so `upsertCatalogTrack` can dedupe by ISRC via a Firestore
/// *transaction* — transactions can only read/write known document
/// references, not arbitrary queries, so the `whereField("isrc",...)` lookup
/// itself can't be made transactional. Keying this index doc by ISRC gives a
/// transactable reference to race on instead.
private let isrcIndexCollection = Firestore.firestore().collection("isrc_index")

/// Loads a single catalog document by id.
func getCatalogTrack(catalogId: String) async throws -> CatalogTrack? {
    let doc = try await tracksCollection.document(catalogId).getDocument()
    guard doc.exists, let data = doc.data() else { return nil }
    return try Firestore.Decoder().decode(CatalogTrack.self, from: data)
}

/// Firestore document IDs must be non-empty and can't contain `/`; ISRCs are
/// normally already alphanumeric, but this strips anything else defensively.
private func sanitizedIsrcKey(_ isrc: String) -> String {
    isrc.uppercased().filter { $0.isLetter || $0.isNumber }
}

/// Finds an existing catalog entry by ISRC (merging whichever service
/// identifiers `input` carries onto it — Apple, Spotify, or both) or creates a
/// new one. Only backfills a service's fields if that row doesn't already have
/// them, so a track independently surfaced by both an Apple Music and a
/// Spotify user ends up as ONE row carrying both services' ids. Returns the
/// catalogId.
///
/// The "first insert wins" step is a Firestore transaction keyed on
/// `isrc_index/{sanitizedIsrc}` — closes a real race (confirmed still-unfixed
/// in the sibling RN app's equivalent code) where two concurrent callers for
/// the same brand-new ISRC could both miss a plain query-based lookup and
/// both insert, orphaning a duplicate catalog row. Firestore retries a
/// transaction automatically on contention, so the loser of the race simply
/// observes the winner's index doc on retry and returns the same catalogId
/// instead of creating a second one.
///
/// This is the canonical "ensure track exists" hook used by
/// `LibrarySyncService` and the play-time enrichment path.
func upsertCatalogTrack(_ input: CatalogTrackInput) async throws -> String {
    let now = Date().timeIntervalSince1970 * 1000

    guard let isrc = input.isrc, !isrc.isEmpty else {
        // No ISRC to dedupe on — nothing to race, just create a fresh row.
        return try await createCatalogRow(input, now: now)
    }

    let indexRef  = isrcIndexCollection.document(sanitizedIsrcKey(isrc))
    let newDocRef = tracksCollection.document()

    // `runTransaction`'s block returns `Any?` (bridged from Objective-C `id`),
    // not a generic type, so the result needs an explicit cast back to String.
    let rawResult = try await Firestore.firestore().runTransaction { transaction, errorPointer -> Any? in
        do {
            let indexSnap = try transaction.getDocument(indexRef)
            if let existingId = indexSnap.data()?["catalogId"] as? String, !existingId.isEmpty {
                return existingId
            }
            // First writer for this ISRC — create the catalog row and its
            // index entry atomically, in the same transaction.
            let track = CatalogTrack(
                title: input.title, artist: input.artist, album: input.album, artwork: input.artwork,
                duration: input.duration, isrc: input.isrc, trackNumber: input.trackNumber,
                albumReleaseDate: input.albumReleaseDate,
                appleMusicUri: input.appleMusicUri, appleMusicTrackId: input.appleMusicTrackId,
                spotifyUri: input.spotifyUri, spotifyTrackId: input.spotifyTrackId,
                createdAt: now, updatedAt: now
            )
            let data = try Firestore.Encoder().encode(track)
            transaction.setData(data, forDocument: newDocRef)
            transaction.setData(["catalogId": newDocRef.documentID], forDocument: indexRef)
            return newDocRef.documentID
        } catch {
            errorPointer?.pointee = error as NSError
            return nil
        }
    }

    guard let catalogId = rawResult as? String else {
        throw NSError(domain: "Nodalong.Catalog", code: -1,
                       userInfo: [NSLocalizedDescriptionKey: "upsertCatalogTrack transaction failed"])
    }

    // Backfill step — only relevant when the transaction found an EXISTING
    // row rather than the one we just created above (a fresh row already has
    // whatever `input` carried). Non-transactional, but idempotent and safe:
    // worst case two callers both attempt the same backfill and the second
    // no-ops against `existing.field == nil` having already been filled.
    if catalogId != newDocRef.documentID, let existing = try await getCatalogTrack(catalogId: catalogId) {
        var updates: [String: Any] = [:]
        if existing.appleMusicUri == nil, let uri = input.appleMusicUri {
            updates["appleMusicUri"]     = uri
            updates["appleMusicTrackId"] = input.appleMusicTrackId
        }
        if existing.spotifyUri == nil, let uri = input.spotifyUri {
            updates["spotifyUri"]     = uri
            updates["spotifyTrackId"] = input.spotifyTrackId
        }
        // Self-heal a catalog row whose artwork/album got permanently baked
        // in from a weaker first match — either a "Greatest Hits"-style
        // compilation, or (the Salt of the Lee / Dungarvan Bay case) the
        // track's own SINGLE release. The catalog is ISRC-keyed, so a song
        // released both as a single and on an EP shares ONE row, and
        // whichever release was ingested first owns its album name for every
        // user; a row still naming the single strands that track outside its
        // album in Shelf, since `groupByAlbum` keys on album name.
        // One-directional — see `NodalongKit`'s `ReleaseMatching.swift`.
        if isBetterRelease(
            newAlbum: input.album,
            existingAlbum: existing.album,
            trackTitle: existing.title
        ) {
            updates["artwork"]          = input.artwork
            updates["album"]            = input.album
            updates["albumLower"]       = input.album.lowercased()
            updates["trackNumber"]      = input.trackNumber as Any
            updates["albumReleaseDate"] = input.albumReleaseDate as Any
        }
        if !updates.isEmpty {
            updates["updatedAt"] = now
            try await tracksCollection.document(catalogId).updateData(updates)
            // Drop the cached copy so readers pick the corrected row up.
            //
            // Without this the repair lands in Firestore but is invisible:
            // `CatalogCache` is disk-persisted and `metadata(for:)` only
            // fetches ids it does NOT already hold — it never refreshes one
            // it does. So a row cached while it still said e.g. "Dungarvan
            // Bay - Single" kept being served from disk on every cold launch
            // even after Firestore had been corrected to "Salt of the Lee -
            // EP", which is what made a saved EP track split back out into
            // its own Shelf tile on reopen (confirmed on device: identical
            // catalogId and ISRC, two different album names 90 seconds
            // apart — the save path read Firestore directly, the read path
            // read the stale cache).
            await CatalogCache.shared.invalidate([catalogId])
        }
    }
    return catalogId
}

private func createCatalogRow(_ input: CatalogTrackInput, now: Double) async throws -> String {
    let ref = tracksCollection.document()
    let track = CatalogTrack(
        title:             input.title,
        artist:            input.artist,
        album:             input.album,
        artwork:           input.artwork,
        duration:          input.duration,
        isrc:              input.isrc,
        trackNumber:       input.trackNumber,
        albumReleaseDate:  input.albumReleaseDate,
        appleMusicUri:     input.appleMusicUri,
        appleMusicTrackId: input.appleMusicTrackId,
        spotifyUri:        input.spotifyUri,
        spotifyTrackId:    input.spotifyTrackId,
        createdAt:         now,
        updatedAt:         now
    )
    let data = try Firestore.Encoder().encode(track)
    try await ref.setData(data)
    return ref.documentID
}

/// Ensures a shared-catalog row exists for a `Song` and returns its canonical
/// catalogId. A non-empty `song.catalogId` is trusted (a real Nodalong id);
/// otherwise checks `TrackCache` (isrc/title+artist → catalogId — the same
/// cache `LibrarySyncService` already uses to skip redundant Firestore
/// transactions) before falling through to a real `upsertCatalogTrack`
/// round trip, writing into whichever service's identifier fields match
/// `song.sourceService`. Shared by the Playlists and Parties add-track paths
/// (mirrors `ensureCatalogId(forLibrary:)`).
func ensureCatalogId(for song: Song) async throws -> String {
    if let existing = song.catalogId, !existing.isEmpty { return existing }
    if let cached = await TrackCache.shared.lookup(isrc: song.isrc, title: song.title, artist: song.artist) {
        return cached
    }
    var input = CatalogTrackInput(
        title:            song.title,
        artist:           song.artist,
        album:            song.album,
        artwork:          song.artwork,
        duration:         song.duration,
        isrc:             song.isrc,
        trackNumber:      song.trackNumber,
        albumReleaseDate: song.albumReleaseDate
    )
    switch song.sourceService {
    case .appleMusic:
        input = CatalogTrackInput(
            title: input.title, artist: input.artist, album: input.album, artwork: input.artwork,
            duration: input.duration, isrc: input.isrc, trackNumber: input.trackNumber,
            albumReleaseDate: input.albumReleaseDate,
            appleMusicUri: song.uri, appleMusicTrackId: song.trackId
        )
    case .spotify:
        input = CatalogTrackInput(
            title: input.title, artist: input.artist, album: input.album, artwork: input.artwork,
            duration: input.duration, isrc: input.isrc, trackNumber: input.trackNumber,
            albumReleaseDate: input.albumReleaseDate,
            spotifyUri: song.uri, spotifyTrackId: song.trackId
        )
    }
    let catalogId = try await upsertCatalogTrack(input)
    await TrackCache.shared.store(catalogId: catalogId, isrc: song.isrc, title: song.title, artist: song.artist)
    return catalogId
}
