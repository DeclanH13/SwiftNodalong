import Foundation

/// Formats a track duration (in **milliseconds**) as `M:SS`.
///
/// All track durations across Nodalong are stored in milliseconds. This is
/// a legacy schema choice inherited from the React Native version which used
/// Spotify (Spotify's API returns `duration_ms`). For consistency the rest
/// of the data model preserved milliseconds; `AppleMusicService` converts
/// MusicKit's `TimeInterval` (seconds) → ms on ingest so the on-disk shape
/// is always the same.
///
/// Display sites convert the other way using this helper. Don't reinvent
/// the conversion — duration arithmetic that treats the stored Int as
/// seconds will be off by a factor of 1000 (e.g. a 3:37 track will display
/// as 3624:27).
///
/// - Parameter durationMs: Track length in milliseconds. Negative values
///   are clamped to 0.
/// - Returns: `"M:SS"` formatted string. Zero-pads seconds.
public func formatTrackDuration(_ durationMs: Int) -> String {
    let totalSeconds = max(0, durationMs / 1000)
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    return String(format: "%d:%02d", minutes, seconds)
}
