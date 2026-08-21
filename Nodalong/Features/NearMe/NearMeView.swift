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
                        // The park needs no location fix — only the users
                        // do. Render it straight away and let avatars arrive
                        // once the geohash resolves, rather than showing a
                        // spinner for the whole tab while CoreLocation works.
                        usersContent()
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
            SocialCache.shared.prefetch(uids: nearMeVM.nearbyUsers.map(\.uid), viewerUid: uid)
        }
        .onChange(of: locationService.geohash) { _, geohash in
            guard let geohash, let uid = authVM.currentUser?.uid else { return }
            Task {
                try? await updateUserLocation(uid: uid, geohash: geohash)
                await nearMeVM.load(geohash: geohash, excludeUid: uid)
                // Also warm here, not just in `.task` — when the tab is
                // opened before location resolves, THIS is the path that
                // actually runs the load.
                SocialCache.shared.prefetch(uids: nearMeVM.nearbyUsers.map(\.uid), viewerUid: uid)
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
    private func usersContent() -> some View {
        // The park renders IMMEDIATELY and unconditionally.
        //
        // `ParkBackgroundView` is procedural — a seeded `Canvas`, no network,
        // no dependency on `nearbyUsers` — so gating it behind the users
        // fetch was never necessary. Previously a full-screen `ProgressView`
        // replaced the entire canvas, park included, which is exactly the
        // loading wheel seen on first navigation to this tab. Now the park is
        // there on the first frame and avatars populate into it as the fetch
        // lands; every transient state is an overlay ON TOP of the park
        // rather than a replacement for it.
        //
        // VStack lets the canvas shrink to fill exactly what's left once the
        // native mini-player accessory reserves its own space —
        // MainTabView's `.tabViewBottomAccessory` already auto-insets the
        // safe area here, so no manual clearance spacer is needed.
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
            .overlay(canvasStateOverlay)
            .shadow(color: .black.opacity(0.35), radius: 16, y: 4)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
    }

    /// Transient states, drawn over the park instead of replacing it. Only
    /// ever shown when there is genuinely nothing on the map yet — once
    /// avatars exist, a background refresh is silent.
    @ViewBuilder
    private var canvasStateOverlay: some View {
        // Three genuinely different states, and conflating the last two is
        // what caused the "No listeners nearby" regression: an empty
        // `nearbyUsers` means nothing on its own until a fetch has actually
        // been ATTEMPTED. `.task` returns early while `locationService.geohash`
        // is still nil, so `load()` never runs, `isLoading` stays false, and
        // the empty state would otherwise assert there's nobody around before
        // having looked at all.
        if let err = nearMeVM.errorMessage, nearMeVM.nearbyUsers.isEmpty {
            stateCard {
                Text(err)
                    .font(Font.nodalong.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.nodalong.textOnAccent.opacity(0.85))
            }
        } else if nearMeVM.nearbyUsers.isEmpty {
            if locationService.geohash == nil {
                busyCard("Finding your location…")
            } else if nearMeVM.isLoading || !nearMeVM.hasLoaded {
                busyCard("Looking for listeners…")
            } else {
                // Only now is this claim actually true.
                stateCard {
                    VStack(spacing: 8) {
                        Image(systemName: "location.fill")
                            .font(Font.nodalong.title3)
                            .foregroundStyle(Color.nodalong.textOnAccent.opacity(0.85))
                        Text("No listeners within \(Int(nearMeVM.radiusKm)) km")
                            .font(Font.nodalong.subheadline)
                            .foregroundStyle(Color.nodalong.textOnAccent.opacity(0.85))
                    }
                }
            }
        }
    }

    /// Non-blocking "still working" pill. Small and over the park, so it
    /// reads as progress rather than replacing the map the way the old
    /// full-screen `ProgressView` did.
    private func busyCard(_ label: String) -> some View {
        stateCard {
            VStack(spacing: 10) {
                ProgressView()
                    .tint(Color.nodalong.textOnAccent)
                Text(label)
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textOnAccent.opacity(0.85))
            }
        }
    }

    /// Legible pill over the park — the park is a mid-green photo-ish
    /// backdrop, so plain text on it reads poorly at any single fixed colour.
    private func stateCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
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
