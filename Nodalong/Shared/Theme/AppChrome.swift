import SwiftUI
import UIKit

/// UIKit appearance-proxy setup for the chrome SwiftUI can't reach — nav bar
/// titles and tab bar item labels are drawn by UIKit, so `Font.nodalong` has
/// no effect on them and they'd otherwise stay on San Francisco while every
/// SwiftUI screen renders in Quicksand.
@MainActor
enum AppChrome {

    /// Quicksand at a given size, falling back to the system font if the
    /// family somehow failed to register (a missing `UIAppFonts` entry, a
    /// renamed file) — never force-unwrapped, since a font lookup failure
    /// should degrade to SF, not crash at launch.
    static func brandFont(_ size: CGFloat, _ face: String, fallback: UIFont) -> UIFont {
        UIFont(name: face, size: size) ?? fallback
    }

    private static var navTitleFont: UIFont {
        brandFont(17, "Quicksand-SemiBold", fallback: .systemFont(ofSize: 17, weight: .semibold))
    }
    private static var navLargeTitleFont: UIFont {
        brandFont(34, "Quicksand-Bold", fallback: .systemFont(ofSize: 34, weight: .bold))
    }
    private static var tabItemFont: UIFont {
        brandFont(10, "Quicksand-Medium", fallback: .systemFont(ofSize: 10, weight: .medium))
    }

    /// Applied once at process launch, from `AppDelegate`.
    ///
    /// This used to also configure a transparent nav-bar appearance for the
    /// pre-auth stack (Sign In / Create Account / Reset password), whose
    /// titles would otherwise have rendered in SF while the screen beneath
    /// them was Quicksand. **That block is gone: those three screens no
    /// longer have a navigation bar**, and neither does `SplashView` above
    /// them, so nothing pre-auth can display one. `configureMainChrome()`
    /// still configures the nav bar because the app's sheets — Add to
    /// Playlist, Edit Profile, Queue, Start an LP, Add to Queue — kept
    /// theirs.
    static func configureLaunchChrome() {
        UITabBarItem.appearance().setTitleTextAttributes([.font: tabItemFont], for: .normal)
        UITabBarItem.appearance().setTitleTextAttributes([.font: tabItemFont], for: .selected)
    }

    /// The authenticated app's chrome — brand tints, the window background,
    /// and the opaque `bgBase` nav bar. Called once per process from
    /// `MainTabView.init()`.
    ///
    /// The nav-bar half now only reaches the app's **sheets** (Add to
    /// Playlist, Edit Profile, Queue, Start an LP, Add to Queue), which
    /// deliberately kept their bars so Cancel/Done stays where the platform
    /// puts it. Every pushed and tab-root screen hides its bar and renders a
    /// `ScreenHeader` instead.
    ///
    /// `UIColor(named:)`, not `UIColor(Color.nodalong.X)` — the latter
    /// resolves the SwiftUI `Color` to a static snapshot at the moment this
    /// runs, so it would freeze at whichever appearance was active then and
    /// never follow a later system light/dark toggle. `UIColor(named:)` stays
    /// trait-aware, re-resolving the named asset on every query.
    static func configureMainChrome() {
        let ink = UIColor(named: "textPrimary") ?? .white
        let accent = UIColor(named: "purpleAccent") ?? UIColor(Color.nodalong.purpleAccent)

        // Native UITabBar — let iOS render its Liquid Glass floating pill.
        // Only tint colours are configured; touching translucency or
        // background effects would replace the glass style with an opaque bar.
        UITabBar.appearance().tintColor = accent
        UITabBar.appearance().unselectedItemTintColor = ink.withAlphaComponent(0.50)
        UITabBarItem.appearance().setTitleTextAttributes([.font: tabItemFont], for: .normal)
        UITabBarItem.appearance().setTitleTextAttributes([.font: tabItemFont], for: .selected)

        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor          = UIColor(named: "bgBase") ?? UIColor(Color.nodalong.bgBase)
        navAppearance.titleTextAttributes       = [.foregroundColor: ink, .font: navTitleFont]
        navAppearance.largeTitleTextAttributes  = [.foregroundColor: ink, .font: navLargeTitleFont]
        UINavigationBar.appearance().standardAppearance   = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().tintColor            = accent

        applyWindowBackground()
    }

    /// Paints every attached window's background `bgBase`.
    ///
    /// **Must be re-runnable, and must run when a window actually exists.**
    /// This used to live inline in `configureMainChrome()` — i.e. it ran
    /// exactly once, from `MainTabView.init()`, and only after sign-in. A
    /// real device capture showed the consequences: at
    /// `didFinishLaunching` there are **0 scenes and 0 windows** (so doing
    /// this at launch is a silent no-op over an empty array), and at
    /// `didBecomeActive` the window's `backgroundColor` was still **nil**,
    /// which renders white.
    ///
    /// That nil window background is what showed through as white flashes
    /// on reopen: iOS composites the app-switcher snapshot against the live
    /// view during the resume animation, and any gap between them exposes
    /// the window itself. Same for the pre-auth screens, where
    /// `MainTabView.init()` has never run at all.
    ///
    /// Called on every `didBecomeActive` (cheap, idempotent, and guaranteed
    /// to have a window by then) as well as from `configureMainChrome()`.
    static func applyWindowBackground() {
        let bg = UIColor(named: "bgBase") ?? UIColor(Color.nodalong.bgBase)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            // ONLY the app's own window — the one actually hosting SwiftUI.
            //
            // This used to paint EVERY window in the scene, which is very
            // likely what produced the intermittent "blank bgBase screen".
            // A device capture showed the app running with `windows=2`: iOS
            // (and UIKit presentations) can add a second, normally
            // transparent overlay window, and painting that one opaque
            // `bgBase` turns it into a full-screen fill covering the real UI
            // — which is exactly the report: a full-bleed `bgBase` screen
            // with no nav bar, no tab bar and no content, appearing on
            // reopen and right after taking a screenshot (both moments when
            // this runs / an overlay window can appear).
            //
            // Identifying our window by its root being a `UIHostingController`
            // is the reliable test here: SwiftUI's `WindowGroup` hosts the
            // app in exactly one, and system/overlay windows never do.
            .filter { window in window.rootViewController.map(isHostingController) ?? false }
            .forEach { $0.backgroundColor = bg }
    }

    /// True for any `UIHostingController<…>`, whatever its generic parameter.
    /// The concrete generic type SwiftUI uses for the root is an internal
    /// implementation detail (`ModifiedContent<AnyView, RootModifier>` today),
    /// so match on the type NAME rather than trying to spell it out — a
    /// version bump that changes the generic must not silently stop matching
    /// and leave the window unpainted again.
    private static func isHostingController(_ vc: UIViewController) -> Bool {
        String(describing: type(of: vc)).hasPrefix("UIHostingController")
    }
}
