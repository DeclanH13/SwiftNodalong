import SwiftUI
import MusicKit

/// View modifier that surfaces playback errors from `PlayerViewModel` as a
/// system alert, and offers a one-tap Apple Music subscribe path when the
/// user is eligible.
///
/// Attach to any view in the player-touching hierarchy with
/// `.playbackErrorAlert()`. Currently applied to `MiniPlayerBar` and
/// `NowPlayingView` so the alert is reachable from any tab and from the
/// expanded player cover.
///
/// The alert binds to `playerVM.trackUnavailable`. `PlayerViewModel` flips
/// it to `true` whenever a play attempt fails (typically: user has no Apple
/// Music subscription and tried to stream a full track). Dismissing the
/// alert flips it back to `false` automatically.
///
/// Subscription offers are rendered by Apple's first-party
/// `.musicSubscriptionOffer(...)` — no custom sign-up UI.
struct PlaybackErrorAlert: ViewModifier {
    @EnvironmentObject private var playerVM:     PlayerViewModel
    @EnvironmentObject private var musicService: AppleMusicService

    /// Drives the system Apple Music subscription offer sheet. Flipped to
    /// `true` from the alert's "Subscribe" button.
    @State private var showSubscriptionOffer = false

    func body(content: Content) -> some View {
        content
            .alert(
                alertTitle,
                isPresented: $playerVM.trackUnavailable
            ) {
                if musicService.canBecomeSubscriber {
                    Button("Subscribe to Apple Music") {
                        showSubscriptionOffer = true
                    }
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
            .musicSubscriptionOffer(isPresented: $showSubscriptionOffer)
    }

    /// Alert title — adapts copy based on whether subscribing is even an
    /// option in the user's region. Only offers the Apple Music subscribe
    /// path when Apple Music is actually the service that was active and
    /// failed — showing it while Spotify was active would be misleading.
    private var alertTitle: String {
        (playerVM.activeService == .appleMusic && musicService.canBecomeSubscriber)
            ? "Subscription required"
            : "Track unavailable"
    }

    /// Alert message — same adaptive logic as the title. Keep this in sync
    /// with the title; together they shape the user's mental model of the
    /// failure mode. Appends the actual underlying error (when known) so a
    /// user can read/report the real cause without an attached debugger —
    /// this was a real gap on first on-device test, where every failure
    /// (regardless of active service) showed the same generic Apple Music
    /// copy even when Spotify was the one that actually failed.
    private var alertMessage: String {
        let base: String
        if playerVM.activeService == .appleMusic {
            base = musicService.canBecomeSubscriber
                ? "Subscribe to Apple Music to play full tracks in Nodalong."
                : "This track can't be played right now. Check your Apple Music access in Settings."
        } else {
            base = "This track can't be played via Spotify right now."
        }
        guard let detail = playerVM.lastPlaybackErrorDetail, !detail.isEmpty else { return base }
        return base + "\n\n(\(detail))"
    }
}

extension View {
    /// Sugar for `.modifier(PlaybackErrorAlert())`.
    /// See `PlaybackErrorAlert` for the behavioural contract.
    func playbackErrorAlert() -> some View {
        modifier(PlaybackErrorAlert())
    }
}

#if DEBUG
/// Previews the alert in its triggered state (`trackUnavailable = true`).
/// Use interactive mode in Xcode to dismiss the alert and tap "Play" on the
/// mock mini player to re-trigger it.
#Preview("Playback error – alert visible") {
    Color.nodalong.bgBase
        .ignoresSafeArea()
        .overlay {
            VStack {
                Spacer()
                MiniPlayerBar()
                    .frame(height: 62)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 100)
            }
        }
        .playbackErrorAlert()
        .withPreviewEnvironment()
        .environmentObject(PlayerViewModel.mockPreviewError)
}
#endif
