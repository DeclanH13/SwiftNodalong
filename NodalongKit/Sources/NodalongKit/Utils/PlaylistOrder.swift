import Foundation

/// Fractional ordering for playlist / party-queue tracks.
///
/// Each track carries a sparse `order: Double`. Appending uses `maxOrder + step`;
/// reordering sets the moved item's `order` to the **midpoint of its two new
/// neighbours** — a single-document write, no rewrite of the whole list.
///
/// The one footgun of double midpoints is precision exhaustion: repeatedly
/// dropping an item between the *same* two neighbours halves the gap each time
/// and after ~50 moves the midpoint equals a neighbour. `needsRenormalize`
/// detects that so the caller can renormalise the list (reassign evenly spaced
/// orders) before it collapses. In practice this is rare; for typical editing it
/// never triggers.
public enum PlaylistOrder {
    /// Spacing between consecutively appended tracks. Large enough to leave room
    /// for many midpoint insertions before precision matters.
    public static let step: Double = 1024

    /// Smallest gap we tolerate between neighbours before recommending a
    /// renormalise. Well above `Double` epsilon so we act with margin to spare.
    public static let minGap: Double = 0.0001

    /// The `order` for a newly appended track given the current maximum order
    /// (nil when the list is empty).
    public static func appended(afterMax maxOrder: Double?) -> Double {
        guard let maxOrder else { return step }
        return maxOrder + step
    }

    /// The `order` to assign an item dropped between `before` and `after`.
    ///
    /// - `before` / `after` are the orders of the neighbours at the destination
    ///   (either may be nil at the ends of the list).
    public static func midpoint(before: Double?, after: Double?) -> Double {
        switch (before, after) {
        case let (b?, a?): return (b + a) / 2
        case let (b?, nil): return b + step   // dropped at the end
        case let (nil, a?): return a - step   // dropped at the start
        case (nil, nil):    return step       // only item
        }
    }

    /// True when the neighbours are so close that a further midpoint would lose
    /// precision — the caller should renormalise the list.
    public static func needsRenormalize(before: Double?, after: Double?) -> Bool {
        guard let b = before, let a = after else { return false }
        return abs(a - b) < minGap
    }

    /// Evenly spaced orders (`step, 2·step, …`) for renormalising `count` items
    /// back into their current visible sequence.
    public static func renormalized(count: Int) -> [Double] {
        guard count > 0 else { return [] }
        return (1...count).map { Double($0) * step }
    }
}
