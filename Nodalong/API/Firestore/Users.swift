import FirebaseFirestore
import NodalongKit

private let usersCollection = Firestore.firestore().collection("users")

func createUserProfile(_ profile: UserProfile) async throws {
    let data = try Firestore.Encoder().encode(profile)
    try await usersCollection.document(profile.uid).setData(data)
}

func getUserProfile(uid: String) async throws -> UserProfile? {
    let doc = try await usersCollection.document(uid).getDocument()
    guard doc.exists, let data = doc.data() else { return nil }
    return try await decodeUserProfile(documentID: doc.documentID, data: data)
}

/// Batched lookup for a set of uids (Firestore `in` caps at 30, so chunk) —
/// e.g. enriching a follow list's bare `(uid, username)` entries into full
/// `UserProfile`s for avatar display + navigation. Order isn't guaranteed to
/// match `uids`; callers that care about order should re-sort by uid. A
/// single malformed document is skipped rather than failing the whole batch.
func getUserProfiles(uids: [String]) async throws -> [UserProfile] {
    guard !uids.isEmpty else { return [] }

    // Chunks run CONCURRENTLY. The previous sequential `for` loop serialized
    // every 30-uid batch, so a 100-follow graph paid four round trips
    // end-to-end — `CatalogCache.metadata` already parallelises its own
    // chunks exactly this way.
    let collection = usersCollection
    let raw: [UserProfile] = await withTaskGroup(of: [UserProfile].self) { group in
        for chunk in uids.chunked(into: 30) {
            group.addTask {
                guard let snap = try? await collection
                    .whereField(FieldPath.documentID(), in: chunk)
                    .getDocuments()
                else { return [] }
                // Decode WITHOUT spotlight enrichment — see the batched
                // enrichment below.
                return snap.documents.compactMap {
                    try? decodeUserProfileRaw(documentID: $0.documentID, data: $0.data())
                }
            }
        }
        var out: [UserProfile] = []
        for await chunkProfiles in group { out += chunkProfiles }
        return out
    }

    // ONE catalog round trip covering every profile's spotlights combined.
    // `decodeUserProfile` used to call `enrichSpotlights` per document, inside
    // the loop — so 100 follows meant 100 sequential `CatalogCache.metadata`
    // calls, each its own `whereField(documentID, in:)` query. That was the
    // single biggest cost inside `getFriendsSpotlightsToday`.
    let allIds = raw
        .flatMap { $0.spotlightTracks.compactMap(\.catalogId) }
        .filter { !$0.isEmpty }
    guard !allIds.isEmpty else { return raw }
    let meta = await CatalogCache.shared.metadata(for: allIds)
    return raw.map { profile in
        var copy = profile
        copy.spotlightTracks = profile.spotlightTracks.map { track in
            track.merged(withCatalog: track.catalogId.flatMap { meta[$0] })
        }
        return copy
    }
}

/// Shared decode path for `getUserProfile`/`getUserProfiles` — back-fills
/// fields that JS-created documents may omit, then overlays catalog metadata
/// onto the embedded `spotlightTracks[]` (slim event entries) so the
/// Profile/other-profile spotlight carousel renders.
private func decodeUserProfile(documentID: String, data rawData: [String: Any]) async throws -> UserProfile {
    var profile = try decodeUserProfileRaw(documentID: documentID, data: rawData)
    profile.spotlightTracks = await enrichSpotlights(profile.spotlightTracks)
    return profile
}

/// The synchronous half of `decodeUserProfile` — back-fills fields that
/// JS-created documents may omit, then decodes. Deliberately does NOT enrich
/// spotlights: `getUserProfiles` batches that across every profile at once
/// instead of paying a catalog round trip per document.
private func decodeUserProfileRaw(documentID: String, data rawData: [String: Any]) throws -> UserProfile {
    var data = rawData
    if (data["uid"] as? String) == nil    { data["uid"] = documentID }
    if data["bio"] == nil                 { data["bio"] = "" }
    if data["spotlightTracks"] == nil     { data["spotlightTracks"] = [] as [Any] }
    if data["lastActive"] == nil          { data["lastActive"] = 0.0 }
    if data["createdAt"] == nil           { data["createdAt"] = 0.0 }
    if data["updatedAt"] == nil           { data["updatedAt"] = 0.0 }
    return try Firestore.Decoder().decode(UserProfile.self, from: data)
}

func updateUserProfile(uid: String, fields: [String: Any]) async throws {
    try await usersCollection.document(uid).updateData(fields)
}

/// Slim spotlight event entry — metadata lives in the catalog (single source
/// of truth) and is overlaid on read. Store only catalogId + event data.
private func slimSpotlightData(_ track: SpotlightTrack) -> [String: Any] {
    var data: [String: Any] = [
        "trackId":   track.trackId,
        "spotlitAt": track.spotlitAt,
    ]
    if let catalogId = track.catalogId { data["catalogId"] = catalogId }
    if let service = track.sourceService { data["sourceService"] = service.rawValue }
    return data
}

func updateSpotlightTracks(uid: String, tracks: [SpotlightTrack]) async throws {
    let encoded = tracks.map(slimSpotlightData)
    try await usersCollection.document(uid).updateData(["spotlightTracks": encoded])
}

/// Atomically updates `spotlightTracks[]` on the user doc AND appends to the
/// permanent `spotlight_history` subcollection. Matches the RN `addSpotlightTrack`.
///
/// The history doc is keyed `{trackId}_{dateKey}` rather than bare `trackId` —
/// re-spotlighting the same track on a *later* day is a deliberate
/// "reminding people about this song again" action and gets its own
/// permanent entry, while re-adding/updating within the *same* day still
/// overwrites in place (no duplicate card for one day).
func addSpotlightTrackBatch(uid: String, spotlight: SpotlightTrack, newActiveList: [SpotlightTrack]) async throws {
    let db = Firestore.firestore()
    let userRef    = usersCollection.document(uid)
    let historyId  = "\(spotlight.trackId)_\(dateKey(epochMs: spotlight.spotlitAt))"
    let historyRef = usersCollection.document(uid)
        .collection("spotlight_history").document(historyId)
    let encoded    = newActiveList.map(slimSpotlightData)
    let spotData   = slimSpotlightData(spotlight)
    let batch      = db.batch()
    batch.updateData(
        ["spotlightTracks": encoded, "updatedAt": Date().timeIntervalSince1970 * 1000],
        forDocument: userRef
    )
    batch.setData(spotData, forDocument: historyRef)
    try await batch.commit()
}

func getSpotlightHistory(uid: String) async throws -> [SpotlightTrack] {
    let snap = try await usersCollection.document(uid)
        .collection("spotlight_history")
        .getDocuments()
    let tracks = snap.documents.compactMap {
        try? Firestore.Decoder().decode(SpotlightTrack.self, from: $0.data())
    }
    return await enrichSpotlights(tracks)
}

/// Overlays catalog metadata onto spotlight tracks built from slim event docs
/// (embedded `spotlightTracks[]` or `spotlight_history`). The catalog is the
/// single source of truth; joins through `CatalogCache`. Tracks with no
/// `catalogId` (or a missing catalog row) keep whatever they carried.
func enrichSpotlights(_ tracks: [SpotlightTrack]) async -> [SpotlightTrack] {
    let ids = tracks.compactMap(\.catalogId).filter { !$0.isEmpty }
    guard !ids.isEmpty else { return tracks }
    let meta = await CatalogCache.shared.metadata(for: ids)
    return tracks.map { $0.merged(withCatalog: $0.catalogId.flatMap { meta[$0] }) }
}

/// Today's spotlight picks from people the given user follows — a friend's
/// deliberate "this is the one" pick, not just any recent play. Powers
/// Home's "Friends' Spotlights" rail.
///
/// Reuses `getUserProfiles(uids:)` — its decode path (`decodeUserProfile`)
/// already overlays catalog metadata onto each profile's `spotlightTracks[]`
/// via `enrichSpotlights`, so nothing further needs enriching here.
func getFriendsSpotlightsToday(followingUids: [String]) async throws -> [FriendSpotlight] {
    guard !followingUids.isEmpty else { return [] }
    let profiles = await UserProfileCache.shared.profiles(uids: followingUids)
    let todayKey = dateKey(epochMs: Date().timeIntervalSince1970 * 1000)
    let picks = profiles.flatMap { profile in
        profile.spotlightTracks
            .filter { dateKey(epochMs: $0.spotlitAt) == todayKey }
            .map { FriendSpotlight(user: profile, track: $0) }
    }
    return picks.sorted { $0.track.spotlitAt > $1.track.spotlitAt }
}

/// Persists which music service the user has linked. `nil` clears the field
/// entirely (via `FieldValue.delete()`, not a written null) so a missing
/// `activeService` unambiguously means "no service linked" — `UserProfile`'s
/// `decodeIfPresent` already reads a missing field as `nil`.
func setActiveService(uid: String, service: MusicServiceType?) async throws {
    if let service {
        try await usersCollection.document(uid).updateData(["activeService": service.rawValue])
    } else {
        try await usersCollection.document(uid).updateData(["activeService": FieldValue.delete()])
    }
}

func searchUsers(query: String, limit: Int = 20) async throws -> [UserProfile] {
    let lower = query.lowercased().trimmingCharacters(in: .whitespaces)
    guard !lower.isEmpty else { return [] }
    let snap = try await usersCollection
        .whereField("usernameLower", isGreaterThanOrEqualTo: lower)
        .whereField("usernameLower", isLessThan: lower + "~")
        .limit(to: limit)
        .getDocuments()
    return snap.documents.compactMap { doc in
        var data = doc.data()
        if (data["uid"] as? String) == nil { data["uid"] = doc.documentID }
        if data["bio"]             == nil  { data["bio"] = "" }
        if data["spotlightTracks"] == nil  { data["spotlightTracks"] = [] as [Any] }
        if data["lastActive"]      == nil  { data["lastActive"] = 0.0 }
        if data["createdAt"]       == nil  { data["createdAt"] = 0.0 }
        if data["updatedAt"]       == nil  { data["updatedAt"] = 0.0 }
        return try? Firestore.Decoder().decode(UserProfile.self, from: data)
    }
}

/// Cheap "people you may know" seed for Search's browse state — newest
/// members, excluding the caller and anyone already followed.
///
/// Deliberately NOT a true mutual-follows suggestion (that needs either a
/// server-side aggregation or an N+1 client-side fan-out across every
/// followed user's own follow list — expensive, and this app has enough
/// documented history this session of exactly that kind of query being the
/// actual root cause of a "feels slow" complaint elsewhere). One query,
/// ordered by `createdAt` descending with a small buffer over `limit` to
/// absorb the client-side exclusion filter.
func getSuggestedUsers(excluding excludedUids: Set<String>, limit: Int = 8) async throws -> [UserProfile] {
    let snap = try await usersCollection
        .order(by: "createdAt", descending: true)
        .limit(to: limit + excludedUids.count + 5)
        .getDocuments()
    var out: [UserProfile] = []
    for doc in snap.documents {
        guard !excludedUids.contains(doc.documentID) else { continue }
        if let profile = try? await decodeUserProfile(documentID: doc.documentID, data: doc.data()) {
            out.append(profile)
            if out.count == limit { break }
        }
    }
    return out
}
