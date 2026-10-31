import SwiftUI
import NodalongKit

/// Which *screen* a pushed value lands on — deliberately not the value itself.
///
/// `PendingArtistResolve` (from the player), `PendingArtistLookup` (from an
/// album screen) and `ArtistResult` (from Similar Artists) are three different
/// types that all open the **same artist page**, so value equality can never
/// recognise the duplicate no matter how well the stack is tracked. A
/// normalized identity can. This is what a device log finally showed: six
/// `ArtistDetailSearchView` appearances against one router artist push.
///
/// Normalized through the same helpers the rest of the app groups by
/// (`primaryArtist`, `stripSearchNoise`), so "same artist" means here exactly
/// what it means in `groupByAlbum` / `groupByArtist`.
enum NavIdentity: Hashable {
    case artist(String)
    case album(String)

    static func artist(name: String) -> NavIdentity {
        .artist(primaryArtist(name).lowercased())
    }

    static func album(name: String, artist: String) -> NavIdentity {
        .album("\(stripSearchNoise(name).lowercased())|\(primaryArtist(artist).lowercased())")
    }
}

/// App-wide navigation coordinator — owns which tab is selected and each
/// tab's own push/pop stack, plus a "dismiss whatever cover is up, then
/// navigate wherever the user was" helper.
///
/// Before this, every tab (`HomeView`/`FeedView`/`SearchView`/`ShelfView`)
/// owned a PRIVATE `@State var path = NavigationPath()` — nothing outside
/// that tab's own struct could push onto it, and `NearMeView` had no
/// programmatic path at all. That made it impossible for `NowPlayingView`/
/// `PartyView` (both `.fullScreenCover`s hung off `MainTabView`) to ever
/// hand off to a tab's own navigation — any further content had to be
/// nested as a `.sheet` on top of the cover instead, which cut the tab bar
/// and mini player off entirely (they live in `MainTabView`, several
/// presentation layers below). Centralizing the paths here is what makes
/// "dismiss the cover, then push onto whichever tab the user was on"
/// possible for the first time.
///
/// Lives as a `@StateObject` on `MainTabView` (NOT the `NodalongApp` root,
/// unlike `PlayerViewModel`) — `MainTabView` is reconstructed on every
/// sign-in, and this resetting along with that reconstruction matches the
/// previous private `@State private var selectedTab`'s own lifecycle
/// exactly. Reachable from `NowPlayingView`/`PartyView` via
/// `.environmentObject` despite being declared after their
/// `.fullScreenCover` modifiers in `MainTabView`'s chain — environment
/// injection doesn't care about modifier ordering.
@MainActor
final class AppRouter: ObservableObject {
    enum Tab: Int, Hashable, CaseIterable {
        case home = 0, feed = 1, nearMe = 2, shelf = 3, search = 4
    }

    @Published var selectedTab: Tab = .home

    // One path per tab — mirrors the per-tab-private `@State` every tab
    // used to own individually (NearMe had none at all).
    @Published var homePath   = NavigationPath()
    @Published var feedPath   = NavigationPath()
    @Published var nearMePath = NavigationPath()
    @Published var shelfPath  = NavigationPath()
    @Published var searchPath = NavigationPath()

    /// Bumped each time a tab is re-tapped while already at its root. A tab's
    /// scroll view watches its own entry and scrolls to the top when it changes.
    /// A counter rather than a Bool so two consecutive requests are two
    /// distinct values — see `ReturnEvent.seq` for the same reasoning.
    @Published private(set) var scrollToTopRequests: [Tab: Int] = [:]

    /// Every write to the tab selection comes through here.
    ///
    /// Confirmed on a device (iOS 27) that tapping the tab you are ALREADY on
    /// reaches this setter with a value equal to the current one — which is
    /// the only way SwiftUI's `TabView` exposes a re-tap.
    func tabSelectionSet(_ new: Tab) {
        if new == selectedTab {
            tabReselected(new)
        } else {
            selectedTab = new
        }
    }

    /// Re-tapping the current tab: go BACK first, and only when there is
    /// nothing left to go back to, scroll to the top.
    ///
    /// "Back" is all the way to the tab's root, which is what iOS already did
    /// on its own for Home (the device log showed the stack going from depth 1
    /// to 0 after a re-tap with no code of ours involved). Doing it explicitly
    /// makes the behaviour the same on every tab instead of resting on a system
    /// behaviour observed only on one — and the depth is checked BEFORE the
    /// pop, so the tap that takes you back never also scrolls.
    func tabReselected(_ tab: Tab) {
        reconcile(tab)
        let depth = path(for: tab).count
        if depth > 0 {
            removeLast(depth, from: tab)
            reconcile(tab)
        } else {
            scrollToTopRequests[tab, default: 0] += 1
        }
    }

    /// One deliberate return to an already-open screen — see `returnedTo`.
    struct ReturnEvent: Equatable {
        let identity: NavIdentity
        /// Distinguishes two consecutive returns to the SAME screen —
        /// without it the second event is `==` the first and an
        /// `.onChange` observer never fires again.
        let seq: Int
    }

    /// Bumped whenever `push` returns to an already-open screen instead of
    /// stacking a copy on top of it. A screen that cares reads this to reset
    /// itself — you asked for that page, so you land at the top of it, not
    /// wherever you happened to be scrolled when you left it.
    ///
    /// Deliberately NOT fired for a system back-button pop, which the router
    /// never sees anyway: backing out of a screen you pushed yourself should
    /// leave you exactly where you were, which is what iOS does everywhere else.
    @Published private(set) var returnedTo: ReturnEvent?
    private var returnSeq = 0

    /// One slot per level of that tab's `NavigationPath`; `nil` where something
    /// pushed without an identity (a `NavigationLink` we don't own).
    ///
    /// `NavigationPath` is opaque — you can read `.count` but never its
    /// elements — so this shadow is reconciled against that count before every
    /// operation. Pops only ever remove from the top, so a shrunk count means
    /// truncate; a grown one means a link pushed something we never saw, which
    /// is padded with `nil` rather than guessed at.
    private var stack: [Tab: [NavIdentity?]] = [:]

    private func path(for tab: Tab) -> NavigationPath {
        switch tab {
        case .home:   return homePath
        case .feed:   return feedPath
        case .nearMe: return nearMePath
        case .shelf:  return shelfPath
        case .search: return searchPath
        }
    }

    private func append<D: Hashable>(_ destination: D, to tab: Tab) {
        switch tab {
        case .home:   homePath.append(destination)
        case .feed:   feedPath.append(destination)
        case .nearMe: nearMePath.append(destination)
        case .shelf:  shelfPath.append(destination)
        case .search: searchPath.append(destination)
        }
    }

    private func removeLast(_ k: Int, from tab: Tab) {
        switch tab {
        case .home:   homePath.removeLast(k)
        case .feed:   feedPath.removeLast(k)
        case .nearMe: nearMePath.removeLast(k)
        case .shelf:  shelfPath.removeLast(k)
        case .search: searchPath.removeLast(k)
        }
    }

    private func reconcile(_ tab: Tab) {
        let depth = path(for: tab).count
        var s = stack[tab] ?? []
        if s.count > depth { s.removeLast(s.count - depth) }
        while s.count < depth { s.append(nil) }
        stack[tab] = s
    }

    /// Pushes `destination` — or, when a screen with the same `identity` is
    /// already open further back, **returns to that screen** instead of
    /// stacking a copy on top of it.
    ///
    /// Identity rather than value equality is the whole point: three different
    /// types push the same artist page, so the previous value-based dedup could
    /// only ever catch the same type twice in a row. A device log showed it
    /// working exactly that far and no further — one `DEDUPED` for a repeated
    /// album, then `valueEqual=false` on every album↔artist alternation.
    ///
    /// A push with **no** identity behaves exactly as before (plain append), so
    /// nothing that works today changes.
    func push<D: Hashable>(_ destination: D, identity: NavIdentity? = nil, onto tab: Tab) {
        reconcile(tab)

        if let identity, let existing = stack[tab]?.firstIndex(of: identity) {
            let toPop = path(for: tab).count - existing - 1
            // TEMPORARY [Nodalong.Nav] — remove with the rest of the nav
            // diagnostics once this is confirmed on device.
            navLog("nav.push POPPED-TO \(identity) tab=\(tab) from=\(path(for: tab).count) to=\(existing + 1)")
            if toPop > 0 { removeLast(toPop, from: tab) }
            reconcile(tab)
            returnSeq += 1
            returnedTo = ReturnEvent(identity: identity, seq: returnSeq)
            return
        }

        append(destination, to: tab)
        stack[tab, default: []].append(identity)
        // TEMPORARY [Nodalong.Nav] — see above.
        navLog("nav.push PUSHED \(D.self) id=\(identity.map { "\($0)" } ?? "none") tab=\(tab) depth=\(path(for: tab).count)")
    }

    /// Tells the router what screen is currently on top, for a push it never
    /// saw.
    ///
    /// `NavigationLink(value:)` pushes straight onto the path without going
    /// through `push`, so the shadow stack records `nil` for that level and
    /// the dedup has nothing to match against — which is why opening an album
    /// from a carousel and then choosing "Album" in that album's own "…" menu
    /// stacked a second copy of the screen you were already looking at.
    ///
    /// A screen calls this from `onAppear` to fill in its own slot. Only ever
    /// fills a `nil` one: a slot the router set itself is authoritative, and a
    /// late `onAppear` arriving after something else was pushed must not
    /// overwrite that newer screen's identity with its own.
    func claimTopIdentity(_ identity: NavIdentity, onto tab: Tab) {
        reconcile(tab)
        let depth = path(for: tab).count
        guard depth > 0, stack[tab]?[depth - 1] == nil else { return }
        stack[tab]?[depth - 1] = identity
        // TEMPORARY [Nodalong.Nav] — remove with the rest of the nav
        // diagnostics once this is confirmed on device.
        navLog("nav.claimTopIdentity \(identity) tab=\(tab) depth=\(depth)")
    }

    /// Pops the whole contiguous run of artist pages at the top of `tab`'s
    /// stack, so backing out of `artist → similar artist → similar artist`
    /// lands on whatever you were doing before you started artist-hopping
    /// rather than walking you out through n of them.
    ///
    /// This is where the artist-chain collapse lives, rather than in `push`.
    /// Replacing the top of the stack on the way IN (pop + append in one
    /// update, leaving the depth unchanged) is what SwiftUI has nothing to
    /// animate — it swaps the screen with no transition at all, which read as
    /// jarring on device. Pushing normally keeps the real system slide for
    /// free and moves the collapse to the one place it's actually observable.
    ///
    /// Only definite `.artist` slots count. A `nil` slot is a link push the
    /// router never saw, and a run that walks past one could swallow a screen
    /// it knows nothing about — so it stops there and pops the single level a
    /// plain back would have, same fail-open asymmetry as `push`'s dedup.
    ///
    /// Returns `false` when there is nothing on this tab's stack to pop, so
    /// the caller can fall back to its own `dismiss()` (this screen might be
    /// presented somewhere the router doesn't own).
    @discardableResult
    func popArtistRun(onto tab: Tab) -> Bool {
        reconcile(tab)
        let depth = path(for: tab).count
        guard depth > 0 else { return false }

        var run = 0
        var slots = stack[tab] ?? []
        while let last = slots.last, let identity = last, case .artist = identity {
            slots.removeLast()
            run += 1
        }

        let toPop = min(max(run, 1), depth)
        // TEMPORARY [Nodalong.Nav] — remove with the rest of the nav
        // diagnostics once this is confirmed on device.
        navLog("nav.popArtistRun tab=\(tab) run=\(run) popping=\(toPop) from=\(depth)")
        removeLast(toPop, from: tab)
        reconcile(tab)
        return true
    }

    /// Pushes onto whichever tab is selected right now. For a push that happens
    /// after an `await`, prefer the explicit `onto:` form — the user may have
    /// changed tabs in the meantime.
    func push<D: Hashable>(_ destination: D, identity: NavIdentity? = nil) {
        push(destination, identity: identity, onto: selectedTab)
    }

    /// Dismisses whatever full-screen cover is currently up, waits for its
    /// dismiss animation (the same `0.35s` constant already established by
    /// the existing Queue→Party cover swap in `NowPlayingView`), then
    /// pushes `destination` onto whichever tab was selected AT THE MOMENT
    /// OF THE CALL — captured up front, not re-read after the delay, so a
    /// fast tab switch mid-animation can't steal the push. `dismiss` is a
    /// closure so this stays ignorant of which view model's flag actually
    /// needs flipping (`playerVM.isExpanded`, `partyVM.presenting`, ...).
    ///
    /// **Accepted trade-off**: this reintroduces the ~0.35s wait the old
    /// instant-sheet-on-top-of-the-cover pattern didn't have — there is no
    /// way to both stay inside the modal stack (for zero-latency
    /// presentation) AND reach a tab's own navigation (which requires
    /// leaving the modal stack first). See the decisions log for the
    /// round this was accepted in.
    func dismissThenPush<D: Hashable>(
        _ destination: D,
        identity: NavIdentity? = nil,
        dismiss: @escaping () -> Void
    ) {
        let tab = selectedTab
        // TEMPORARY [Nodalong.Nav] — see `push(_:identity:onto:)`.
        navLog("nav.dismissThenPush \(D.self) tab=\(tab)")
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.push(destination, identity: identity, onto: tab)
        }
    }
}
