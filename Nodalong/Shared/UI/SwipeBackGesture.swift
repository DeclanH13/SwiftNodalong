import SwiftUI
import UIKit

/// Restores the edge-swipe-to-go-back gesture that hiding the navigation bar
/// takes away.
///
/// UIKit wires `interactivePopGestureRecognizer` to the navigation bar's own
/// back button, and disables it whenever the bar is hidden — it has no back
/// button to drive. This app hides the bar on **every** screen (see
/// `ScreenHeader`, which replaced it app-wide to stop bar height/appearance
/// changes forcing a layout settle mid-push), so the swipe went with it and
/// the only way back became the header's chevron.
///
/// The fix is to give the recognizer a delegate of our own. The widely-copied
/// version of this assigns `delegate = nil`, which is a trap: a nil delegate
/// means "always begin", so a swipe on a stack's ROOT starts a pop with
/// nothing to pop and leaves the navigation controller wedged — the back
/// button stops working from then on. This delegate answers the question
/// properly instead, and only allows the gesture when there is genuinely
/// something underneath.
///
/// Installed per navigation controller, not per screen: `ScreenHeader` is on
/// every tab root, so the install happens once per stack and covers every
/// screen pushed onto it — including the handful (`PlaylistDetailView`) that
/// draw their own header rather than using `ScreenHeader`.
final class SwipeBackGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    static let shared = SwipeBackGestureDelegate()

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let nav = gestureRecognizer.view?.enclosingNavigationController else { return false }
        return nav.viewControllers.count > 1
    }
}

private extension UIResponder {
    /// Walks the responder chain rather than trusting `view.next` to be the
    /// controller directly — SwiftUI nests its own hosting views between the
    /// navigation controller's view and anything we can reach.
    var enclosingNavigationController: UINavigationController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let nav = current as? UINavigationController { return nav }
            responder = current.next
        }
        return nil
    }
}

/// Zero-size view controller whose only job is to be inside the navigation
/// controller's own hierarchy, so it can reach up and find it.
private final class SwipeBackInstallerController: UIViewController {
    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        install()
    }

    func install() {
        guard let gesture = navigationController?.interactivePopGestureRecognizer else { return }
        gesture.delegate = SwipeBackGestureDelegate.shared
        gesture.isEnabled = true
    }
}

private struct SwipeBackInstaller: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        SwipeBackInstallerController()
    }

    /// Re-asserted on every update, not just on insert. `delegate` is a weak
    /// reference and the recognizer outlives any one screen, so re-applying is
    /// how this survives anything else that reassigns it.
    func updateUIViewController(_ controller: UIViewController, context: Context) {
        (controller as? SwipeBackInstallerController)?.install()
    }
}

extension View {
    /// Re-enables edge-swipe-back on the navigation stack this view sits in.
    /// Applied from `ScreenHeader`, so every stack gets it from its own root.
    func enablesInteractiveSwipeBack() -> some View {
        background(
            SwipeBackInstaller()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
    }
}
