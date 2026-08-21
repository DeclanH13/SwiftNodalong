import Foundation
import FirebaseCore
import FirebaseDatabase
import NodalongKit

/// Ephemeral live layer for listening parties, backed by Firebase **Realtime
/// Database** (RTDB) — presence (with `onDisconnect` auto-cleanup) and the
/// host-written now-playing pointer. Durable records (the party doc, the queue,
/// the frozen playlist) live in Firestore; this is only the live, throwaway
/// state.
///
/// **Setup gate:** RTDB requires a `DATABASE_URL` in `GoogleService-Info.plist`
/// (i.e. a Realtime Database instance provisioned in the Firebase console). If
/// it's absent, `isAvailable` is `false` and every call is a safe no-op — the
/// app never crashes; live features just don't function until RTDB is enabled.
///
/// One instance per party session, owned by `ListeningPartyViewModel`, which
/// MUST call `detachAll()` / `leavePresence()` on leave + background (the
/// jetsam guardrail — the app's first realtime surface).
final class PartyLiveService {
    private let root: DatabaseReference?
    private var observations: [(ref: DatabaseReference, handle: DatabaseHandle)] = []
    private var presenceRef: DatabaseReference?

    /// `true` when a Realtime Database instance is configured for this app.
    var isAvailable: Bool { root != nil }

    init() {
        if FirebaseApp.app()?.options.databaseURL != nil {
            root = Database.database().reference()
        } else {
            root = nil
        }
    }

    private func liveRef(_ partyId: String) -> DatabaseReference? {
        root?.child("parties_live").child(partyId)
    }

    // MARK: - Presence

    /// Writes this device's presence and arms `onDisconnect` cleanup so a drop
    /// or force-quit auto-removes it (fixes "party stuck with ghost members").
    func joinPresence(partyId: String, participant: PartyParticipant) {
        guard let ref = liveRef(partyId)?.child("presence").child(participant.id) else { return }
        presenceRef = ref
        ref.setValue([
            "username":    participant.username,
            "avatarEmoji": participant.avatarEmoji as Any,
            "avatarColor": participant.avatarColor as Any,
            "joinedAt":    participant.joinedAt,
            "mode":        participant.mode.rawValue,
        ])
        ref.onDisconnectRemoveValue()
    }

    /// Updates just this device's listen mode (in-room ↔ sync) without disturbing
    /// the rest of its presence node or the armed `onDisconnect` cleanup.
    func updateListenMode(_ mode: PartyListenMode) {
        presenceRef?.child("mode").setValue(mode.rawValue)
    }

    /// Explicitly removes this device's presence (graceful leave).
    func leavePresence() {
        presenceRef?.cancelDisconnectOperations()
        presenceRef?.removeValue()
        presenceRef = nil
    }

    /// Observes the participant set. Callback fires on the main queue (RTDB
    /// default). Handle is tracked and removed by `detachAll()`.
    func observePresence(partyId: String, onChange: @escaping ([PartyParticipant]) -> Void) {
        guard let ref = liveRef(partyId)?.child("presence") else { onChange([]); return }
        let handle = ref.observe(.value) { snap in
            var out: [PartyParticipant] = []
            for case let child as DataSnapshot in snap.children {
                guard let dict = child.value as? [String: Any] else { continue }
                out.append(PartyParticipant(
                    id:          child.key,
                    username:    dict["username"] as? String ?? "",
                    avatarEmoji: dict["avatarEmoji"] as? String,
                    avatarColor: dict["avatarColor"] as? String,
                    joinedAt:    dict["joinedAt"] as? Double ?? 0,
                    mode:        (dict["mode"] as? String).flatMap(PartyListenMode.init) ?? .inRoom
                ))
            }
            onChange(out.sorted { $0.joinedAt < $1.joinedAt })
        }
        observations.append((ref, handle))
    }

    /// Records the host uid in the live node so RTDB rules can gate host-only
    /// writes (`nowPlaying`) — RTDB rules can't read Firestore, so the authority
    /// must be mirrored here. Called by the host on enter.
    func setHost(partyId: String, hostUid: String) {
        liveRef(partyId)?.child("hostUid").setValue(hostUid)
    }

    // MARK: - Now playing (host-written, display-only)

    func writeNowPlaying(partyId: String, _ np: PartyNowPlaying) {
        guard let ref = liveRef(partyId)?.child("nowPlaying") else { return }
        ref.setValue([
            "catalogId":         np.catalogId,
            "positionMs":        np.positionMs as Any,
            "isPlaying":         np.isPlaying,
            "updatedAt":         np.updatedAt,
            "isPreviewPlayback": np.isPreviewPlayback,
        ])
    }

    func observeNowPlaying(partyId: String, onChange: @escaping (PartyNowPlaying?) -> Void) {
        guard let ref = liveRef(partyId)?.child("nowPlaying") else { onChange(nil); return }
        let handle = ref.observe(.value) { snap in
            guard let dict = snap.value as? [String: Any],
                  let catalogId = dict["catalogId"] as? String else { onChange(nil); return }
            onChange(PartyNowPlaying(
                catalogId:         catalogId,
                positionMs:        dict["positionMs"] as? Int,
                isPlaying:         dict["isPlaying"] as? Bool ?? false,
                updatedAt:         dict["updatedAt"] as? Double ?? 0,
                isPreviewPlayback: dict["isPreviewPlayback"] as? Bool ?? false
            ))
        }
        observations.append((ref, handle))
    }

    // MARK: - Teardown

    /// Removes the whole live node (host, on party end).
    func clearLive(partyId: String) {
        liveRef(partyId)?.removeValue()
    }

    /// Removes all observers. MUST be called on leave / `.onDisappear` /
    /// background so no RTDB listener leaks into the background.
    func detachAll() {
        for (ref, handle) in observations { ref.removeObserver(withHandle: handle) }
        observations.removeAll()
    }
}
