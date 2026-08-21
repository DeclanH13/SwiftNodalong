import AVFoundation
import FirebaseCore
import UIKit

/// UIKit launch hook — calls `FirebaseApp.configure()` and sets up the audio
/// session before any SwiftUI code runs. Wired in via
/// `@UIApplicationDelegateAdaptor` in `NodalongApp.swift`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Guarded — `NodalongApp.init()` may already have configured it, and
        // calling `configure()` twice traps. Whichever runs first wins.
        if FirebaseApp.app() == nil { FirebaseApp.configure() }
        // Nav/tab chrome the pre-auth screens need — `MainTabView.init()`
        // only runs after sign-in, so without this the auth stack's nav
        // titles rendered in the system font. See `AppChrome`.
        AppChrome.configureLaunchChrome()
        configureAudioSession()
        configureURLCache()
        // TEMPORARY DIAGNOSTIC — see CLAUDE.md decisions log (fresh-install
        // Search-tab lag investigation). Remove once resolved.
        MainThreadHangDetector.start()
        diagLog("app launch: didFinishLaunching")
        // The window doesn't exist yet at this point (confirmed: 0 scenes,
        // 0 windows here), so its background has to be applied once one
        // does. `didBecomeActive` covers both launch and every reopen —
        // see `AppChrome.applyWindowBackground()` for why a one-shot call
        // wasn't enough and what the nil background looked like.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            // `queue: .main` guarantees the thread but not the actor, and
            // `AppChrome` is `@MainActor` — so hop explicitly.
            Task { @MainActor in AppChrome.applyWindowBackground() }
        }
        // Blank-screen investigation. The report is a full-bleed `bgBase`
        // window with no nav bar, tab bar or content — i.e. the window with
        // nothing painted over it — and it also reproduces when TAKING A
        // SCREENSHOT, which (like the app-switcher and the resume animation)
        // drives UIKit's snapshot render path. So the common factor is
        // off-cycle rendering, not user interaction.
        //
        // These two, plus `ContentView`'s branch breadcrumb, are what turn
        // the next occurrence into evidence: a memory warning immediately
        // before a relaunch means jetsam, and the scene-phase trail shows
        // whether the process actually restarted or merely resumed.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            diagLog("[Nodalong.Diag] MEMORY WARNING — jetsam risk; a relaunch after this is a kill, not a resume")
        }
        for (name, label) in [
            (UIApplication.didEnterBackgroundNotification, "didEnterBackground"),
            (UIApplication.willEnterForegroundNotification, "willEnterForeground"),
            (UIApplication.willResignActiveNotification, "willResignActive"),
        ] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                // The closure itself is `@Sendable`, so the UIKit reads have
                // to hop onto the MainActor explicitly — `queue: .main` only
                // guarantees the thread, not the actor, as far as the
                // compiler is concerned.
                Task { @MainActor in
                    let wins = UIApplication.shared.connectedScenes
                        .compactMap { $0 as? UIWindowScene }
                        .flatMap { $0.windows }
                    let root = wins.first?.rootViewController
                    diagLog("[Nodalong.Diag] \(label): windows=\(wins.count) rootVC=\(root.map { String(describing: type(of: $0)) } ?? "nil")")
                }
            }
        }
        return true
    }

    /// Configures the single image cache the app actually uses.
    ///
    /// All artwork renders through `AsyncImage`, which is backed by
    /// `URLCache.shared` — so that's the only cache to size. (Kingfisher was
    /// removed from every rendering path; configuring its `ImageCache.default`
    /// in parallel just reserved a second, unused 50 MB memory budget.)
    ///
    /// 24 MB in memory is plenty now that artwork decodes are capped at the
    /// 600 px source (see `ArtworkURL.sized`); 200 MB on disk survives restarts
    /// so repeat visits to Feed / Profile / Shelf stay instant.
    private func configureURLCache() {
        URLCache.shared = URLCache(
            memoryCapacity:  24 * 1024 * 1024,   // 24 MB memory
            diskCapacity:   200 * 1024 * 1024,   // 200 MB disk
            diskPath: "nodalong_artwork_cache"
        )
    }

    private func configureAudioSession() {
        // Only set the *category* at launch — cheap and safe. Do NOT call
        // `setActive(true)` here: activating an audio session from the
        // background (iOS relaunches background-audio apps while the phone is
        // still locked) can block the main thread, which froze the app on a
        // blank launch screen. Activation now happens lazily at first playback
        // (see `PlayerViewModel.activateAudioSessionIfNeeded`).
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
    }
}
