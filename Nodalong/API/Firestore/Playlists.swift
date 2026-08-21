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
    let playlists = snap.documents.compactMap { doc -> Playlist? in
        guard var p = try? Firestore.Decoder().decode(Playlist.self, from: doc.data()) else { return nil }
        p.id = doc.documentID
        return p
    }
    return playlists.sorted { $0.updatedAt > $1.updatedAt }
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
    partyId: String? = nil,
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
        partyId: partyId,
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
