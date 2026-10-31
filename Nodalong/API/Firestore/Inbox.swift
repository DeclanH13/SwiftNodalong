import FirebaseFirestore
import NodalongKit

private let db = Firestore.firestore()

private func inboxRef(uid: String) -> CollectionReference {
    db.collection("users").document(uid).collection("inbox")
}

/// Sends a song (with an optional note) to a friend's inbox. The id is
/// deterministic per sender/song/day, so a double-tap or retry overwrites the
/// same document instead of duplicating it. `firestore.rules` only allows the
/// create when the two users follow each other.
func sendSongToInbox(to recipientUid: String, from me: UserProfile, catalogId: String, note: String?) async throws {
    let now = Date().timeIntervalSince1970 * 1000
    var data: [String: Any] = [
        "type": InboxItem.Kind.song.rawValue,
        "fromUid": me.uid,
        "fromUsername": me.username,
        "catalogId": catalogId,
        "createdAt": now,
    ]
    if let e = me.avatarEmoji { data["fromAvatarEmoji"] = e }
    if let c = me.avatarColor { data["fromAvatarColor"] = c }
    if let n = note?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
        data["note"] = String(n.prefix(inboxNoteMaxLength))
    }
    let id = "song_\(me.uid)_\(catalogId)_\(dateKey(epochMs: now))"
    try await inboxRef(uid: recipientUid).document(id).setData(data)
}

/// Invites a friend to contribute to one of your playlists. The id is
/// `invite_{playlistId}` because the playlist rules look this exact document up
/// when the invitee joins (see `acceptPlaylistInvite`).
func sendPlaylistInvite(to recipientUid: String, from me: UserProfile, playlistId: String, playlistTitle: String) async throws {
    var data: [String: Any] = [
        "type": InboxItem.Kind.playlistInvite.rawValue,
        "fromUid": me.uid,
        "fromUsername": me.username,
        "playlistId": playlistId,
        "playlistTitle": playlistTitle,
        "createdAt": Date().timeIntervalSince1970 * 1000,
    ]
    if let e = me.avatarEmoji { data["fromAvatarEmoji"] = e }
    if let c = me.avatarColor { data["fromAvatarColor"] = c }
    try await inboxRef(uid: recipientUid).document("invite_\(playlistId)").setData(data)
}

/// Joins a playlist you were invited to by adding your own uid to
/// `contributorUids` — the rules permit exactly that, and only while the invite
/// document still exists. The invite is removed afterwards.
func acceptPlaylistInvite(playlistId: String, myUid: String) async throws {
    try await db.collection("playlists").document(playlistId)
        .updateData(["contributorUids": FieldValue.arrayUnion([myUid])])
    try? await inboxRef(uid: myUid).document("invite_\(playlistId)").delete()
}

func deleteInboxItem(uid: String, itemId: String) async {
    try? await inboxRef(uid: uid).document(itemId).delete()
}

/// Live listener over the newest 50 items. Single-field ordering, so no index.
func listenToInbox(uid: String, onChange: @escaping ([InboxItem]) -> Void) -> ListenerRegistration {
    inboxRef(uid: uid)
        .order(by: "createdAt", descending: true)
        .limit(to: 50)
        .addSnapshotListener { snap, _ in
            guard let snap else { return }
            onChange(snap.documents.compactMap { InboxItem(id: $0.documentID, data: $0.data()) })
        }
}
