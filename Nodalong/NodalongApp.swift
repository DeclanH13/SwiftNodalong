import SwiftUI
import FirebaseCore

/// App entry point — owns every long-lived view model and injects them via
/// `.environmentObject` so any descendant view can read them.
///
/// The provider hierarchy is intentional and roughly mirrors the React Native
/// Context tree: Firebase auth → Apple Music auth → library sync → location →
/// player → library. Every VM is `@StateObject` so SwiftUI keeps the same
/// instance across re-renders.
@main
struct NodalongApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // `@State`, not `@StateObject` — `FirebaseAuthViewModel` is `@Observable`.
    // Deliberately has NO inline default: see `init()` for why the
    // construction ORDER here is load-bearing.
    @State private var authVM: FirebaseAuthViewModel
    @StateObject private var musicService    = AppleMusicService()
    @StateObject private var spotifyService  = SpotifyMusicService()
    @StateObject private var syncService     = LibrarySyncService()
    @StateObject private var locationService = LocationService()
    @StateObject private var playerVM        = PlayerViewModel()
    @StateObject private var libraryVM       = LibraryViewModel()
    @StateObject private var nowPlayingBroadcast = NowPlayingBroadcastService()
    @StateObject private var syncCoordinator = SyncFollowCoordinator()

    /// Ensures Firebase is configured **before** `FirebaseAuthViewModel` is
    /// constructed.
    ///
    /// This ordering is load-bearing and easy to break. `FirebaseAuthViewModel.init`
    /// reads `Auth.auth().currentUser` synchronously — that's the warm-launch
    /// splash skip — which traps if `FirebaseApp.configure()` hasn't run yet.
    ///
    /// It used to be safe implicitly: `@StateObject` wraps its initial value in
    /// an `@autoclosure` and defers construction until the first body
    /// evaluation, which happens after `AppDelegate`'s
    /// `didFinishLaunchingWithOptions` has configured Firebase. `@State`
    /// (required now that the view model is `@Observable`) evaluates its
    /// default **eagerly**, during App-struct init — i.e. BEFORE the delegate
    /// runs. Assigning the state here instead makes the ordering explicit.
    ///
    /// `configure()` is guarded rather than moved: `AppDelegate` still calls it
    /// for every other launch path, and calling it twice traps.
    init() {
        if FirebaseApp.app() == nil { FirebaseApp.configure() }
        _authVM = State(wrappedValue: FirebaseAuthViewModel())
    }

    /// User's appearance override (System/Light/Dark), set from `ProfileView`.
    /// Shares `appearanceModeKey` with the picker there via `@AppStorage`,
    /// so a change is reflected immediately without any extra plumbing.
    @AppStorage(appearanceModeKey) private var appearanceModeRaw = AppearanceMode.system.rawValue
    private var appearanceMode: AppearanceMode { AppearanceMode(rawValue: appearanceModeRaw) ?? .system }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(authVM)
                .environmentObject(musicService)
                .environmentObject(spotifyService)
                .environmentObject(syncService)
                .environmentObject(locationService)
                .environmentObject(playerVM)
                .environmentObject(playerVM.clock)
                .environmentObject(libraryVM)
                .environmentObject(nowPlayingBroadcast)
                .environmentObject(syncCoordinator)
                .preferredColorScheme(appearanceMode.colorScheme)
        }
    }
}
