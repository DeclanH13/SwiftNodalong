import SwiftUI

/// Top-level router — the only view that decides "splash vs. auth stack vs.
/// main app" based on Firebase auth state.
///
/// Also owns cross-cutting side effects that depend on auth: presenting the
/// music-service onboarding cover when neither is connected, kicking off a
/// library sync when access is granted, and refreshing auth state on
/// foreground return so user-made changes in Settings flow through.
struct ContentView: View {
    @Environment(FirebaseAuthViewModel.self) private var authVM
    @EnvironmentObject private var musicService:  AppleMusicService
    @EnvironmentObject private var spotifyService: SpotifyMusicService
    @EnvironmentObject private var syncService:   LibrarySyncService
    @EnvironmentObject private var playerVM:     PlayerViewModel
    @EnvironmentObject private var nowPlayingBroadcast: NowPlayingBroadcastService
    @EnvironmentObject private var syncCoordinator: SyncFollowCoordinator

    /// `true` while the "connect a music service" onboarding cover should be
    /// visible — whenever the user is signed in but has **no service linked**.
    ///
    /// Deliberately reads the persisted `authVM.profile?.activeService`, NOT
    /// either service's raw `isAuthenticated`. MusicKit's OS-level Apple
    /// Music permission has no per-app revoke, so `musicService.isAuthenticated`
    /// silently resurrects to `true` on every relaunch for anyone who has
    /// ever granted it once — using it here would mean a user who disconnected
    /// Apple Music (in favor of Spotify) gets silently re-shown as "connected"
    /// and this cover would never reappear even after a real disconnect.
    /// `activeService` is the single durable source of truth for "linked,"
    /// written only by `setActiveMusicService(...)` from a real user action —
    /// see that function's doc comment. No extra "is profile loaded" guard
    /// needed: `authVM.isInitializing` (gating `MainTabView` itself) already
    /// guarantees `authVM.profile` has been fetched by the time this is read.
    /// Set once the user chooses "Not now" on the music-service onboarding.
    ///
    /// Without this the cover was an inescapable gate: `MusicServiceLinkView`
    /// has a single button that `.disabled(...)`s itself once MusicKit
    /// reports `.denied`, and the cover only dismisses when `activeService`
    /// becomes non-nil. Anyone who tapped "Don't Allow" once — including an
    /// App Review tester, or a tester with no Apple Music subscription — was
    /// locked out of the app entirely, with only a "change it in Settings"
    /// caption. Skipping leaves the app usable (browse, profiles, follows);
    /// Profile → Music Services is the way back in to connect later.
    @AppStorage(skippedMusicLinkKey) private var skippedMusicLink = false

    private var shouldShowMusicLink: Bool {
        authVM.isAuthenticated
            && authVM.profile?.activeService == nil
            && !skippedMusicLink
    }

    /// `true` for a brief guaranteed window right after sign-in/registration
    /// succeeds, before `MainTabView` is ever constructed.
    ///
    /// `authVM.isInitializing` only covers cold launch (by design — see its
    /// own doc comment); the sign-in/register transition has never had any
    /// bridge at all, so `isAuthenticated` flipping true went straight into
    /// constructing a brand-new `MainTabView` with nothing shown in between.
    /// `MainTabView.init()` does real one-time work on its very first
    /// construction in a process (UIKit chrome setup, five `@StateObject`s,
    /// then `TabView` layout + `FeedView`'s async load kicking off) — with no
    /// bridge, any hitch there shows the window's raw background (`bgBase`)
    /// and nothing else: the reported "blank purple screen" on account
    /// creation and login. Reusing `LaunchSplash` here for a fixed ~400ms
    /// floor gives that work a head start before the user ever sees it,
    /// mirroring how cold launch already avoids the same problem.
    ///
    /// Driven by `authVM.postAuthBridgeToken`, NOT `authVM.isAuthenticated` —
    /// the latter also flips true on a cold launch (once the profile lands),
    /// which used to eat this same 400ms on every launch, including the new
    /// cached-profile fast path where it's pure waste. `postAuthBridgeToken`
    /// only increments for a genuine interactive sign-in/register.
    @State private var showPostAuthBridge = false

    /// Backs the music-service onboarding cover.
    ///
    /// Deliberately a real `@State` binding kept in sync with
    /// `shouldShowMusicLink`, NOT `.constant(shouldShowMusicLink)` — a
    /// `fullScreenCover` bound to a constant can never be written back to by
    /// SwiftUI's own presentation machinery, so its internal presentation
    /// state and the value it's reading can desync. `shouldShowMusicLink`
    /// derives from `authVM.profile?.activeService`, which transiently
    /// changes during profile load/refresh, making that desync reachable —
    /// a known cause of covers that present blank or fail to dismiss.
    @State private var showMusicLink = false

    var body: some View {
        Group {
            if authVM.isInitializing || showPostAuthBridge {
                LaunchSplash()
            } else if authVM.isAuthenticated {
                MainTabView()
            } else {
                NavigationStack {
                    SplashView()
                        .navigationDestination(for: AuthRoute.self) { route in
                            switch route {
                            case .login:          LoginView()
                            case .register:       RegisterView()
                            case .forgotPassword: ForgotPasswordView()
                            }
                        }
                }
            }
        }
        .onChange(of: authVM.postAuthBridgeToken) { _, token in
            guard token > 0, authVM.isAuthenticated else { return }
            showPostAuthBridge = true
            Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                showPostAuthBridge = false
            }
        }
        // Present the music-service onboarding as a full-screen cover the
        // moment the user is signed in with no service linked. Dismisses
        // itself once `MusicServiceLinkView` calls `setActiveMusicService(...)`
        // on a successful connect, which updates `authVM.profile` and flips
        // `shouldShowMusicLink` false.
        .onChange(of: shouldShowMusicLink) { _, shouldShow in
            // One-way sync: the derived condition drives the flag, and the
            // cover dismisses itself by flipping `showMusicLink` when the
            // condition clears. See `showMusicLink`'s own doc comment.
            if showMusicLink != shouldShow { showMusicLink = shouldShow }
        }
        .fullScreenCover(isPresented: $showMusicLink) {
            MusicServiceLinkView(onSkip: { skippedMusicLink = true })
                .environmentObject(musicService)
                .environmentObject(spotifyService)
                .environment(authVM)
                .environmentObject(playerVM)
        }
        // Permanent breadcrumb for the intermittent "empty screen on
        // reopen" report — a full-bleed `bgBase` window with no nav bar, no
        // tab bar and no content, i.e. the window with nothing painted over
        // it. All three branches above render real content, so if this
        // recurs the log says immediately whether SwiftUI believes it's
        // showing `MainTabView` (a rendering/compositing problem) or one of
        // the other branches (a state problem) — rather than another round
        // of theorising. Same `diagLog` convention that cracked the white-
        // flash bug.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification
        )) { _ in
            let branch: String
            if authVM.isInitializing || showPostAuthBridge { branch = "LaunchSplash" }
            else if authVM.isAuthenticated                 { branch = "MainTabView" }
            else                                            { branch = "AuthStack" }
            diagLog("ContentView active: branch=\(branch) musicLinkCover=\(showMusicLink) initializing=\(authVM.isInitializing) authed=\(authVM.isAuthenticated)")
        }
        // Already-authorized cold start: trigger an initial sync.
        .task {
            diagLog("ContentView: launch-sync .task fired, authed=\(musicService.isAuthenticated)")
            guard let uid = authVM.currentUser?.uid, musicService.isAuthenticated else { return }
            // Deliberately off the launch critical path. This sync's only
            // visible effect is refreshing the user's OWN recent tracks
            // (Jump Back In, via `HomeViewModel.refreshOwnRecents` reacting
            // to `syncService.lastSyncedAt`) — it used to fire immediately,
            // concurrent with Home's, Feed's and Library's own launch loads,
            // so ~25 MusicKit lookups and ~25 Firestore transactions
            // competed with the very requests painting the first screen.
            // Home picks the result up reactively whenever it lands,
            // regardless of this delay.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            syncService.sync(uid: uid, service: musicService)
        }
        // Start mirroring this device's playback to RTDB (users_live) for
        // NearMe's "Now Playing" — safe to call once auth is ready; no-ops if
        // already started or if RTDB isn't provisioned.
        .task {
            nowPlayingBroadcast.start(playerVM: playerVM, authVM: authVM)
        }
        // Self-heal: end any of my own party docs still marked `.live` from a
        // previous process (crash/force-quit before `endParty` ever ran — the
        // party VM never restores a session across relaunch, so this can never
        // catch a legitimately-resumable session). Fixes "zombie" parties that
        // would otherwise stay live forever and keep surfacing to other users.
        .task {
            guard let uid = authVM.currentUser?.uid else { return }
            await endOrphanedLiveParties(hostUid: uid)
        }
        // Keep your OWN profile ready at all times.
        //
        // `ProfileView` already paints instantly from its disk
        // `ProfileSnapshot`, but that snapshot only refreshes when Profile
        // itself appears — so the FIRST visit of a session showed last
        // session's data until the network caught up. Warming here means the
        // bundle and both follow lists are resolved before you ever tap the
        // avatar. Fire-and-forget: nothing on screen awaits it.
        .task {
            guard let uid = authVM.currentUser?.uid else { return }
            SocialCache.shared.prefetch(uid: uid, viewerUid: uid)
            SocialCache.shared.prefetchFollowLists(uid: uid)
        }
        // Spotify support is suspended (connect entry points removed) — an
        // account still linked from before this shipped would otherwise be
        // silently stuck on a service with no visible UI to manage or
        // disconnect it. Clear `activeService` so `shouldShowMusicLink` flips
        // true and they're re-prompted to connect Apple Music. Best-effort,
        // same launch-time-cleanup pattern as `endOrphanedLiveParties` above.
        .task {
            guard let uid = authVM.currentUser?.uid,
                  authVM.profile?.activeService == .spotify else { return }
            await setActiveMusicService(nil, uid: uid, playerVM: playerVM, authVM: authVM)
        }
        // Kick off a library sync when Apple Music access transitions to
        // granted. Deliberately does NOT write `activeService` here — this
        // fires on ANY transition to `isAuthenticated == true`, including
        // MusicKit's OS-level grant silently resurrecting on a cold launch
        // (it has no per-app revoke), which looks identical to a genuine
        // user-initiated connect. Writing `activeService` from a passive
        // observer like this was the root cause of Apple Music silently
        // "reconnecting" after the user explicitly disconnected it — that
        // responsibility now lives only in the real connect/disconnect call
        // sites (`ProfileView`, `MusicServiceLinkView`), via
        // `setActiveMusicService(...)`.
        .onChange(of: musicService.isAuthenticated) { _, isAuth in
            guard isAuth, let uid = authVM.currentUser?.uid else { return }
            syncService.sync(uid: uid, service: musicService)
        }
        // Same for Spotify — sync-only, same rationale as above.
        .onChange(of: spotifyService.isAuthenticated) { _, isAuth in
            guard isAuth, let uid = authVM.currentUser?.uid else { return }
            syncService.syncSpotify(uid: uid, service: spotifyService)
        }
        // Stage B wiring: give PlayerViewModel a reference to SpotifyMusicService
        // (it's constructed with no dependencies, so this is how it learns about
        // it) and set its initial `activeService` from the user's Firestore
        // preference at launch. `setActiveMusicService(...)` (the sole writer
        // of `activeService`, called from real connect/disconnect actions in
        // `ProfileView`/`MusicServiceLinkView`) already updates `playerVM`
        // directly and calls `authVM.refreshProfile()`, so this `.task` +
        // `.onChange` pair mainly matters for a fresh launch — reading
        // whatever was last persisted to Firestore before any connect action
        // in this session has happened.
        .task {
            playerVM.configure(spotifyService: spotifyService)
            playerVM.configure(musicService: musicService)
            syncCoordinator.configure(playerVM: playerVM)
            playerVM.activeService = authVM.profile?.activeService ?? .appleMusic
        }
        .onChange(of: authVM.profile?.activeService) { _, service in
            playerVM.activeService = service ?? .appleMusic
        }
        // Re-sync on foreground return + re-read auth (user may have toggled
        // permission in Settings while away).
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            musicService.refreshAuthStatus()
            if musicService.isAuthenticated, let uid = authVM.currentUser?.uid {
                syncService.sync(uid: uid, service: musicService)
            }
            // If the last Spotify play attempt failed for lack of an active
            // Connect device, this is exactly the moment that tends to fix
            // it — the user likely just came back from opening the real
            // Spotify app (manually, or via the alert's "Open Spotify"
            // button). No-ops when there's nothing pending.
            Task { await playerVM.retryAfterSpotifyDeviceRecovery() }
        }
    }
}

/// Branded cold-launch splash shown while Firebase resolves the auth state.
///
/// Replaces the previous bare `bgDeep` fill (the "purple screen and nothing
/// else"). After ~8 s of still-initializing it surfaces a quiet hint so a
/// stalled launch reads as a slow network rather than a frozen app.
private struct LaunchSplash: View {
    @State private var slowStart = false

    var body: some View {
        ZStack {
            Color.nodalong.bgDeep.ignoresSafeArea()

            VStack(spacing: 20) {
                NodalongMark(size: 52)
                    .foregroundStyle(Color.nodalong.purpleAccent)
                Text("Nodalong")
                    .font(Font.nodalong.title2Bold)
                    .foregroundStyle(Color.nodalong.textOnAccent)
                ProgressView()
                    .tint(Color.nodalong.purpleAccent)
                    .padding(.top, 4)
                if slowStart {
                    Text("Taking longer than usual — check your connection.")
                        .font(Font.nodalong.footnote)
                        .foregroundStyle(Color.nodalong.textOnAccent.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .transition(.opacity)
                }
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            withAnimation { slowStart = true }
        }
    }
}
