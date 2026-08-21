import Foundation

/// A user's general "currently playing" presence, mirrored at
/// `users_live/{uid}/nowPlaying` (RTDB) by `UserPresenceService`. Generalizes
/// the party host's now-playing broadcast (`PartyNowPlaying`) to every user —
/// solo playback is, conceptually, a live party of one.
///
/// Carries `positionMs` + a server-clock `updatedAt` so a nearby user can **tune
/// in** and play the same track aligned to this user's position.
/// Stores only `catalogId`, not title/artist/artwork, matching the app's
/// established normalization pattern (`CatalogCache` is the single source of
/// truth for track metadata).
public struct UserNowPlaying: Hashable, Sendable {
    public var catalogId: String
    /// Playback position (ms) at the instant `updatedAt` was stamped. `nil` for
    /// legacy payloads written before sync support. Enables NearMe "tune in".
    public var positionMs: Int?
    public var isPlaying: Bool
    /// **Server-clock** timestamp (ms) — stamped via `ServerClock` so a follower
    /// can extrapolate position across device clock skew (see `SyncTimeline`).
    public var updatedAt: Double
    /// `true` while this user's own playback is the 30-second preview fallback
    /// (non-subscriber). Tuning in is blocked against a preview-mode broadcaster
    /// — see `SyncTimeline.isPreviewPlayback`'s doc comment.
    public var isPreviewPlayback: Bool

    public init(catalogId: String, positionMs: Int? = nil, isPlaying: Bool, updatedAt: Double, isPreviewPlayback: Bool = false) {
        self.catalogId = catalogId
        self.positionMs = positionMs
        self.isPlaying = isPlaying
        self.updatedAt = updatedAt
        self.isPreviewPlayback = isPreviewPlayback
    }
}
