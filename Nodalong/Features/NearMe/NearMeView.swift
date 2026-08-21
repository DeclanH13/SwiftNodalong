import SwiftUI
import UIKit
import NodalongKit

/// Near Me tab — animated canvas of nearby users' sprite avatars.
///
/// Loads users within a configurable radius (slider, 5–25 km) and lays them
/// out on a canvas. Tapping an avatar opens `NearMeUserSheet` with that
/// user's profile + featured track.
///
/// Owns the radius slider; the actual avatar layout lives in
/// `NearMeCanvasView`; the per-user sheet in `NearMeUserSheet`.
struct NearMeView: View {
    @Environment(FirebaseAuthViewModel.self) private var authVM
    @EnvironmentObject private var locationService: LocationService
    @EnvironmentObject private var nearMeVM:        NearMeViewModel
    // Added so this tab can resolve/render `ArtistResult`/`AlbumResult`
    // destinations landed here from `router.dismissThenPush` (NowPlayingView's
    // artist/album tap, or PartyView's) — a push always targets whichever tab
    // happens to be selected, and this tab previously had none of the
    // services or registrations needed to handle one.
    @EnvironmentObject private var playerVM:        PlayerViewModel
    @EnvironmentObject private var musicService:    AppleMusicService
    @EnvironmentObject private var spotifyService:  SpotifyMusicService
    /// Owns this tab's own `NavigationPath` (`router.nearMePath`) — see
    /// `AppRouter`'s doc comment. This tab had no programmatic path at all
    /// before this.
    @EnvironmentObject private var router:          AppRouter

    private var activeService: any MusicService {
        activeMusicService(playerVM: playerVM, apple: musicService, spotify: spotifyService)
    }

    @State private var selectedUser: UserProfile? = nil
    @State private var radiusDraft:  Double       = 10.0

    var body: some View {
        NavigationStack(path: $router.nearMePath) {
            VStack(spacing: 0) {
                // Radius control lives at the top of the content area —
                // previously this was a `.toolbar(.bottomBar)` item, which
                // sat behind the MiniPlayerBar + tab bar and was unreachable.
                // Top placement is always visible and tappable.
                if case .authorizedWhenInUse = locationService.authorizationStatus {
                    radiusBar
                } else if case .authorizedAlways = locationService.authorizationStatus {
                    radiusBar
                }

                Group {
                    switch locationService.authorizationStatus {
                    case .notDetermined:
                        requestState
                    case .denied, .restricted:
                        deniedState
                    default:
                        if let geohash = locationService.geohash {
                            usersContent(geohash: geohash)
                        } else {
                            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
            .background(Color.nodalong.bgBase)
            .navigationTitle("Near Me")
            .navigationBarTitleDisplayMode(.inline)
            // Both destinations a follow-list flow needs, registered together on
            // every stack that can host it.
            //
            // `FollowListTarget` is pushed with a plain `NavigationLink(value:)`,
            // NOT `.navigationDestination(item:)`. An item-based push re-presents
            // itself whenever something is pushed ON TOP of it (the bound item is
            // still non-nil), which is exactly the bug Round 9.9 hit with
            // `discographyGridTab` — and it's what made tapping a NAME inside a
            // follow list show a second copy of the follow list instead of that
            // person's profile.
            //
            // `UserProfile` has to be here too: `FollowListView`'s rows push one, so
            // without it a row tap has no destination on this stack. Every closure
            // below builds purely from the pushed value, so the duplicate
            // registrations across stacks are behaviourally identical — which is the
            // property that actually makes this safe, not uniqueness.
            .navigationDestination(for: FollowListTarget.self) { t in
                FollowListView(uid: t.uid, mode: t.mode, username: t.username)
            }
            .navigationDestination(for: UserProfile.self) { user in
                UserProfileView(user: user)
            }
            .navigationDestination(for: ArtistResult.self) { ArtistDetailSearchView(artist: $0) }
            .navigationDestination(for: AlbumResult.self)  { AlbumDetailSearchView(album: $0) }
            .navigationDestination(for: Playlist.self)     { PlaylistDetailView(playlist: $0) }
            .navigationDestination(for: PendingArtistResolve.self) { pending in
                ResolvingArtistsView(name: pending.artist) {
                    await resolvePendingArtists(for: pending, playerVM: playerVM, musicService: musicService, activeService: activeService)
                }
            }
            .navigationDestination(for: PendingAlbumResolve.self) { pending in
                ResolvingAlbumView(name: pending.albumName, artistName: pending.artist, artwork: pending.artwork) {
                    await resolvePendingAlbum(for: pending, playerVM: playerVM, musicService: musicService, activeService: activeService)
                }
            }
            .profileEntryPoint()
        }
        // No wrapping `NavigationStack` here anymore, and no
        // `.navigationDestination` — `NearMeUserSheet`'s own "View Profile"
        // now dismisses this sheet and pushes onto `router.nearMePath`
        // instead (which already has `.navigationDestination(for:
        // UserProfile.self)` registered above), so there's nothing left to
        // navigate to from inside the sheet itself. `NearMeUserSheet` was
        // confirmed to use no `.navigationTitle`/`.toolbar` chrome that
        // would have needed a `NavigationStack` ancestor for its own sake.
        .sheet(item: $selectedUser) { user in
            NearMeUserSheet(user: user)
        }
        .task {
            radiusDraft = nearMeVM.radiusKm
            guard let geohash = locationService.geohash,
                  let uid = authVM.currentUser?.uid else { return }
            try? await updateUserLocation(uid: uid, geohash: geohash)
            await nearMeVM.load(geohash: geohash, excludeUid: uid)
        }
        .onChange(of: locationService.geohash) { _, geohash in
            guard let geohash, let uid = authVM.currentUser?.uid else { return }
            Task {
                try? await updateUserLocation(uid: uid, geohash: geohash)
                await nearMeVM.load(geohash: geohash, excludeUid: uid)
            }
        }
    }

    // MARK: - States

    private var requestState: some View {
        VStack(spacing: 20) {
            Image(systemName: "location.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.nodalong.purpleAccent)
            Text("See who's listening nearby")
                .font(Font.nodalong.headline).foregroundStyle(Color.nodalong.textPrimary)
            Text("Nodalong uses your approximate location to show music listeners near you.")
                .font(Font.nodalong.subheadline).foregroundStyle(Color.nodalong.textSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Button("Enable Location") { locationService.requestLocation() }
                .font(Font.nodalong.subheadlineSemibold).foregroundStyle(Color.nodalong.textOnAccent)
                .padding(.vertical, 14).padding(.horizontal, 32)
                .background(Color.nodalong.purpleBold)
                .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deniedState: some View {
        VStack(spacing: 16) {
            Image(systemName: "location.slash.fill")
                .font(.system(size: 48)).foregroundStyle(Color.nodalong.textSecondary)
            Text("Location access denied")
                .font(Font.nodalong.headline).foregroundStyle(Color.nodalong.textPrimary)
            Text("Enable location in Settings → Nodalong → Location")
                .font(Font.nodalong.subheadline).foregroundStyle(Color.nodalong.textSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .foregroundStyle(Color.nodalong.purpleAccent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func usersContent(geohash: String) -> some View {
        if nearMeVM.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = nearMeVM.errorMessage {
            Text(err).foregroundStyle(Color.nodalong.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if nearMeVM.nearbyUsers.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "location.fill")
                    .font(Font.nodalong.largeTitle).foregroundStyle(Color.nodalong.textSecondary)
                Text("No listeners within \(Int(nearMeVM.radiusKm)) km")
                    .font(Font.nodalong.subheadline).foregroundStyle(Color.nodalong.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // VStack lets the canvas shrink to fill exactly what's left once
            // the native mini-player accessory reserves its own space —
            // MainTabView's `.tabViewBottomAccessory` already auto-insets the
            // safe area here (same mechanism as `.safeAreaInset`), so no
            // manual clearance spacer is needed on top of that. (Other tabs
            // still carry a manual 70pt spacer of their own inside a
            // ScrollView, a harmless leftover there since it just adds a bit
            // of extra empty scroll space; here the canvas is a fixed-size,
            // non-scrolling `maxHeight: .infinity` view, so the same spacer
            // was double-reserving space and showing as an oversized gap.)
            VStack(spacing: 0) {
                // Rounded "playfield" container — the canvas lives inside this
                // and nothing else does. Park panning happens inside the clip,
                // so the park never bleeds over the slider or the tab bar.
                NearMeCanvasView(
                    users:          nearMeVM.nearbyUsers,
                    featuredTracks: nearMeVM.featuredTracks,
                    onSelectUser:  { user in selectedUser = user }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Corner.container, style: .continuous)
                        .strokeBorder(Color.nodalong.textPrimary.opacity(0.06), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 16, y: 4)
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
        }
    }

    /// Top-of-content radius control. Always visible, never obstructed by
    /// the tab bar / mini player. `onChange` re-runs the nearby-users fetch
    /// on each step transition.
    private var radiusBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "scope")
                .font(Font.nodalong.captionSemibold)
                .foregroundStyle(Color.nodalong.purpleAccent)
            Slider(value: $radiusDraft, in: 1...50, step: 1)
                .tint(Color.nodalong.purpleAccent)
                .onChange(of: radiusDraft) { _, newVal in
                    nearMeVM.radiusKm = newVal
                    if let geohash = locationService.geohash,
                       let uid = authVM.currentUser?.uid {
                        // forceReload: true — radius change always re-queries
                        // regardless of the hasLoaded guard.
                        Task { await nearMeVM.load(geohash: geohash, excludeUid: uid, forceReload: true) }
                    }
                }
            Text("\(Int(radiusDraft)) km")
                .font(Font.nodalong.captionMedium)
                .foregroundStyle(Color.nodalong.textPrimary)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.nodalong.bgBase)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.nodalong.bgCard)
                .frame(height: 0.5)
        }
    }
}

#if DEBUG
#Preview {
    NearMeView().withPreviewEnvironment()
}
#endif
