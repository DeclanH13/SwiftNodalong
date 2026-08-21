import FirebaseFirestore
import NodalongKit

private let db = Firestore.firestore()

// MARK: - Sync recent_tracks subcollection

/// Upsert up to 30 recently-played tracks to `users/{uid}/recent_tracks`, preserving existing playCount.
/// Matches the RN `syncRecentTracks` in activity.ts.
///
/// `tracks` arrives in MusicKit's own most-recent-first order (preserved end
/// to end from `AppleMusicService.getRecentlyPlayed()` — MusicKit only
/// exposes relative order, never a real per-item play timestamp), so each
/// track's position doubles as its true recency rank *within this sync*.
///
/// `listenedAt` is assigned from that position rather than a fresh `Date()`
/// call per track — calling `Date()` inside the loop while iterating
/// newest-first meant the actual most recent play got the *earliest*
/// timestamp of the batch, inverting the true order once read back sorted
/// descending.
///
/// A track already seen in a prior sync keeps its existing `listenedAt`
/// untouched unless it has genuinely moved to a more recent position than
/// last time (a real replay) — otherwise every still-in-Apple's-top-25 track
/// would get bumped to "just now" on every app open, making Recent Tracks
/// reorder itself just from opening the app rather than from actually
/// listening to something again.
func syncRecentTracks(uid: String, tracks: [(song: Song, catalogId: String)]) async throws {
    guard !tracks.isEmpty else { return }
    let colRef = db.collection("users").document(uid).collection("recent_tracks")

    // Preserve existing nod counts, and read each existing track's prior
    // listenedAt + relative rank (sorted desc, matching how they'll be read
    // back) so we can tell "genuinely moved up" apart from "still present."
    //
    // Bounded to the 500 most recent — this collection accumulates forever
    // (upsert by trackId, never deleted), so an unbounded read here got
    // steadily more expensive every launch (measured reading the full
    // collection on every sync). 500 is ~20 syncs' worth of headroom past
    // the ≤30 tracks actually being written this call, so a track that
    // genuinely falls outside it and gets replayed today is treated as new
    // (loses its accumulated playCount/replayCount) rather than a true
    // replay — an accepted, intentionally generous-margin edge case.
    let existing = try await colRef
        .order(by: "listenedAt", descending: true)
        .limit(to: 500)
        .getDocuments()
    var playCounts: [String: Int] = [:]
    var replayCounts: [String: Int] = [:]
    var existingListenedAt: [String: Double] = [:]
    for doc in existing.documents {
        if let count = doc.data()["playCount"] as? Int {
            playCounts[doc.documentID] = count
        }
        if let replays = doc.data()["replayCount"] as? Int {
            replayCounts[doc.documentID] = replays
        }
        if let listenedAt = doc.data()["listenedAt"] as? Double {
            existingListenedAt[doc.documentID] = listenedAt
        }
    }
    let existingRank: [String: Int] = Dictionary(
        uniqueKeysWithValues: existingListenedAt
            .sorted { $0.value > $1.value }
            .enumerated()
            .map { ($0.element.key, $0.offset) }
    )

    let anchor = Date().timeIntervalSince1970 * 1000
    let batch = db.batch()
    for (index, item) in tracks.prefix(30).enumerated() {
        let song = item.song
        let priorListenedAt = existingListenedAt[song.trackId]
        let movedUp = existingRank[song.trackId].map { index < $0 } ?? true
        // Distinct from `movedUp`: a brand-new track (no prior rank) is NOT
        // a "replay" — only a track that existed before AND has genuinely
        // moved to a more recent position counts as one. Powers "On Repeat"
        // (`Post.replayCount`) — a personal-listening signal, kept separate
        // from `playCount`/`nods` (a social signal from OTHER users).
        let isGenuineReplay = existingRank[song.trackId].map { index < $0 } ?? false
        let replayCount = (replayCounts[song.trackId] ?? 0) + (isGenuineReplay ? 1 : 0)
        let listenedAt: Double
        if let real = song.listenedAt {
            // Respect a genuine timestamp if one is ever provided directly —
            // MusicKit doesn't supply one today, but the field exists on
            // `Song` for other sources; don't silently ignore it.
            listenedAt = real
        } else if let priorListenedAt, !movedUp {
            listenedAt = priorListenedAt
        } else {
            listenedAt = anchor - Double(index)
        }

        // Slim event doc — metadata lives in the catalog (single source of
        // truth) and is overlaid on read. Store only catalogId + event data.
        let data: [String: Any] = [
            "trackId":       song.trackId,
            "listenedAt":    listenedAt,
            "playCount":     playCounts[song.trackId] ?? 0,
            "replayCount":   replayCount,
            "catalogId":     item.catalogId,
            "sourceService": MusicServiceType.appleMusic.rawValue
        ]
        batch.setData(data, forDocument: colRef.document(song.trackId))
    }
    try await batch.commit()
}

// MARK: - Feed from recent_tracks subcollections

/// Fetch the "Following" feed: recent tracks from all users that `myUid` follows.
/// Matches the RN `loadFollowingFeed` in Feed.tsx.
///
/// The following list itself is read via `FollowingCache` (not a direct
/// Firestore query) — at launch, `HomeViewModel` and `FeedView`'s
/// party-discovery banner also need this same list within the same second;
/// routing through the shared cache collapses what would otherwise be 3
/// concurrent reads of identical data down to 1.
func getFollowingFeed(myUid: String) async throws -> [Post] {
    let following = await FollowingCache.shared.following(uid: myUid)

    guard !following.isEmpty else { return [] }

    // ONE batched (and now session-cached) read covering every followed
    // profile, replacing the `getDocument()` that used to run per user inside
    // the task group below. At launch this same profile set is also needed by
    // `getFriendsSpotlightsToday` and `loadLiveNow`; routing all three through
    // `UserProfileCache` collapses what were three concurrent fetches into one.
    let profiles = await UserProfileCache.shared.profiles(uids: following.map(\.uid))
    let profileByUid = Dictionary(uniqueKeysWithValues: profiles.map { ($0.uid, $0) })

    // This fan-out fetches `N × perUserLimit` docs and then keeps only the 50
    // most recent overall, so a flat 30 is a ~12× over-fetch at 20 follows.
    // But cutting it unconditionally would SHRINK the feed for someone
    // following only a handful of people (3 follows × 10 = 30 candidates for
    // 50 slots), so trim only where there's genuine waste.
    let perUserLimit = following.count > 10 ? 10 : 30

    var allPosts: [Post] = []

    try await withThrowingTaskGroup(of: [Post].self) { group in
        for entry in following {
            let targetUid = entry.uid
            let username  = entry.username
            let profile   = profileByUid[targetUid]

            group.addTask {
                let tracks = try await db.collection("users").document(targetUid)
                    .collection("recent_tracks")
                    .order(by: "listenedAt", descending: true)
                    .limit(to: perUserLimit)
                    .getDocuments()

                let avatarEmoji = profile?.avatarEmoji
                let avatarColor = profile?.avatarColor
                // `SpotlightTrack.trackId` is always written as the catalogId
                // (see `addToSpotlight`), and `mapRecentTrack` compares against
                // catalogId — so reading `catalogId` here is the same value the
                // raw-dictionary `trackId` read produced, just type-safe.
                let spotlitIds = Set((profile?.spotlightTracks ?? []).compactMap(\.catalogId))

                return tracks.documents.compactMap { doc -> Post? in
                    mapRecentTrack(doc: doc, uid: targetUid, username: username,
                                   avatarEmoji: avatarEmoji, avatarColor: avatarColor,
                                   spotlitIds: spotlitIds)
                }
            }
        }

        for try await posts in group {
            allPosts += posts
        }
    }

    let top = allPosts
        .sorted { $0.createdAt > $1.createdAt }
        .prefix(50)
        .map { $0 }
    return await overlayCatalog(top)
}

/// Fetch the "Your Music" feed from the current user's own recent_tracks.
///
/// **Limit 100** — `syncRecentTracks` accumulates over time (upsert by
/// trackId, never deletes old entries), so the Firestore collection grows
/// past Apple's per-sync cap of 25. Reading 100 here gives ~17 pages in
/// the 6-per-page carousel without round-tripping for pagination.
func getYourMusicFeed(uid: String) async throws -> [Post] {
    async let trackSnap = db.collection("users").document(uid)
        .collection("recent_tracks")
        .order(by: "listenedAt", descending: true)
        .limit(to: 100)
        .getDocuments()

    async let profileSnap = db.collection("users").document(uid).getDocument()

    let (tracks, profile) = try await (trackSnap, profileSnap)
    let username    = profile.data()?["username"]    as? String ?? ""
    let avatarEmoji = profile.data()?["avatarEmoji"] as? String
    let avatarColor = profile.data()?["avatarColor"] as? String

    let posts = tracks.documents.compactMap { doc in
        mapRecentTrack(doc: doc, uid: uid, username: username,
                       avatarEmoji: avatarEmoji, avatarColor: avatarColor)
    }
    return await overlayCatalog(posts)
}

/// Overlays catalog metadata (title/artist/album/artwork/uri) onto posts built
/// from slim `recent_tracks` event docs. The `tracks` catalog is the single
/// source of truth; the event doc supplies only `catalogId` + event data.
/// Joins through `CatalogCache` so recurring tracks are fetched once per
/// session. Posts whose catalog row is missing keep whatever the event doc
/// still carried (empty for slim docs).
func overlayCatalog(_ posts: [Post]) async -> [Post] {
    let ids = posts.map(\.catalogId).filter { !$0.isEmpty }
    guard !ids.isEmpty else { return posts }
    let meta = await CatalogCache.shared.metadata(for: ids)
    return posts.map { $0.merged(withCatalog: meta[$0.catalogId]) }
}

/// Increment the playCount ("nod") on another user's track.
func incrementPlayCount(sourceUid: String, trackId: String) async throws {
    try await db.collection("users").document(sourceUid)
        .collection("recent_tracks").document(trackId)
        .updateData(["playCount": FieldValue.increment(Int64(1))])
}

/// Atomically increment a nod, preventing self-nods and more-than-once-per-day
/// duplicate nods for the same track. Mirrors the RN `tryIncrementNod`
/// transaction in activity.ts.
///
/// One nod per (nodder, track) per **calendar day** — the record is keyed
/// `{nodderUid}_{sourceUid}_{trackId}_{dateKey}`, so repeatedly tapping play on
/// the same card today doesn't inflate the count, but tapping it again
/// tomorrow is a genuine new nod and increments again.
/// - Returns: `true` if the nod was new (count incremented), `false` if
///   already nodded today or self-nod.
@discardableResult
func tryIncrementNod(nodderUid: String, sourceUid: String, trackId: String) async throws -> Bool {
    guard nodderUid != sourceUid else { return false }
    let now = Date().timeIntervalSince1970 * 1000
    let today = dateKey(epochMs: now)
    let recordRef = db.collection("nod_records")
        .document("\(nodderUid)_\(sourceUid)_\(trackId)_\(today)")
    let trackRef = db.collection("users").document(sourceUid)
        .collection("recent_tracks").document(trackId)

    var wasNew = false
    _ = try await db.runTransaction { tx, errorPointer in
        let snap: DocumentSnapshot
        do { snap = try tx.getDocument(recordRef) }
        catch let err as NSError { errorPointer?.pointee = err; return nil }
        if snap.exists { return nil }
        tx.setData([
            "nodderUid": nodderUid, "sourceUid": sourceUid,
            "trackId": trackId, "dateKey": today, "createdAt": now
        ], forDocument: recordRef)
        tx.updateData(["playCount": FieldValue.increment(Int64(1))], forDocument: trackRef)
        wasNew = true
        return nil
    }
    return wasNew
}

// MARK: - Private helpers

private func mapRecentTrack(
    doc: QueryDocumentSnapshot,
    uid: String,
    username: String,
    avatarEmoji: String?,
    avatarColor: String?,
    spotlitIds: Set<String> = []
) -> Post? {
    let d = doc.data()
    // Slim event docs carry only catalogId + event data; metadata is overlaid
    // from the catalog by `overlayCatalog`. Any metadata still present on a doc
    // is read as a fallback base. A doc with no catalogId AND no title is junk.
    let catalogId = d["catalogId"] as? String ?? ""
    let title  = d["title"]  as? String ?? ""
    let artist = d["artist"] as? String ?? ""
    guard !catalogId.isEmpty || !title.isEmpty else { return nil }

    let listenedAt = d["listenedAt"] as? Double ?? 0

    // Decode the persisted sourceService when available; default to
    // .appleMusic (the current canonical source) when older documents
    // don't have the field set.
    let sourceService: MusicServiceType = {
        if let raw = d["sourceService"] as? String,
           let parsed = MusicServiceType(rawValue: raw) {
            return parsed
        }
        return .appleMusic
    }()

    return Post(
        id:            "\(uid)_\(doc.documentID)",
        uid:           uid,
        username:      username,
        avatarEmoji:   avatarEmoji,
        avatarColor:   avatarColor,
        catalogId:     catalogId,
        title:         title,
        artist:        artist,
        album:         d["album"]   as? String ?? "",
        artwork:       d["artwork"] as? String ?? "",
        uri:           d["uri"]     as? String ?? "",
        sourceService: sourceService,
        nods:          d["playCount"] as? Int ?? 0,
        replayCount:   d["replayCount"] as? Int ?? 0,
        // `spotlitIds` holds catalogIds (see `getFollowingFeed` — sourced from
        // `spotlightTracks[].trackId`, which despite the field name is always
        // set to the catalogId, per `FirebaseAuthViewModel.addToSpotlight`).
        // `doc.documentID` here is the recent_tracks doc's key, which is the
        // Apple Music track id — a different id space entirely. Comparing
        // against `catalogId` is the fix; comparing against `doc.documentID`
        // made `isSpotlit` false for virtually every genuinely-spotlit post.
        isSpotlit:     spotlitIds.contains(catalogId),
        createdAt:     listenedAt,
        sourceUid:     uid,
        trackId:       doc.documentID
    )
}
