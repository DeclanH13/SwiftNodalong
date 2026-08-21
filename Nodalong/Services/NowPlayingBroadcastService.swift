import Foundation
import Combine
import NodalongKit

/// Bridges `PlayerViewModel`'s already-public playback state to
/// `UserPresenceService`, so any playing device shows up in nearby users'
/// "Now Playing" — without adding any party/social awareness to
/// `PlayerViewModel` itself (kept generic, exactly as before).
///
/// Broadcasts include `positionMs` + a `ServerClock` timestamp so a nearby user
/// can **tune in** and align to this device's position. A lightweight keepalive
/// re-broadcasts position while playing (bounds staleness for a late tune-in and
/// catches seeks); it only ticks while playing, so it's nowhere near the cost of
/// the retired 60fps NearMe timer.
///
/// Instantiated once app-wide (`NodalongApp`) and started once auth is ready
/// (`ContentView`). Only broadcasts while genuinely `isPlaying == true` — a
/// paused-but-loaded track reads as "not currently playing" — and never while
/// this device is itself *following* someone (that playback is really their
/// timeline; rebroadcasting it would create tune-in chains).
@MainActor
final class NowPlayingBroadcastService: ObservableObject {
    private let presence = UserPresenceService()
    private var cancellables = Set<AnyCancellable>()
    private var keepaliveTimer: Timer?
    private weak var playerVM: PlayerViewModel?
    private weak var authVM: FirebaseAuthViewModel?
    private var started = false

    /// Interval for the position keepalive. Coarse on purpose — position
    /// extrapolates exactly at rate 1.0, so this only exists to catch seeks and
    /// bound staleness for late joiners.
    private static let keepaliveInterval: TimeInterval = 12

    /// Subscribes to `playerVM`'s playback state and mirrors it to RTDB under
    /// `authVM`'s current uid. Safe to call once; subsequent calls no-op.
    func start(playerVM: PlayerViewModel, authVM: FirebaseAuthViewModel) {
        guard !started else { return }
        started = true
        self.playerVM = playerVM
        self.authVM = authVM

        // React immediately to track/play-state changes (incl. clearing on stop).
        Publishers.CombineLatest(playerVM.$nowPlaying, playerVM.$isPlaying)
            .sink { [weak self] _, _ in self?.broadcast() }
            .store(in: &cancellables)

        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: Self.keepaliveInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let pvm = self.playerVM,
                      pvm.isPlaying, pvm.followContext == nil else { return }
                self.broadcast()
            }
        }
    }

    /// Writes or clears this device's now-playing presence from current state.
    private func broadcast() {
        guard let playerVM, let uid = authVM?.currentUser?.uid else { return }
        if playerVM.isPlaying, playerVM.followContext == nil,
           let catalogId = playerVM.nowPlaying?.catalogId, !catalogId.isEmpty {
            presence.broadcastNowPlaying(
                uid: uid,
                catalogId: catalogId,
                positionMs: playerVM.currentPositionMs,
                isPlaying: true,
                updatedAt: ServerClock.shared.serverNowMs(),
                isPreviewPlayback: playerVM.isPreviewPlayback
            )
        } else {
            presence.clearNowPlaying(uid: uid)
        }
    }
}
