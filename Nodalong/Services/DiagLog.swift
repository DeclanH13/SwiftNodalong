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

/// Navigation diagnostics, written to a file in the app container **as well as**
/// stdout.
///
/// `devicectl --console` is the only way to see `print()` from a device, and it
/// needs the device unlocked with someone watching at the moment of the repro —
/// three consecutive captures died to a force-quit (`signal 9`), a dropped
/// tunnel (`RemoteXPCPeerConnection … canceled`) and a lock screen
/// (`FBSOpenApplicationErrorDomain error 7`). A file decouples the two:
/// reproduce whenever, pull afterwards with
///
///     xcrun devicectl device copy from --device <id> \
///       --domain-type appDataContainer --domain-identifier com.bigdeccyh.nodalong \
///       --source "Library/Application Support/nav.log" --destination ./nav.log
///
/// **TEMPORARY** — delete along with the rest of the `[Nodalong.Nav]`
/// diagnostics once the screen-stacking bug is root-caused. Debug-only like
/// everything else here, so a Release build writes nothing at all.
func navLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    let line = "\(diagFormatter.string(from: Date())) [\(Thread.isMainThread ? "main" : "bg")] \(message())"
    print("[Nodalong.Nav] \(line)")
    NavLogFile.append(line)
    #endif
}

#if DEBUG
/// Serialised, size-capped appender. Deliberately its own queue so writing a
/// nav line never does file I/O on the main thread — `AppRouter.push` runs
/// there.
private enum NavLogFile {
    private static let queue = DispatchQueue(label: "nodalong.navlog", qos: .utility)
    private static let maxBytes = 256 * 1024

    private static var url: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("nav.log")
    }

    static func append(_ line: String) {
        queue.async {
            guard let url, let data = (line + "\n").data(using: .utf8) else { return }
            // Truncate rather than rotate: this is scratch for one
            // investigation, and an unbounded log on a device is not something
            // to leave behind.
            if let size = try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int, size > maxBytes {
                try? FileManager.default.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
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

    /// Mutable so a short window of interest (Search opening) can run tighter.
    nonisolated(unsafe) static var thresholdMs: Double = 150

    static func start(thresholdMs: Double = 150) {
        #if DEBUG
        guard !started else { return }
        started = true
        Self.thresholdMs = thresholdMs
        let queue = DispatchQueue(label: "nodalong.diag.hangdetector", qos: .utility)

        func scheduleTick() {
            queue.asyncAfter(deadline: .now() + 0.15) {
                let postedAt = DispatchTime.now()
                DispatchQueue.main.async {
                    let delayMs = Double(DispatchTime.now().uptimeNanoseconds - postedAt.uptimeNanoseconds) / 1_000_000
                    if delayMs > Self.thresholdMs {
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
