import FirebaseFirestore
import NodalongKit

// MARK: - Collection refs

private let playlistsCollection = Firestore.firestore().collection("playlists")

private func playlistTracksCollection(_ playlistId: String) -> CollectionReference {
    playlistsCollection.document(playlistId).collection("tracks")
}

private func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

// MARK: - Read

/// Loads a single playlist by id (documentID injected onto the model).
func getPlaylist(id: String) async throws -> Playlist? {
    let doc = try await playlistsCollection.document(id).getDocument()
    guard doc.exists, let data = doc.data() else { return nil }
    var playlist = try Firestore.Decoder().decode(Playlist.self, from: data)
    playlist.id = doc.documentID
    return playlist
}

/// All playlists `uid` contributed to (owned + party playlists they were part
/// of), newest first. `contributorUids` always includes the owner, so this one
/// query covers both. Sorted client-side to avoid a composite index.
func getUserPlaylists(uid: String) async throws -> [Playlist] {
    let snap = try await playlistsCollection
        .whereField("contributorUids", arrayContains: uid)
        .getDocuments()
    return decodePlaylists(snap)
}

/// Playlists of `ownerUid` that `viewerUid` is actually allowed to see.
///
/// **Use this for anyone else's profile; `getUserPlaylists` is for your own.**
/// The distinction is not stylistic — it's what keeps the query legal under the
/// visibility rules in `firestore.rules`.
///
/// Firestore evaluates read rules PER RETURNED DOCUMENT on a list query, and if
/// a single returned doc fails the rule the WHOLE query fails rather than
/// filtering that doc out. `getUserPlaylists` queries
/// `contributorUids arrayContains <uid>`; pointed at someone else that returns
/// docs which don't list *you*, so the rule's contributor clause fails and the
/// query dies outright. (An earlier attempt at visibility rules was reverted for
/// exactly this reason — see the decisions log.)
///
/// So this constrains by `ownerUid` + an explicit `visibility` set instead, and
/// every document it can return independently satisfies the rule. Sorted
/// client-side, matching `getUserPlaylists`, to avoid needing a composite index.
func getVisiblePlaylists(ownerUid: String, viewerUid: String) async throws -> [Playlist] {
    // Your own profile: keep the contributor query, so party playlists you took
    // part in but don't own still show up.
    if ownerUid == viewerUid { return try await getUserPlaylists(uid: ownerUid) }

    // The rule allows `friends` only when the viewer follows the owner, so ask
    // for those docs only when that's true — otherwise the query would return
    // documents the rule rejects and fail as a whole.
    let following = await FollowingCache.shared.following(uid: viewerUid)
    let follows   = following.contains { $0.uid == ownerUid }
    let allowed   = follows
        ? [PlaylistVisibility.public.rawValue, PlaylistVisibility.friends.rawValue]
        : [PlaylistVisibility.public.rawValue]

    let snap = try await playlistsCollection
        .whereField("ownerUid", isEqualTo: ownerUid)
        .whereField("visibility", in: allowed)
        .getDocuments()

    return decodePlaylists(snap)
}

/// Ordered tracks for a playlist, with catalog metadata overlaid.
func getPlaylistTracks(playlistId: String) async throws -> [PlaylistTrack] {
    let snap = try await playlistTracksCollection(playlistId)
        .order(by: "order")
        .getDocuments()
    let docs = snap.documents.compactMap { doc -> PlaylistTrack? in
        guard var t = try? Firestore.Decoder().decode(PlaylistTrack.self, from: doc.data()) else { return nil }
        t.id = doc.documentID
        return t
    }
    return await enrichPlaylistTracks(docs)
}

/// Overlays catalog metadata onto slim playlist-track docs. The catalog is the
/// single source of truth; joins through `CatalogCache`. Mirrors `enrichLibrary`.
func enrichPlaylistTracks(_ docs: [PlaylistTrack]) async -> [PlaylistTrack] {
    let ids = docs.map(\.catalogId).filter { !$0.isEmpty }
    guard !ids.isEmpty else { return docs }
    let meta = await CatalogCache.shared.metadata(for: ids)
    return docs.map { $0.merged(withCatalog: meta[$0.catalogId]) }
}

/// Decodes a playlist query snapshot, injecting each documentID (not part of
/// the stored payload) and ordering newest-updated first.
///
/// Shared by `getUserPlaylists` and `getVisiblePlaylists`, which query
/// differently but must decode and order identically.
private func decodePlaylists(_ snap: QuerySnapshot) -> [Playlist] {
    snap.documents
        .compactMap { doc -> Playlist? in
            guard var p = try? Firestore.Decoder().decode(Playlist.self, from: doc.data()) else { return nil }
            p.id = doc.documentID
            return p
        }
        .sorted { $0.updatedAt > $1.updatedAt }
}

// MARK: - Playlist CRUD

/// Creates an empty playlist owned by `ownerUid` and returns its id. The owner
/// is always the first contributor so `getUserPlaylists` finds it.
@discardableResult
func createPlaylist(
    ownerUid: String,
    ownerUsername: String,
    ownerAvatarEmoji: String?,
    ownerAvatarColor: String?,
    title: String,
    description: String? = nil,
    visibility: PlaylistVisibility = .friends,
    source: PlaylistSource = .manual,
    lens: PlaylistLens? = nil,
    partyId: String? = nil,
    genre: String? = nil,
    variant: String? = nil,
    contributorUids: [String]? = nil
) async throws -> String {
    let now = nowMs()
    let playlist = Playlist(
        ownerUid: ownerUid,
        ownerUsername: ownerUsername,
        ownerAvatarEmoji: ownerAvatarEmoji,
        ownerAvatarColor: ownerAvatarColor,
        title: title,
        description: description,
        coverArtwork: "",
        visibility: visibility,
        source: source,
        lens: lens,
        partyId: partyId,
        genre: genre,
        variant: variant,
        contributorUids: contributorUids ?? [ownerUid],
        trackCount: 0,
        createdAt: now,
        updatedAt: now
    )
    let ref = playlistsCollection.document()
    try await ref.setData(try Firestore.Encoder().encode(playlist))
    return ref.documentID
}

/// Updates editable playlist metadata. Only non-nil fields are written.
func updatePlaylistMeta(
    id: String,
    title: String? = nil,
    description: String? = nil,
    visibility: PlaylistVisibility? = nil,
    coverArtwork: String? = nil
) async throws {
    var data: [String: Any] = ["updatedAt": nowMs()]
    if let title { data["title"] = title }
    if let description { data["description"] = description }
    if let visibility { data["visibility"] = visibility.rawValue }
    if let coverArtwork { data["coverArtwork"] = coverArtwork }
    try await playlistsCollection.document(id).updateData(data)
}

/// Saves a copy of `source` as a normal, editable playlist owned by the caller.
///
/// This is how a generated playlist is kept: those are rebuilt weekly and can't
/// be edited, so a copy is the only way to hold on to a version. Track docs are
/// copied as-is (same `catalogId`, `order` and `addedBy*`, so "via <name>"
/// credits survive) in ONE batch — no per-track catalog round trips.
func copyPlaylist(
    from source: Playlist,
    ownerUid: String,
    ownerUsername: String,
    ownerAvatarEmoji: String?,
    ownerAvatarColor: String?,
    title: String
) async throws -> String {
    let newId = try await createPlaylist(
        ownerUid: ownerUid,
        ownerUsername: ownerUsername,
        ownerAvatarEmoji: ownerAvatarEmoji,
        ownerAvatarColor: ownerAvatarColor,
        title: title,
        description: "Saved from \(source.title)"
    )
    let snap = try await playlistTracksCollection(source.id).order(by: "order").getDocuments()
    let batch = Firestore.firestore().batch()
    for doc in snap.documents {
        batch.setData(doc.data(), forDocument: playlistTracksCollection(newId).document())
    }
    batch.updateData([
        "trackCount":   snap.documents.count,
        "coverArtwork": source.coverArtwork,
        "updatedAt":    nowMs(),
    ], forDocument: playlistsCollection.document(newId))
    try await batch.commit()
    return newId
}

/// Deletes a playlist and all of its track docs in one batch.
func deletePlaylist(id: String) async throws {
    let db = Firestore.firestore()
    let trackDocs = try await playlistTracksCollection(id).getDocuments()
    let batch = db.batch()
    for doc in trackDocs.documents {
        batch.deleteDocument(doc.reference)
    }
    batch.deleteDocument(playlistsCollection.document(id))
    try await batch.commit()
}

// MARK: - Track mutations

/// The current maximum `order` in a playlist, or nil when empty.
private func currentMaxOrder(playlistId: String) async throws -> Double? {
    let snap = try await playlistTracksCollection(playlistId)
        .order(by: "order", descending: true)
        .limit(to: 1)
        .getDocuments()
    guard let doc = snap.documents.first,
          let order = doc.data()["order"] as? Double else { return nil }
    return order
}

/// Slim playlist-track doc — metadata lives in the catalog and is overlaid on
/// read. Store only catalogId + event data.
private func slimPlaylistTrackData(
    catalogId: String, addedByUid: String, addedByUsername: String,
    addedAt: Double, order: Double, sourceService: MusicServiceType
) -> [String: Any] {
    [
        "catalogId":       catalogId,
        "addedByUid":      addedByUid,
        "addedByUsername": addedByUsername,
        "addedAt":         addedAt,
        "order":           order,
        "sourceService":   sourceService.rawValue,
    ]
}

/// Appends `song` to a playlist. Ensures the catalog entry (so the track carries
/// service-neutral ISRC identity), appends after the current max order, bumps
/// `trackCount`, and seeds the cover art from the first track added.
func addTrackToPlaylist(
    playlistId: String, song: Song, addedByUid: String, addedByUsername: String
) async throws {
    let catalogId = try await ensureCatalogId(for: song)
    let maxOrder  = try await currentMaxOrder(playlistId: playlistId)
    let order     = PlaylistOrder.appended(afterMax: maxOrder)
    let now       = nowMs()

    let db = Firestore.firestore()
    let batch = db.batch()
    batch.setData(
        slimPlaylistTrackData(
            catalogId: catalogId, addedByUid: addedByUid, addedByUsername: addedByUsername,
            addedAt: now, order: order, sourceService: song.sourceService
        ),
        forDocument: playlistTracksCollection(playlistId).document()
    )
    var playlistUpdate: [String: Any] = [
        "trackCount": FieldValue.increment(Int64(1)),
        "updatedAt":  now,
    ]
    // Seed the cover from the first track's artwork.
    if maxOrder == nil, !song.artwork.isEmpty {
        playlistUpdate["coverArtwork"] = song.artwork
    }
    batch.updateData(playlistUpdate, forDocument: playlistsCollection.document(playlistId))
    try await batch.commit()
}

/// Removes a track (by its doc id) and decrements `trackCount`.
func removeTrackFromPlaylist(playlistId: String, trackDocId: String) async throws {
    let db = Firestore.firestore()
    let batch = db.batch()
    batch.deleteDocument(playlistTracksCollection(playlistId).document(trackDocId))
    batch.updateData([
        "trackCount": FieldValue.increment(Int64(-1)),
        "updatedAt":  nowMs(),
    ], forDocument: playlistsCollection.document(playlistId))
    try await batch.commit()
}

/// Reorders a track by assigning it the midpoint `order` between its new
/// neighbours — a single-document write. `before`/`after` are the neighbours'
/// current orders at the destination (nil at the list ends).
func reorderPlaylistTrack(
    playlistId: String, trackDocId: String, before: Double?, after: Double?
) async throws {
    let newOrder = PlaylistOrder.midpoint(before: before, after: after)
    try await playlistTracksCollection(playlistId).document(trackDocId)
        .updateData(["order": newOrder])
}


// MARK: - Generated playlists

/// Finds this user's existing playlist for `lens`, if any.
///
/// Generated playlists are **regenerated in place** on a stable doc id rather
/// than created fresh each run, so repeat generations don't accumulate docs and
/// the user's position in Shelf/Profile stays put. Filtered client-side to avoid
/// needing a composite index for a query this small.
/// Matches on `(lens, genre)`, not lens alone: a user can hold one general
/// `.taste` playlist plus one per genre, and matching on lens only would make
/// every genre run overwrite the same document.
func getGeneratedPlaylist(
    ownerUid: String, lens: PlaylistLens, genre: String? = nil, variant: String? = nil
) async throws -> Playlist? {
    let mine = try await getUserPlaylists(uid: ownerUid)
    return mine.first {
        $0.ownerUid == ownerUid && $0.source == .generated && $0.lens == lens
            && $0.genre == genre && $0.variant == variant
    }
}

/// Creates or refreshes the generated playlist for `lens`, replacing its tracks
/// wholesale with `tracks` (already ordered best-first by the generator).
///
/// Replacement is deliberately *destructive but atomic per stage*: the old track
/// docs are deleted and the new ones written in a single `WriteBatch`, so a
/// reader never sees a half-rebuilt list. Modelled on `freezePlaylist` in
/// `Parties.swift`, which is this codebase's existing precedent for building a
/// playlist programmatically.
///
/// **`contributorUids` is deliberately the owner ONLY**, unlike a frozen party
/// playlist. `getUserPlaylists` is an `arrayContains` query on this field, so
/// listing the sourced people here would make your generated playlist appear on
/// *their* profiles unbidden — and for the `nearby`/`admirers` lenses those are
/// strangers, who would effectively be told their listening had been mined. A
/// party is consensual co-presence; this isn't. Per-track credit still works,
/// via `addedByUid`/`addedByUsername` on each track — which is what actually
/// delivers the "real people" feel.
@discardableResult
func upsertGeneratedPlaylist(
    ownerUid: String,
    ownerUsername: String,
    ownerAvatarEmoji: String?,
    ownerAvatarColor: String?,
    lens: PlaylistLens,
    description: String?,
    coverArtwork: String,
    /// Non-nil for a genre-scoped discovery playlist. Part of the identity —
    /// see `getGeneratedPlaylist`.
    genre: String? = nil,
    /// Names the seed artist for a `.becauseArtist` playlist. Part of the identity.
    variant: String? = nil,
    /// Overrides `lens.title`, so a genre playlist can name its genre.
    title: String? = nil,
    tracks: [(catalogId: String, addedByUid: String, addedByUsername: String, sourceService: MusicServiceType)]
) async throws -> String {
    let resolvedTitle = title ?? lens.title
    let now = nowMs()
    let db  = Firestore.firestore()

    // Owner only — see this function's doc comment for why the sourced people
    // are deliberately NOT listed here.
    let contributors = [ownerUid]

    let existing = try await getGeneratedPlaylist(ownerUid: ownerUid, lens: lens, genre: genre, variant: variant)
    let playlistId: String

    if let existing {
        playlistId = existing.id
        // Clear the previous run's tracks before writing the new ones.
        let oldDocs = try await playlistTracksCollection(playlistId).getDocuments()
        if !oldDocs.documents.isEmpty {
            let deleteBatch = db.batch()
            for doc in oldDocs.documents { deleteBatch.deleteDocument(doc.reference) }
            try await deleteBatch.commit()
        }
        try await playlistsCollection.document(playlistId).updateData([
            "title":           resolvedTitle,
            "description":     description as Any,
            "coverArtwork":    coverArtwork,
            "contributorUids": contributors,
            "trackCount":      tracks.count,
            "updatedAt":       now,
        ])
    } else {
        playlistId = try await createPlaylist(
            ownerUid: ownerUid,
            ownerUsername: ownerUsername,
            ownerAvatarEmoji: ownerAvatarEmoji,
            ownerAvatarColor: ownerAvatarColor,
            title: resolvedTitle,
            description: description,
            visibility: .friends,
            source: .generated,
            lens: lens,
            genre: genre,
            variant: variant,
            contributorUids: contributors
        )
        try await playlistsCollection.document(playlistId).updateData([
            "coverArtwork": coverArtwork,
            "trackCount":   tracks.count,
            "updatedAt":    now,
        ])
    }

    guard !tracks.isEmpty else { return playlistId }

    let writeBatch = db.batch()
    var order = PlaylistOrder.step
    for t in tracks {
        writeBatch.setData(
            slimPlaylistTrackData(
                catalogId: t.catalogId,
                addedByUid: t.addedByUid,
                addedByUsername: t.addedByUsername,
                addedAt: now,
                order: order,
                sourceService: t.sourceService
            ),
            forDocument: playlistTracksCollection(playlistId).document()
        )
        order += PlaylistOrder.step
    }
    try await writeBatch.commit()

    return playlistId
}
