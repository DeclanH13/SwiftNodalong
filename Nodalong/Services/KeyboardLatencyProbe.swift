import UIKit

/// Measures the pause between tapping into Search's field and the first
/// character actually landing — split into focus → keyboard shown → first key,
/// so the cost can be attributed instead of guessed at.
///
/// **Numbers only.** The lines go to `FieldLog`, whose privacy contract forbids
/// query text, so this is safe to ship and shows up in Release/TestFlight
/// exports too — which matters, because a debug build run from Xcode makes
/// text-input spin-up look far worse than it is for real users.
@MainActor
enum KeyboardLatencyProbe {
    private static var focusAt: Date?
    private static var shownAt: Date?
    private static var firstKeyLogged = true   // nothing to log until a focus happens
    private static var openedBefore = false
    private static var observing = false

    /// Called once at launch, before any keyboard can appear.
    static func start() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidShowNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { shownAt = shownAt ?? Date() }
        }
    }

    /// Search appeared. Tags it cold (first open of the session) or warm, and
    /// in debug tightens the hang detector for a few seconds so a stall around
    /// the keyboard is caught at 50 ms rather than 150.
    static func searchOpened() {
        FieldLog.event("search", "opened cold=\(!openedBefore)")
        openedBefore = true
        #if DEBUG
        MainThreadHangDetector.thresholdMs = 50
        Task { try? await Task.sleep(nanoseconds: 5_000_000_000); MainThreadHangDetector.thresholdMs = 150 }
        #endif
    }

    static func focused() {
        focusAt = Date()
        shownAt = nil
        firstKeyLogged = false
    }

    /// First time the query text changes after a focus.
    static func firstKey() {
        guard !firstKeyLogged, let f = focusAt else { return }
        firstKeyLogged = true
        let toShown = shownAt.map { Int($0.timeIntervalSince(f) * 1000) } ?? -1
        let toKey = Int(Date().timeIntervalSince(f) * 1000)
        FieldLog.event("search", "focus→keyboard=\(toShown)ms focus→firstKey=\(toKey)ms")
    }
}
