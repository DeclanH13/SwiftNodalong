import Foundation
import FirebaseCore
import FirebaseDatabase
import NodalongKit

/// General per-user "currently playing" presence, backed by Firebase
/// **Realtime Database** at `users_live/{uid}/nowPlaying`. Generalizes
/// `PartyLiveService`'s host now-playing broadcast to every user — solo
/// playback is, conceptually, a live party of one (see `UserNowPlaying`).
///
/// Same setup gate as `PartyLiveService`: if RTDB isn't provisioned
/// (`DATABASE_URL` absent from `GoogleService-Info.plist`), `isAvailable` is
/// `false` and every call is a safe no-op.
///
/// One instance shared app-wide (`NowPlayingBroadcastService` owns it for
/// writing; `NearMeUserSheet` creates its own for reading — RTDB observation
/// handles are cheap and scoped to the sheet's lifetime).
///
/// `@unchecked Sendable`: `HomeViewModel.loadLiveNow` fans out concurrent
/// `getNowPlayingOnce` calls (one per followed uid) across a `TaskGroup`,
/// which requires this. Safe because `getNowPlayingOnce` is read-only and
/// never touches `observations` (the only mutable state here) — every
/// mutation of `observations` happens via `observeNowPlaying`/`detachAll`,
/// both already only ever called from MainActor contexts in this app.
final class UserPresenceService: @unchecked Sendable {
    private let root: DatabaseReference?
    private var observations: [(ref: DatabaseReference, handle: DatabaseHandle)] = []

    var isAvailable: Bool { root != nil }

    init() {
        if FirebaseApp.app()?.options.databaseURL != nil {
            root = Database.database().reference()
        } else {
            root = nil
        }
    }

    private func nowPlayingRef(_ uid: String) -> DatabaseReference? {
        root?.child("users_live").child(uid).child("nowPlaying")
    }

    /// Writes this device's now-playing state and arms `onDisconnect` cleanup
    /// so a killed app doesn't leave a stale "still playing" ghost entry.
    ///
    /// `positionMs` + `updatedAt` (a **server-clock** timestamp from `ServerClock`)
    /// let a nearby user "tune in" and align to this device's position.
    func broadcastNowPlaying(uid: String, catalogId: String, positionMs: Int, isPlaying: Bool, updatedAt: Double, isPreviewPlayback: Bool) {
        guard let ref = nowPlayingRef(uid) else { return }
        ref.setValue([
            "catalogId":         catalogId,
            "positionMs":        positionMs,
            "isPlaying":         isPlaying,
            "updatedAt":         updatedAt,
            "isPreviewPlayback": isPreviewPlayback,
        ])
        ref.onDisconnectRemoveValue()
    }

    /// Clears this device's now-playing state (playback stopped entirely).
    func clearNowPlaying(uid: String) {
        guard let ref = nowPlayingRef(uid) else { return }
        ref.cancelDisconnectOperations()
        ref.removeValue()
    }

    /// Observes a single uid's now-playing state. Callback fires on the main
    /// queue (RTDB default). Handle is tracked and removed by `detachAll()`.
    func observeNowPlaying(uid: String, onChange: @escaping (UserNowPlaying?) -> Void) {
        guard let ref = nowPlayingRef(uid) else { onChange(nil); return }
        let handle = ref.observe(.value) { snap in
            guard let dict = snap.value as? [String: Any],
                  let catalogId = dict["catalogId"] as? String, !catalogId.isEmpty else {
                onChange(nil); return
            }
            onChange(UserNowPlaying(
                catalogId:         catalogId,
                positionMs:        dict["positionMs"] as? Int,
                isPlaying:         dict["isPlaying"] as? Bool ?? false,
                updatedAt:         dict["updatedAt"] as? Double ?? 0,
                isPreviewPlayback: dict["isPreviewPlayback"] as? Bool ?? false
            ))
        }
        observations.append((ref, handle))
    }

    /// One-time read of a single uid's now-playing state — no ongoing
    /// observer, unlike `observeNowPlaying`. Used for a one-shot check like
    /// Home's "Live Now" section, which follows the app's load-once/
    /// pull-to-refresh convention rather than a continuously-live feed.
    func getNowPlayingOnce(uid: String) async -> UserNowPlaying? {
        guard let ref = nowPlayingRef(uid) else { return nil }
        guard let snap = try? await ref.getData(),
              let dict = snap.value as? [String: Any],
              let catalogId = dict["catalogId"] as? String, !catalogId.isEmpty else {
            return nil
        }
        return UserNowPlaying(
            catalogId:         catalogId,
            positionMs:        dict["positionMs"] as? Int,
            isPlaying:         dict["isPlaying"] as? Bool ?? false,
            updatedAt:         dict["updatedAt"] as? Double ?? 0,
            isPreviewPlayback: dict["isPreviewPlayback"] as? Bool ?? false
        )
    }

    /// Removes all observers. Callers that create their own instance for
    /// reading (e.g. `NearMeUserSheet`) MUST call this on dismiss/disappear.
    func detachAll() {
        for (ref, handle) in observations { ref.removeObserver(withHandle: handle) }
        observations.removeAll()
    }
}
