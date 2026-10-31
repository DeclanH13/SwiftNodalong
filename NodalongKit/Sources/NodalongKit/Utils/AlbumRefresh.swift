import Foundation

/// When a cached album track list should next be re-fetched, or `nil` when it
/// never needs to be.
///
/// A list containing any unplayable track is transient by definition — it's an
/// unreleased or partly released album — so the cache must not hold it forever.
///
/// - Fully playable → `nil` (cache indefinitely, as before).
/// - Release date still in the future → that date: nothing can change before it.
/// - Release date reached but tracks still unplayable → `now + 1h`: Apple rolls
///   releases out by time of day and region, so keep checking until it's all up.
/// - Released more than `albumRefreshGraceDays` ago and STILL incomplete → `nil`:
///   a track that's unplayable two weeks after release is region-locked or
///   removed, not pending, and re-checking it forever would be wasted requests.
/// - No known date → `now + 6h`.
public let albumRefreshGraceDays = 14

public func albumRefreshAfter(releaseDate: String?, hasUnplayable: Bool, now: Date = Date()) -> Date? {
    guard hasUnplayable else { return nil }
    if let raw = releaseDate, !raw.isEmpty {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        if let date = f.date(from: String(raw.prefix(10))) {
            if date > now { return date }
            if now.timeIntervalSince(date) > Double(albumRefreshGraceDays) * 86_400 { return nil }
            return now.addingTimeInterval(3_600)
        }
    }
    return now.addingTimeInterval(6 * 3_600)
}
