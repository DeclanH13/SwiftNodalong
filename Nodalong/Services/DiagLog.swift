import Foundation

/// Diagnostic logging — **debug builds only**.
///
/// Everything here compiles to nothing in a Release build, which is what
/// TestFlight and the App Store ship. That's deliberate and not just noise
/// control: these logs carry real user data (track titles, search queries,
/// geohashes, uids, party ids), and testers' devices should not be writing
/// any of it.
///
/// The `@autoclosure` is what makes it free rather than merely quiet. In
/// Release the closure is never invoked, so the string interpolation at the
/// call site — often built from track metadata — never runs either. Call
/// sites stay exactly as they read today; there is no `#if DEBUG` to
/// remember at each one.
///
/// Debug builds (running from Xcode, or `devicectl` installs of a Debug
/// archive) keep full output, so on-device investigation is unchanged.

/// Timestamped, thread-tagged diagnostic line. No-op in Release.
func diagLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print("[Nodalong.Diag] \(diagFormatter.string(from: Date())) [\(Thread.isMainThread ? "main" : "bg")] \(message())")
    #endif
}

/// Plain diagnostic line, no timestamp — the chokepoint the app's
/// `print("[Nodalong.…]")` call sites now route through. No-op in Release.
func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}

#if DEBUG
private let diagFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()
#endif

/// Detects main-thread hangs directly rather than inferring them from how
/// long async calls took: a background queue posts a ping to the main queue
/// every ~150ms and measures the actual delay.
///
/// **Debug-only.** `start()` is an empty function in Release — the timer is
/// never scheduled at all, so testers' devices don't pay for a permanent
/// 150ms main-queue ping.
enum MainThreadHangDetector {
    #if DEBUG
    private static var started = false
    #endif

    static func start(thresholdMs: Double = 150) {
        #if DEBUG
        guard !started else { return }
        started = true
        let queue = DispatchQueue(label: "nodalong.diag.hangdetector", qos: .utility)

        func scheduleTick() {
            queue.asyncAfter(deadline: .now() + 0.15) {
                let postedAt = DispatchTime.now()
                DispatchQueue.main.async {
                    let delayMs = Double(DispatchTime.now().uptimeNanoseconds - postedAt.uptimeNanoseconds) / 1_000_000
                    if delayMs > thresholdMs {
                        print("[Nodalong.Diag] ⚠️ MAIN THREAD HANG \(Int(delayMs))ms")
                    }
                    scheduleTick()
                }
            }
        }
        scheduleTick()
        #endif
    }
}
