import UIKit

/// Screen geometry read through the active window scene — the replacement
/// for the deprecated `UIScreen.main` (deprecated iOS 26: the singleton
/// assumes a single-scene app, which doesn't generalize to multi-window/
/// external-display scenes). Nodalong only ever has one scene, so `bounds`/
/// `scale` resolve to exactly the same physical screen `UIScreen.main`
/// always pointed to — this is a value-for-value substitution, not a
/// behavior change.
enum ScreenMetrics {
    /// Equivalent to the old `UIScreen.main.bounds`.
    @MainActor
    static var bounds: CGRect {
        currentScreen?.bounds ?? CGRect(x: 0, y: 0, width: 393, height: 852)
    }

    /// Equivalent to the old `UIScreen.main.scale`.
    @MainActor
    static var scale: CGFloat {
        currentScreen?.scale ?? 3
    }

    /// The screen of the first connected window scene. `nil` only in the
    /// pathological case where no scene has connected yet — SwiftUI content
    /// shouldn't be evaluating at that point, so the fallbacks above exist
    /// purely so a screen-metrics read can never crash or return zero.
    ///
    /// **Cached**, because resolving this walks `connectedScenes` and
    /// allocates an array via `compactMap` — and `bounds`/`scale` are read
    /// from inside `TrackCard` and `ArtworkThumbnail` bodies, i.e. once per
    /// visible tile per render pass.
    ///
    /// Caching the SCREEN rather than its `bounds` is deliberate: `bounds`
    /// and `scale` stay live across rotation because UIKit updates them on
    /// the `UIScreen` in place, so there's nothing to invalidate. `weak` so
    /// a torn-down scene's screen is never retained — if it does go away,
    /// the next read simply re-resolves.
    @MainActor
    private static weak var cachedScreen: UIScreen?

    @MainActor
    private static var currentScreen: UIScreen? {
        if let cachedScreen { return cachedScreen }
        let screen = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }
            .first
        cachedScreen = screen
        return screen
    }
}
