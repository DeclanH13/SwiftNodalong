import FirebaseFirestore
import NodalongKit

// MARK: - Collection refs

private let partiesCollection = Firestore.firestore().collection("parties")

private func partyQueueCollection(_ partyId: String) -> CollectionReference {
    partiesCollection.document(partyId).collection("queue")
}

private func partyNowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

// MARK: - Party lifecycle

/// Creates a live party hosted by `host` and returns its id.
@discardableResult
func createParty(
    hostUid: String,
    hostUsername: String,
    hostAvatarEmoji: String?,
    hostAvatarColor: String?,
    title: String,
    permission: PartyPermission
) async throws -> String {
    let party = ListeningParty(
        hostUid: hostUid,
        hostUsername: hostUsername,
        hostAvatarEmoji: hostAvatarEmoji,
        hostAvatarColor: hostAvatarColor,
        title: title,
        status: .live,
        permission: permission,
        createdAt: partyNowMs()
    )
    let ref = partiesCollection.document()
    try await ref.setData(try Firestore.Encoder().encode(party))
    return ref.documentID
}

/// Loads a party by id (documentID injected).
func getParty(id: String) async throws -> ListeningParty? {
    let doc = try await partiesCollection.document(id).getDocument()
    guard doc.exists, let data = doc.data() else { return nil }
    var party = try Firestore.Decoder().decode(ListeningParty.self, from: data)
    party.id = doc.documentID
    return party
}

/// Live parties hosted by friends (client passes the friend uid set; Firestore
/// `in` caps at 30, so chunk). Newest first.
func getLivePartiesHostedBy(uids: [String]) async throws -> [ListeningParty] {
    guard !uids.isEmpty else { return [] }
    var out: [ListeningParty] = []
    for chunk in uids.chunked(into: 30) {
        let snap = try await partiesCollection
            .whereField("hostUid", in: chunk)
            .whereField("status", isEqualTo: PartyStatus.live.rawValue)
            .getDocuments()
        for doc in snap.documents {
            guard var p = try? Firestore.Decoder().decode(ListeningParty.self, from: doc.data()) else { continue }
            p.id = doc.documentID
            out.append(p)
        }
    }
    return out.sorted { $0.createdAt > $1.createdAt }
}

/// Live party hosted by a single, arbitrary uid (e.g. a nearby user in NearMe —
/// not necessarily someone followed). No `.limit`/`.order(by:)` sent to
/// Firestore (same equality-only query shape as `getLivePartiesHostedBy`, so no
/// new composite index is needed) — picks the newest client-side. Deterministic
/// even if a host transiently has more than one `.live` doc.
func getLivePartyHostedBy(uid: String) async throws -> ListeningParty? {
    let snap = try await partiesCollection
        .whereField("hostUid", isEqualTo: uid)
        .whereField("status", isEqualTo: PartyStatus.live.rawValue)
        .getDocuments()
    let parties = snap.documents.compactMap { doc -> ListeningParty? in
        guard var p = try? Firestore.Decoder().decode(ListeningParty.self, from: doc.data()) else { return nil }
        p.id = doc.documentID
        return p
    }
    return parties.max(by: { $0.createdAt < $1.createdAt })
}

/// Ends a party: freezes the queue into a playlist, then marks the party ended.
/// Returns the new playlist id (nil if the queue was empty / freeze failed).
///
/// The `status: .ended` write always runs, even if the freeze step throws
/// (network blip, catalog issue, etc.) — a freeze failure must never leave the
/// party doc stuck at `.live` forever (this was the root cause of a "zombie
/// party" bug: an unreachable, un-endable live doc that kept surfacing to other
/// users via party-discovery queries).
///
/// Re-checks the doc's live `status` first and no-ops if it's already ended —
/// needed now that cleanup can be triggered automatically from multiple places
/// (`endOrphanedLiveParties`, called both at app launch and before starting a
/// new party), which can race and otherwise double-freeze the same queue into
/// two playlists.
@discardableResult
func endParty(_ party: ListeningParty) async throws -> String? {
    if let fresh = try? await getParty(id: party.id), fresh.status != .live {
        return fresh.resultPlaylistId
    }

    var playlistId: String? = nil
    do {
        let queue = try await getPartyQueueOnce(partyId: party.id, enrich: true)
        playlistId = try await freezePlaylist(from: party, queue: queue)
    } catch {
        debugLog("[Nodalong.Party] freeze failed for party \(party.id), ending without a playlist: \(error)")
    }

    try await partiesCollection.document(party.id).updateData([
        "status":           PartyStatus.ended.rawValue,
        "endedAt":          partyNowMs(),
        "resultPlaylistId": playlistId as Any,
    ])
    return playlistId
}

/// Ends any of `hostUid`'s own live party docs. Called on app launch and before
/// starting a new party — the party VM never restores a session across an app
/// relaunch, so any doc still `.live` at either point is necessarily orphaned
/// from a previous process that crashed/force-quit before calling `endParty`,
/// never a legitimately-resumable session. Best-effort (`try?`) per party.
func endOrphanedLiveParties(hostUid: String) async {
    let mine = (try? await getLivePartiesHostedBy(uids: [hostUid])) ?? []
    diagLog("[Nodalong.Diag] endOrphanedLiveParties: found \(mine.count) live party doc(s) for \(hostUid)")
    for party in mine {
        _ = try? await endParty(party)
        diagLog("[Nodalong.Diag] endOrphanedLiveParties: ended party \(party.id)")
    }
}

/// Copies a party's queue into a new `playlists/{id}` doc (`source == .party`),
/// with `contributorUids` = host + everyone who added a track. Returns the id.
private func freezePlaylist(from party: ListeningParty, queue: [PartyQueueTrack]) async throws -> String? {
    guard !queue.isEmpty else { return nil }

    var contributors = [party.hostUid]
    for t in queue where !t.addedByUid.isEmpty && !contributors.contains(t.addedByUid) {
        contributors.append(t.addedByUid)
    }

    let playlistId = try await createPlaylist(
        ownerUid: party.hostUid,
        ownerUsername: party.hostUsername,
        ownerAvatarEmoji: party.hostAvatarEmoji,
        ownerAvatarColor: party.hostAvatarColor,
        title: party.title,
        visibility: .friends,
        source: .party,
        partyId: party.id,
        contributorUids: contributors
    )

    let db = Firestore.firestore()
    let batch = db.batch()
    let tracksCol = db.collection("playlists").document(playlistId).collection("tracks")
    for t in queue {
        batch.setData([
            "catalogId":       t.catalogId,
            "addedByUid":      t.addedByUid,
            "addedByUsername": t.addedByUsername,
            "addedAt":         t.addedAt,
            "order":           t.order,
            "sourceService":   t.sourceService.rawValue,
        ], forDocument: tracksCol.document())
    }
    batch.updateData([
        "trackCount":   queue.count,
        "coverArtwork": queue.first?.artwork ?? "",
        "updatedAt":    partyNowMs(),
    ], forDocument: db.collection("playlists").document(playlistId))
    try await batch.commit()

    return playlistId
}

// MARK: - Queue

/// One-shot ordered read of the party queue (optionally catalog-enriched).
func getPartyQueueOnce(partyId: String, enrich: Bool = true) async throws -> [PartyQueueTrack] {
    let snap = try await partyQueueCollection(partyId).order(by: "order").getDocuments()
    let docs = snap.documents.compactMap { doc -> PartyQueueTrack? in
        guard var t = try? Firestore.Decoder().decode(PartyQueueTrack.self, from: doc.data()) else { return nil }
        t.id = doc.documentID
        return t
    }
    return enrich ? await enrichPartyQueue(docs) : docs
}

/// Overlays catalog metadata onto slim queue docs (mirrors `enrichLibrary`).
func enrichPartyQueue(_ docs: [PartyQueueTrack]) async -> [PartyQueueTrack] {
    let ids = docs.map(\.catalogId).filter { !$0.isEmpty }
    guard !ids.isEmpty else { return docs }
    let meta = await CatalogCache.shared.metadata(for: ids)
    return docs.map { $0.merged(withCatalog: meta[$0.catalogId]) }
}

private func currentMaxQueueOrder(partyId: String) async throws -> Double? {
    let snap = try await partyQueueCollection(partyId)
        .order(by: "order", descending: true).limit(to: 1).getDocuments()
    guard let doc = snap.documents.first, let order = doc.data()["order"] as? Double else { return nil }
    return order
}

/// Appends `song` to the party queue (ensuring its catalog row). Permission is
/// enforced by the caller + security rules; this just writes.
func addToPartyQueue(partyId: String, song: Song, addedByUid: String, addedByUsername: String) async throws {
    let catalogId = try await ensureCatalogId(for: song)
    let maxOrder  = try await currentMaxQueueOrder(partyId: partyId)
    let order     = PlaylistOrder.appended(afterMax: maxOrder)
    try await partyQueueCollection(partyId).document().setData([
        "catalogId":       catalogId,
        "addedByUid":      addedByUid,
        "addedByUsername": addedByUsername,
        "addedAt":         partyNowMs(),
        "order":           order,
        "sourceService":   song.sourceService.rawValue,
        "played":          false,
    ])
}

/// Seeds a brand-new party's empty `queue` from the host's current local
/// playback state — `songs[0]` MUST be the currently-playing track,
/// `songs[1...]` the rest of `upNext`, in order. Must run BEFORE
/// `ListeningPartyViewModel.enter()` wires the `$queue` → `reconcileQueue`
/// bridge, or the party's first snapshot is empty and `reconcileQueue`'s
/// anchor lookup no-ops forever (the missing-carryover bug this fixes).
///
/// `songs[0]`'s doc gets an EXPLICIT id equal to `songs[0].id`, not an
/// auto-generated one — load-bearing, not cosmetic: `Song.from(partyQueueTrack:)`
/// always sets a party-sourced `Song.id` to the Firestore queue-doc id, so
/// `reconcileQueue`'s anchor can only match `current.song.id` against an
/// incoming snapshot if the seeded current-track doc's id IS that string.
/// An auto id would permanently miss the anchor. Every other doc keeps a
/// normal auto id (never anchor-matched).
///
/// The current track is seeded `played: true`, mirroring the invariant
/// `hostBroadcast` establishes for later tracks — otherwise `enter()`'s
/// `CombineLatest(nowPlaying, isPlaying)` sink (fires immediately on
/// subscribe, before the queue listener delivers anything locally) can
/// never find it to mark played.
///
/// Mirrors `freezePlaylist`'s single-`WriteBatch` pattern rather than looping
/// `addToPartyQueue` — the queue is known empty at seed time, so there's no
/// need for `addToPartyQueue`'s per-call `currentMaxQueueOrder` read.
func seedPartyQueue(
    partyId: String,
    songs: [Song],
    hostUid: String,
    hostUsername: String
) async throws {
    guard !songs.isEmpty else { return }

    var catalogIds = [String](repeating: "", count: songs.count)
    try await withThrowingTaskGroup(of: (Int, String).self) { group in
        for (i, song) in songs.enumerated() {
            group.addTask { (i, try await ensureCatalogId(for: song)) }
        }
        for try await (i, id) in group { catalogIds[i] = id }
    }

    let db    = Firestore.firestore()
    let batch = db.batch()
    let col   = partyQueueCollection(partyId)
    let now   = partyNowMs()
    for (index, song) in songs.enumerated() {
        let docRef = (index == 0 && !song.id.isEmpty && !song.id.contains("/"))
            ? col.document(song.id)
            : col.document()
        batch.setData([
            "catalogId":       catalogIds[index],
            "addedByUid":      hostUid,
            "addedByUsername": hostUsername,
            "addedAt":         now,
            "order":           Double(index) * PlaylistOrder.step,
            "sourceService":   song.sourceService.rawValue,
            "played":          index == 0,
        ], forDocument: docRef)
    }
    try await batch.commit()
}

/// Marks a queue entry as played (host advances through the queue).
func markPartyQueueTrackPlayed(partyId: String, trackDocId: String) async throws {
    try await partyQueueCollection(partyId).document(trackDocId).updateData(["played": true])
}

func removeFromPartyQueue(partyId: String, trackDocId: String) async throws {
    try await partyQueueCollection(partyId).document(trackDocId).delete()
}

/// Reorders a party-queue track by assigning it the midpoint `order` between
/// its new neighbours — a single-document write. Mirrors `reorderPlaylistTrack`
/// (`Playlists.swift`): `before`/`after` are the neighbours' current orders at
/// the destination (nil at the list ends).
func reorderPartyQueueTrack(partyId: String, trackDocId: String, before: Double?, after: Double?) async throws {
    let newOrder = PlaylistOrder.midpoint(before: before, after: after)
    try await partyQueueCollection(partyId).document(trackDocId)
        .updateData(["order": newOrder])
}

// MARK: - Real-time listeners (the app's first Firestore snapshot listeners)

/// Attaches a snapshot listener to the party doc. Returns the registration —
/// the caller MUST remove it on leave/background (see `ListeningPartyViewModel`).
func listenToParty(partyId: String, onChange: @escaping (ListeningParty?) -> Void) -> ListenerRegistration {
    partiesCollection.document(partyId).addSnapshotListener { snap, _ in
        guard let snap, snap.exists, let data = snap.data(),
              var party = try? Firestore.Decoder().decode(ListeningParty.self, from: data) else {
            onChange(nil); return
        }
        party.id = snap.documentID
        onChange(party)
    }
}

/// Attaches a snapshot listener to the party queue, delivering enriched, ordered
/// tracks on every change. Registration MUST be removed on leave/background.
func listenToPartyQueue(partyId: String, onChange: @escaping ([PartyQueueTrack]) -> Void) -> ListenerRegistration {
    partyQueueCollection(partyId).order(by: "order").addSnapshotListener { snap, _ in
        guard let snap else { onChange([]); return }
        let docs = snap.documents.compactMap { doc -> PartyQueueTrack? in
            guard var t = try? Firestore.Decoder().decode(PartyQueueTrack.self, from: doc.data()) else { return nil }
            t.id = doc.documentID
            return t
        }
        Task {
            let enriched = await enrichPartyQueue(docs)
            await MainActor.run { onChange(enriched) }
        }
    }
}
