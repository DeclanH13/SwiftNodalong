import SwiftUI

/// The root tab container shown to authenticated users.
struct MainTabView: View {
    @Environment(FirebaseAuthViewModel.self) private var authVM
    @EnvironmentObject private var musicService:    AppleMusicService
    @EnvironmentObject private var syncService:     LibrarySyncService
    @EnvironmentObject private var locationService: LocationService
    @EnvironmentObject private var playerVM:        PlayerViewModel

    @StateObject private var shelfVM     = ShelfViewModel()
    @StateObject private var searchVM    = SearchViewModel()
    @StateObject private var feedVM      = FeedViewModel()
    @StateObject private var nearMeVM    = NearMeViewModel()
    @StateObject private var playlistsVM = PlaylistsViewModel()
    @StateObject private var partyVM     = ListeningPartyViewModel()
    @StateObject private var homeVM      = HomeViewModel()
    /// Owns which tab is selected and each tab's own `NavigationPath` — see
    /// its own doc comment for why this replaced a private `@State var
    /// selectedTab` and 4 independent per-tab private `@State var path`s.
    @StateObject private var router      = AppRouter()

    /// Guards the appearance/window-chrome setup below to run exactly once
    /// per process. `MainTabView` is reconstructed every time `isAuthenticated`
    /// flips true — cold launch *and* every sign-in — but these are global,
    /// process-wide UIKit settings that never need to be reapplied. Redoing
    /// them on every sign-in was pure wasted main-thread work landing right
    /// at the transition where the window briefly shows its raw background
    /// before this view's first real frame paints — the "purple screen" seen
    /// on sign-out → sign-in, worse there than at cold launch because on a
    /// repeat sign-in the work is 100% redundant (the window is already the
    /// right color from the first time).
    private static var didConfigureChrome = false

    init() {
        guard !Self.didConfigureChrome else { return }
        Self.didConfigureChrome = true
        AppChrome.configureMainChrome()
    }

    var body: some View {
        // Tab Navigation 2.0 (revised): Search is a real tab again, using
        // the `role: .search` Tab — iOS automatically renders it as a
        // visually separated trailing circle, matching Apple Music's own
        // tab bar exactly. Profile stays a persistent per-tab entry point
        // (`.profileEntryPoint()`, applied inside Home/Feed/NearMe/Shelf).
        TabView(selection: $router.selectedTab) {
            Tab("Home", systemImage: "house.fill", value: AppRouter.Tab.home) {
                HomeView()
            }
            Tab("Feed", systemImage: "person.2.fill", value: AppRouter.Tab.feed) {
                FeedView()
            }
            Tab("Near Me", systemImage: "location.fill", value: AppRouter.Tab.nearMe) {
                NearMeView()
            }
            Tab("Shelf", systemImage: Icons.musicalNotesOutline, value: AppRouter.Tab.shelf) {
                ShelfView()
            }
            // `role: .search` is what makes iOS separate this tab into its
            // own trailing circle instead of grouping it with the others.
            Tab("Search", systemImage: Icons.search, value: AppRouter.Tab.search, role: .search) {
                SearchView()
            }
        }
        .fullScreenCover(isPresented: $playerVM.isExpanded) {
            NowPlayingView()
        }
        .fullScreenCover(isPresented: $partyVM.presenting) {
            PartyView()
        }
        // Presented from here, not from `MiniPlayerBar` itself, even
        // though that's where the triggering tap happens — `MiniPlayerBar`
        // lives inside `.tabViewBottomAccessory` below, which (confirmed via
        // a real device console capture) gets torn down and rebuilt on its
        // own during normal use. A `.sheet` bound to local `@State` on a
        // view that can disappear out from under it gets silently reset,
        // which is exactly what made this flash open and immediately close.
        // This `TabView` root is stable, same reasoning as the two covers
        // right above. See `ListeningPartyViewModel.showStartPartySheet`'s
        // own doc comment.
        .sheet(isPresented: $partyVM.showStartPartySheet) {
            StartPartySheet()
        }
        // `ListeningPartyViewModel.errorMessage` was being set in several
        // failure paths (e.g. `addToQueue`'s Firestore write throwing) but
        // never actually read/displayed anywhere in the app — any failure
        // there was completely silent, no alert, no toast, nothing. Found
        // while investigating a real report of "add to queue" not working;
        // the actual root cause that day was a different, separate bug (a
        // dead standalone icon on `TrackCard` bypassing party-routing
        // entirely — see its own removal), but this gap is real regardless
        // and would leave ANY future write failure silent too.
        .alert(
            "Couldn't update the LP",
            isPresented: Binding(
                get: { partyVM.errorMessage != nil },
                set: { if !$0 { partyVM.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(partyVM.errorMessage ?? "")
        }
        // The mini player lives in the system's bottom-accessory slot,
        // always in its floating expanded pill form. `isEnabled:` (not a
        // conditional `if` wrapping this modifier) is the documented way to
        // show/hide it — avoids both a stale-empty-slot bug and a crash tied
        // to conditioning the accessory together with `TabView(selection:)`,
        // both reported against early iOS 18/26 point releases.
        .tabViewBottomAccessory(isEnabled: playerVM.nowPlaying != nil) {
            MiniPlayerBar()
                .environmentObject(playerVM)
        }
        // Deliberately `.never` — this used to be `.onScrollDown` (merging
        // the mini player into the tab bar row while scrolling), reverted
        // per direct product decision: the system's `.expanded`/`.inline`
        // placement transition was a confirmed source of real on-device
        // visual glitches (the spinning disc briefly escaping its circular
        // mask mid-transition — see the residual-drift note that used to
        // live in `MiniPlayerBar`'s own doc comment, now moot since that
        // transition can no longer happen). The mini player now always
        // stays in its one floating-pill form, never merged into the bar.
        .tabBarMinimizeBehavior(.never)
        .overlay(alignment: .bottom) {
            QueueToastOverlay()
        }
        .environmentObject(shelfVM)
        .environmentObject(searchVM)
        .environmentObject(feedVM)
        .environmentObject(nearMeVM)
        .environmentObject(playlistsVM)
        .environmentObject(partyVM)
        .environmentObject(homeVM)
        .environmentObject(router)
    }
}

#if DEBUG
#Preview {
    MainTabView().withPreviewEnvironment()
}
#endif
