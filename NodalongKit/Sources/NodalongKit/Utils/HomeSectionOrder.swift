import Foundation

/// Every section the Home tab can render, as a value — so ordering, pinning,
/// hiding and the density cap become decisions about an ARRAY rather than
/// about the shape of one very long `body`.
///
/// `HomeView.body` previously carried eleven hardcoded
/// `if !x.isEmpty { section(title:) { ... } }` blocks in fixed source order.
/// Nothing could reorder them, nothing could count them, and a user with a
/// busy follow graph got exactly the same eleven-section wall as a brand-new
/// account — with the people-driven content that is the app's actual
/// differentiator sitting above a large block of Apple-sourced shelves that
/// look identical every launch.
///
/// Carrying the user-facing `title` here follows the precedent already set by
/// `PlaylistLens.title` / `.tagline`, which live in this module for the same
/// reason: the string and the case belong together, and neither needs SwiftUI.
public enum HomeSectionID: String, CaseIterable, Codable, Sendable {
    case liveNow
    case jumpBackIn
    case weeklyRecap
    case friendsSpotlights
    case madeByPeople
    case foundForYou
    case newReleases
    case newMusicDaily
    case cityCharts
    case genreCharts
    case friendsListening
    case mostNodded
    case recommended
    case recentlyAdded

    public var title: String {
        switch self {
        case .liveNow:           return "Live Now"
        case .jumpBackIn:        return "Jump Back In"
        case .weeklyRecap:       return "Your week"
        case .friendsSpotlights: return "Friends' Spotlights"
        case .madeByPeople:      return "Made for you, by real people"
        case .foundForYou:       return "Found for you"
        case .newReleases:       return "New Releases"
        case .newMusicDaily:     return "New Music Daily"
        // Both of these carry a name the user supplies (their city,
        // their genre), so the real heading is built at the call site
        // and this is only the fallback / menu label.
        case .cityCharts:        return "Top in Your City"
        case .genreCharts:       return "Top in Your Genre"
        case .friendsListening:  return "Friends are listening to"
        case .mostNodded:        return "Most nodded this week"
        case .recommended:       return "Recommended for You"
        case .recentlyAdded:     return "Recently Added"
        }
    }

    /// Where this sits when nothing is fresh and the user hasn't reordered.
    /// Lower sorts first.
    ///
    /// People-driven content leads and Apple's own evergreen shelves trail,
    /// deliberately: Top Charts / Recommended / Made For You look the same on
    /// every launch, so burying the friend-sourced sections underneath them
    /// spends the most valuable screen real estate on the least changing
    /// content.
    public var baseRank: Int {
        switch self {
        case .liveNow:           return 0
        // Jump Back In now also carries Apple's own recently-played
        // containers — see `HomeView.jumpBackInRail`. They were a separate
        // `recentlyPlayed` section showing about six items, all of which were
        // already deduped against this rail's own rows.
        case .jumpBackIn:        return 1
        case .weeklyRecap:       return 2
        case .friendsSpotlights: return 3
        case .newReleases:       return 4
        case .madeByPeople:      return 5
        case .foundForYou:       return 6
        case .friendsListening:  return 7
        case .mostNodded:        return 8
        case .recentlyAdded:     return 9
        // The global Daily Top chart was retired: for a storefront whose
        // capital dominates its population it overlapped `cityTop` almost
        // entirely, nothing deduped the two, and a national chart is the
        // least personal content the page can carry. These two survive
        // because they genuinely differ per user — and they now have to
        // prove they changed to count as fresh (`HomeViewModel.freshCharts`).
        case .cityCharts:        return 10
        case .genreCharts:       return 11
        // Apple's own editorial new-music playlist, the same for everyone —
        // so it sits with the other evergreen Apple shelves, below the
        // personal `newReleases` rail rather than above people-driven content.
        case .newMusicDaily:     return 12
        // Apple's playlists ("Made For You") are no longer a section of their
        // own: they come from the SAME recommendations payload as the album
        // shelves, so they render as one more shelf inside this one.
        case .recommended:       return 13
        }
    }

    /// Jump Back In cannot be hidden — it is the one section that keeps Home
    /// useful for an account with an empty follow graph and no Apple Music
    /// subscription, i.e. exactly the account most likely to hide things.
    public var isHideable: Bool { self != .jumpBackIn }

    /// Whether this section has a "see all" destination worth offering.
    ///
    /// The four that don't: both generated-playlist sections are already
    /// complete on screen (four tiles and one tile respectively — there is no
    /// "rest" to see), Live Now is a right-now signal that is never truncated,
    /// and Recommended for You has had its own dedicated screen since before
    /// this existed.
    public var hasSeeAll: Bool {
        switch self {
        case .madeByPeople, .foundForYou, .liveNow, .recommended, .newMusicDaily, .weeklyRecap: return false
        default: return true
        }
    }
}

/// Orders Home's sections: pins first, then everything with genuinely new
/// content today, then the rest — with `baseRank` holding within each group.
///
/// Two buckets rather than a continuous score, deliberately. A fully-scored
/// re-sort makes Home structurally different on every launch, which defeats
/// any muscle memory the user builds and makes "where did that section go?"
/// unanswerable. With two buckets, Home only moves when something has
/// actually happened, and it moves in a way you can predict.
///
/// The load-bearing property, covered by a test: identical inputs produce an
/// identical order. A section does not drift up or down for no reason.
///
/// - Parameters:
///   - available: Sections that currently have content to show. Order is
///     ignored; `baseRank` decides.
///   - fresh: Sections holding something genuinely new today.
///   - pinned: User-pinned sections, in the order they should appear. Pins
///     outrank freshness — an explicit choice beats an inferred one.
///   - hidden: User-hidden sections. Ignored for a section whose
///     `isHideable` is `false`, so a stale preference can never strand Home
///     without its fallback content.
public func orderHomeSections(
    available: [HomeSectionID],
    fresh: Set<HomeSectionID> = [],
    pinned: [HomeSectionID] = [],
    hidden: Set<HomeSectionID> = []
) -> [HomeSectionID] {
    let visible = available.filter { !hidden.contains($0) || !$0.isHideable }
    let visibleSet = Set(visible)

    // Pins keep the order the user put them in, deduped in case a stale
    // preference lists one twice.
    var seen = Set<HomeSectionID>()
    let pins = pinned.filter { visibleSet.contains($0) && seen.insert($0).inserted }

    let rest = visible
        .filter { !seen.contains($0) }
        .sorted {
            let lhsFresh = fresh.contains($0)
            let rhsFresh = fresh.contains($1)
            if lhsFresh != rhsFresh { return lhsFresh }
            return $0.baseRank < $1.baseRank
        }

    return pins + rest
}
