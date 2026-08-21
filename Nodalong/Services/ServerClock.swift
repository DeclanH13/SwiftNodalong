import Foundation
import FirebaseCore
import FirebaseDatabase

/// A shared, server-synchronized clock, backed by Firebase Realtime Database's
/// `/.info/serverTimeOffset` — the per-client delta between this device's clock
/// and the RTDB server clock.
///
/// This is the linchpin of synced ("radio") playback. Two devices' system clocks
/// can differ by seconds; if a broadcaster stamped its now-playing position with
/// its *local* clock and a follower extrapolated with *its own* local clock, that
/// skew would show up directly as playback misalignment. By having both sides
/// stamp and read against server time (`serverNowMs()`), the skew cancels out.
///
/// Same setup gate as the other live services: if RTDB isn't provisioned
/// (`DATABASE_URL` absent from `GoogleService-Info.plist`), the offset stays 0 and
/// `serverNowMs()` returns local time — a harmless fallback (sync features are
/// gated on RTDB availability elsewhere anyway).
@MainActor
final class ServerClock {
    static let shared = ServerClock()

    /// Server-minus-local offset in milliseconds, kept live by an RTDB observer.
    private var offsetMs: Double = 0

    private init() {
        guard FirebaseApp.app()?.options.databaseURL != nil else { return }
        // `/.info/serverTimeOffset` is a synthetic RTDB path that Firebase keeps
        // updated as it re-estimates the offset; observing it (rather than a
        // one-shot read) means the estimate refines over the session.
        Database.database().reference(withPath: ".info/serverTimeOffset")
            .observe(.value) { [weak self] snap in
                guard let ms = snap.value as? Double else { return }
                self?.offsetMs = ms
            }
    }

    /// The current server time in milliseconds since the Unix epoch.
    func serverNowMs() -> Double {
        Date().timeIntervalSince1970 * 1000 + offsetMs
    }
}
