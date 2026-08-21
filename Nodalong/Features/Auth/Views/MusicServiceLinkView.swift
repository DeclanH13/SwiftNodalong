import SwiftUI

/// Onboarding screen presented as a full-screen cover after sign-in when no
/// music service is connected yet.
///
/// Was `AppleMusicLinkView`, then briefly extended for a second (Spotify)
/// service — Spotify support is currently suspended (parked, not deleted;
/// `SpotifyMusicService` and its routing are untouched, just unreached from
/// here), so this is Apple-Music-only again. Dismisses automatically once
/// `connectAppleMusic()` succeeds and calls `setActiveMusicService(...)`,
/// which updates `authVM.profile` and flips `ContentView.shouldShowMusicLink`
/// false.
struct MusicServiceLinkView: View {
    @EnvironmentObject private var musicService: AppleMusicService
    @Environment(FirebaseAuthViewModel.self) private var authVM
    @EnvironmentObject private var playerVM:     PlayerViewModel
    @State private var isRequestingApple = false

    var body: some View {
        ZStack {
            Color.nodalong.bgDeep.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                VStack(spacing: 24) {
                    Image(systemName: "music.note.house.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(Color.nodalong.textOnAccent)
                        .symbolRenderingMode(.hierarchical)

                    VStack(spacing: 12) {
                        Text("Connect a Music Service")
                            .font(Font.nodalong.custom(28, .bold))
                            .foregroundStyle(Color.nodalong.textOnAccent)

                        Text("Nodalong plays tracks through Apple Music and uses your library to power your feed and shelf.")
                            .font(Font.nodalong.subheadline)
                            .foregroundStyle(Color.nodalong.textOnAccent.opacity(0.75))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)

                        // A user who previously denied Apple Music would
                        // otherwise be stuck on a dead retry — MusicKit
                        // silently re-reports `.denied` with no fresh system
                        // prompt. Steer them to Settings instead.
                        if musicService.isDenied {
                            Text("Apple Music access was previously denied. Enable it in Settings.")
                                .font(Font.nodalong.caption)
                                .foregroundStyle(Color.nodalong.gold)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                                .padding(.top, 4)
                        }
                    }
                }

                Spacer()

                VStack(spacing: 12) {
                    Button(action: connectAppleMusic) {
                        HStack(spacing: 9) {
                            if isRequestingApple {
                                ProgressView().tint(.white)
                            } else {
                                AppleMusicIcon(size: 22)
                                Text("Connect Apple Music")
                                    .font(Font.nodalong.headline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.nodalong.appleMusicRed)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                    }
                    .disabled(isRequestingApple || musicService.isDenied)

                    Text("You'll be prompted to allow access.")
                        .font(Font.nodalong.caption)
                        .foregroundStyle(Color.nodalong.textOnAccent.opacity(0.5))
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 56)
            }
        }
    }

    private func connectAppleMusic() {
        guard !isRequestingApple else { return }
        isRequestingApple = true
        Task {
            try? await musicService.authorize()
            if musicService.isAuthenticated, let uid = authVM.currentUser?.uid {
                await setActiveMusicService(.appleMusic, uid: uid, playerVM: playerVM, authVM: authVM)
            }
            isRequestingApple = false
            // This view dismisses reactively once `authVM.profile.activeService`
            // is non-nil (see `ContentView.shouldShowMusicLink`).
        }
    }
}

#if DEBUG
#Preview {
    MusicServiceLinkView().withPreviewEnvironment()
}
#endif
