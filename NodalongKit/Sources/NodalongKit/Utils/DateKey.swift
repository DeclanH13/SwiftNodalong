import Foundation

/// Formats an epoch-milliseconds timestamp as a `yyyy-MM-dd` calendar-day key
/// in the device's current calendar/timezone.
///
/// Single canonical implementation for "what day did this happen on" — used
/// both to group spotlight history for display and to key each spotlight
/// event's document in Firestore (`{trackId}_{dateKey}`), so a track spotlit
/// again on a later day gets its own permanent history entry instead of
/// overwriting the previous one.
public func dateKey(epochMs: Double) -> String {
    let date  = Date(timeIntervalSince1970: epochMs / 1000)
    let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
}
