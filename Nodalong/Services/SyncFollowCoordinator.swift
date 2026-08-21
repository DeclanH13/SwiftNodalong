import Foundation
import Combine
import NodalongKit

/// Bridges a NearMe **"tune in"** (single-song sync) to `PlayerViewModel`'s
/// follow engine, keeping RTDB + `ServerClock` concerns out of the player.
///
/// Owns its own `UserPresenceService` reader so the observation survives the
/// NearMe sheet being dismissed (playback continues via the mini player). It
/// translates each `users_live/{uid}/nowPlaying` update into an extrapolated
/// target position and feeds `PlayerViewModel.applyFollowTimeline`.
///
/// Single-song semantics (per product decision): when the broadcaster changes
/// track or stops, the tune-in ends and the follower returns to idle.
///
/// Instantiated once app-wide (`NodalongApp`), wired to the player once
/// (`configure`), same pattern as `NowPlayingBroadcastService`.
@MainActor
final class SyncFollowCoordinator: ObservableObject {
    private let presence = UserPresenceService()
    private weak var playerVM: PlayerViewModel?
    private var followCancellable: AnyCancellable?

    /// The uid currently tuned into, if any (nil when not following via NearMe).
    @Published private(set) var tunedInUid: String?

    func configure(playerVM: PlayerViewModel) {
        self.playerVM = playerVM
    }

    /// Start a single-song tune-in to `uid`'s current track.
    func tuneIn(uid: String, label: String) {
        guard let playerVM else { return }
        cleanup()
        tunedInUid = uid
        playerVM.beginFollowing(label: label, mode: .singleTrack)
        // Auto-clean when the follow ends from anywhere (mini-player Leave,
        // single-song end inside the engine) — fires immediately with the
        // just-set non-nil context, then again if it flips to nil.
        followCancellable = playerVM.$followContext
            .sink { [weak self] ctx in if ctx == nil { self?.cleanup() } }
        presence.observeNowPlaying(uid: uid) { [weak self] np in
            Task { @MainActor in await self?.handle(np) }
        }
    }

    /// End the tune-in explicitly.
    func stop() {
        playerVM?.stopFollowing()   // → followContext == nil → cleanup via the sink
        cleanup()
    }

    private func handle(_ np: UserNowPlaying?) async {
        guard let playerVM, tunedInUid != nil else { return }
        guard let np, np.isPlaying, !np.catalogId.isEmpty else {
            // Broadcaster stopped playing → end the single-song tune-in.
            playerVM.stopFollowing()
            return
        }
        guard !np.isPreviewPlayback else {
            // Broadcaster dropped to preview mode mid-session (e.g. lost their
            // subscription) — their own playback now cycles every ~30s; end
            // rather than follow that into a broken loop. The pre-tap gate in
            // `NearMeUserSheet` covers the common case; this is defense in depth.
            playerVM.stopFollowing()
            return
        }
        let timeline = SyncTimeline(
            catalogId:       np.catalogId,
            positionMs:      np.positionMs ?? 0,
            isPlaying:       np.isPlaying,
            serverUpdatedAt: np.updatedAt,
            isPreviewPlayback: np.isPreviewPlayback
        )
        let target = timeline.targetPositionMs(serverNowMs: ServerClock.shared.serverNowMs())
        let song = await resolveSong(catalogId: np.catalogId)
        await playerVM.applyFollowTimeline(
            catalogId:        np.catalogId,
            targetPositionMs: target,
            isPlaying:        np.isPlaying,
            song:             song
        )
    }

    /// Resolves a `catalogId` to a playable `Song` via the shared catalog cache.
    private func resolveSong(catalogId: String) async -> Song? {
        let meta = await CatalogCache.shared.metadata(for: [catalogId])
        guard let track = meta[catalogId] else { return nil }
        return Song.from(catalogTrack: track, catalogId: catalogId)
    }

    /// Detaches the RTDB observer + the follow-context watcher. Idempotent.
    private func cleanup() {
        presence.detachAll()
        followCancellable?.cancel()
        followCancellable = nil
        tunedInUid = nil
    }
}
