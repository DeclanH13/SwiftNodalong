import Foundation

/// A normalized snapshot of a broadcaster's playback timeline, used to drive
/// **synced ("radio") playback** — a follower plays the same track on its own
/// device, aligned to the broadcaster's position.
///
/// Both live sources feed this shape: a party host's now-playing pointer
/// (`PartyNowPlaying`) and a solo user's now-playing presence (`UserNowPlaying`).
/// The follower doesn't stream audio from the broadcaster — every device plays
/// the full track through its own Apple Music subscription — so all that's shared
/// is *position on a timeline*.
///
/// `serverUpdatedAt` is a **server-clock** timestamp (ms), stamped by the
/// broadcaster via `ServerClock` (RTDB `/.info/serverTimeOffset`). Referencing
/// server time on both sides cancels out device clock skew — the one real hazard
/// in cross-device sync. See `targetPositionMs(serverNowMs:)`.
public struct SyncTimeline: Hashable, Sendable {
    /// The catalog id of the track the broadcaster is playing.
    public var catalogId: String
    /// The broadcaster's playback position (ms) at the instant `serverUpdatedAt`
    /// was stamped.
    public var positionMs: Int
    /// Whether the broadcaster is playing (vs paused).
    public var isPlaying: Bool
    /// Server-clock timestamp (ms) when this snapshot was written.
    public var serverUpdatedAt: Double
    /// Whether the broadcaster itself is on the 30-second preview fallback
    /// (non-subscriber). A follower syncing against a preview-mode broadcaster
    /// would get yanked into a new track every ~30s as the broadcaster's own
    /// preview ends and auto-advances — sync is blocked against this rather
    /// than degrading into that. `false` for legacy payloads (pre-dates this
    /// field) — degrades to "assume real playback," matching prior behavior.
    public var isPreviewPlayback: Bool

    public init(catalogId: String, positionMs: Int, isPlaying: Bool, serverUpdatedAt: Double, isPreviewPlayback: Bool = false) {
        self.catalogId = catalogId
        self.positionMs = positionMs
        self.isPlaying = isPlaying
        self.serverUpdatedAt = serverUpdatedAt
        self.isPreviewPlayback = isPreviewPlayback
    }

    /// Extrapolates the broadcaster's *current* position, given the follower's
    /// own reading of the shared server clock (`serverNowMs`).
    ///
    /// While playing, position advances in real time (rate 1.0), so the current
    /// position is the last-sampled position plus the elapsed server time since
    /// the sample. While paused, position is frozen at the sample. This is exact
    /// enough that a single accurate sample carries a whole song — the broadcaster
    /// only needs to re-broadcast on state changes (seek/pause) plus an occasional
    /// keepalive, not continuously.
    ///
    /// Never returns a negative value (a slightly stale/`serverNowMs`-behind read
    /// clamps to 0 rather than seeking before the track start).
    public func targetPositionMs(serverNowMs: Double) -> Int {
        guard isPlaying else { return max(0, positionMs) }
        let elapsed = serverNowMs - serverUpdatedAt
        return max(0, positionMs + Int(elapsed))
    }
}
