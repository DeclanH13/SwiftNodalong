import Foundation

/// TEMPORARY DIAGNOSTIC utility for the fresh-install Search-tab lag
/// investigation (see CLAUDE.md decisions log). Prints a millisecond
/// timestamp + the calling thread so log lines from concurrent tasks can be
/// correlated against `MainThreadHangDetector`'s own output. Remove once
/// the investigation concludes — every call site is tagged `[Nodalong.Diag]`
/// for easy removal.
private let diagFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

func diagLog(_ message: @autoclosure () -> String) {
    let thread = Thread.isMainThread ? "main" : "bg"
    print("[Nodalong.Diag] \(diagFormatter.string(from: Date())) [\(thread)] \(message())")
}

/// TEMPORARY DIAGNOSTIC — detects main-thread hangs directly, rather than
/// inferring them from how long async calls took. A background queue posts
/// a "ping" block to the main queue every ~150ms and measures how long it
/// actually took to run; a large delay is the direct signature of
/// something MainActor-bound keeping the main thread busy, which is
/// exactly the mechanism suspected (but not yet confirmed) for the
/// fresh-install Search-tab lag. Remove once the investigation concludes.
enum MainThreadHangDetector {
    private static var started = false

    static func start(thresholdMs: Double = 150) {
        guard !started else { return }
        started = true
        let queue = DispatchQueue(label: "nodalong.diag.hangdetector", qos: .utility)

        func scheduleTick() {
            queue.asyncAfter(deadline: .now() + 0.15) {
                let postedAt = DispatchTime.now()
                DispatchQueue.main.async {
                    let delayMs = Double(DispatchTime.now().uptimeNanoseconds - postedAt.uptimeNanoseconds) / 1_000_000
                    if delayMs > thresholdMs {
                        diagLog("⚠️ main thread hang: \(Int(delayMs))ms")
                    }
                    scheduleTick()
                }
            }
        }
        scheduleTick()
    }
}
