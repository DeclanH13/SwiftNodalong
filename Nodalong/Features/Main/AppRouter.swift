import SwiftUI

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

    private func push<D: Hashable>(_ destination: D, onto tab: Tab) {
        switch tab {
        case .home:   homePath.append(destination)
        case .feed:   feedPath.append(destination)
        case .nearMe: nearMePath.append(destination)
        case .shelf:  shelfPath.append(destination)
        case .search: searchPath.append(destination)
        }
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
    func dismissThenPush<D: Hashable>(_ destination: D, dismiss: @escaping () -> Void) {
        let tab = selectedTab
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.push(destination, onto: tab)
        }
    }
}
