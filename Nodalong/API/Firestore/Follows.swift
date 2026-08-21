import FirebaseFirestore

private let db = Firestore.firestore()

// MARK: - Subcollection paths

private func followingRef(uid: String) -> CollectionReference {
    db.collection("users").document(uid).collection("following")
}

private func followersRef(uid: String) -> CollectionReference {
    db.collection("users").document(uid).collection("followers")
}

// MARK: - Follow / Unfollow

/// Atomically writes to both users' subcollections, matching the RN social.ts implementation.
func followUser(myUid: String, myUsername: String, targetUid: String, targetUsername: String) async throws {
    let now = Date().timeIntervalSince1970 * 1000
    let batch = db.batch()
    batch.setData(
        ["followedAt": now, "username": targetUsername],
        forDocument: followingRef(uid: myUid).document(targetUid)
    )
    batch.setData(
        ["followedAt": now, "username": myUsername],
        forDocument: followersRef(uid: targetUid).document(myUid)
    )
    try await batch.commit()
    // Invalidate here (not at each of the ~4 call sites) so a follow change
    // is guaranteed to be picked up by the next Home/Feed load regardless of
    // which screen triggered it.
    await FollowingCache.shared.invalidate()
    // Both parties: the target's follower count and `isFollowing` change,
    // and BOTH users' follower/following lists do. Done here at the API
    // layer rather than at each call site so a follow toggle from anywhere
    // in the app can't leave a stale count or button state behind.
    await SocialCache.shared.invalidate(uid: myUid)
    await SocialCache.shared.invalidate(uid: targetUid)
}

/// Atomically removes from both users' subcollections.
func unfollowUser(myUid: String, targetUid: String) async throws {
    let batch = db.batch()
    batch.deleteDocument(followingRef(uid: myUid).document(targetUid))
    batch.deleteDocument(followersRef(uid: targetUid).document(myUid))
    try await batch.commit()
    await FollowingCache.shared.invalidate()
    // Both parties: the target's follower count and `isFollowing` change,
    // and BOTH users' follower/following lists do. Done here at the API
    // layer rather than at each call site so a follow toggle from anywhere
    // in the app can't leave a stale count or button state behind.
    await SocialCache.shared.invalidate(uid: myUid)
    await SocialCache.shared.invalidate(uid: targetUid)
}

// MARK: - Queries

func isFollowing(myUid: String, targetUid: String) async throws -> Bool {
    let snap = try await followingRef(uid: myUid).document(targetUid).getDocument()
    return snap.exists
}

/// Returns (uid, username) pairs for all users that `uid` follows.
func getFollowedEntries(uid: String) async throws -> [(uid: String, username: String)] {
    let snap = try await followingRef(uid: uid).getDocuments()
    return snap.documents.map { (uid: $0.documentID, username: $0.data()["username"] as? String ?? "") }
}

func getFollowerCount(uid: String) async throws -> Int {
    let snap = try await followersRef(uid: uid).getDocuments()
    return snap.documents.count
}

func getFollowingCount(uid: String) async throws -> Int {
    let snap = try await followingRef(uid: uid).getDocuments()
    return snap.documents.count
}

func getFollowersList(uid: String) async throws -> [(uid: String, username: String)] {
    let snap = try await followersRef(uid: uid).getDocuments()
    return snap.documents.map { (uid: $0.documentID, username: $0.data()["username"] as? String ?? "") }
}

func getFollowingList(uid: String) async throws -> [(uid: String, username: String)] {
    return try await getFollowedEntries(uid: uid)
}
