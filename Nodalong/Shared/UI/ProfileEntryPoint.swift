import SwiftUI
import NodalongKit

/// Adds a persistent entry point to a screen that pushes the current user's
/// own `ProfileView` onto THAT screen's navigation stack — so the back
/// button always returns to wherever the user tapped from. Part of Tab
/// Navigation 2.0: Profile is no longer its own tab, but a global entry
/// point reachable from every tab (via `ProfileAvatarButton`/
/// `ProfileAvatarRow`, below).
///
/// Self-contained (owns its own presentation state), so it composes safely
/// alongside any other `.navigationDestination` a host screen already has —
/// multiple `.navigationDestination` triggers (type-based and boolean-based)
/// can coexist on one `NavigationStack`.
/// Push value for the user's own profile.
///
/// Exists so this entry point can be a plain `NavigationLink(value:)` rather
/// than `.navigationDestination(isPresented:)`.
struct OwnProfileRoute: Hashable {}

/// The user's own avatar, always in the top-trailing corner of a tab root as
/// ordinary layout rather than a floating overlay — so it can never overlap
/// other content. A single tap opens Profile.
///
/// Supersedes `ProfileAvatarPeek`'s two-tap reveal: that existed solely to
/// protect against a mis-tap on a sliver that sat over real content, and
/// once the avatar has its own reserved space there's nothing left to
/// protect against.
struct ProfileAvatarButton: View {
    @Environment(FirebaseAuthViewModel.self) private var authVM
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        Button {
            router.push(OwnProfileRoute(), onto: router.selectedTab)
        } label: {
            AvatarView(
                emoji: authVM.profile?.avatarEmoji,
                colorHex: authVM.profile?.avatarColor,
                size: 34
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Your profile")
    }
}

/// A dedicated top-right row holding just the avatar — the ONE placement
/// every tab root uses (`HomeView`, `FeedView`, `SearchView`, `ShelfView`,
/// `NearMeView`), always as the first row of the screen's content, so the
/// avatar lands in the same spot on all five.
///
/// Deliberately inline content, never a `.screenControls(trailing:)`
/// floating overlay. An overlay is pinned to the screen while Search's and
/// Shelf's headers scroll, so at some offsets it sat on top of the search
/// bar or the segmented picker. Reserving real space is the only version
/// that structurally cannot overlap anything. On the four scrolling tabs it
/// scrolls away with the rest of the header; NearMe's header doesn't
/// scroll, so there it simply stays put.
struct ProfileAvatarRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Spacer()
            InboxBellButton()
            ProfileAvatarButton()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

/// Registers the own-profile push destination. The avatar that triggers it is
/// now `ProfileAvatarButton`/`ProfileAvatarRow`, placed in each tab root's
/// own layout — the two are separate because the destination must be a
/// modifier on the stack while the button is ordinary content.
struct ProfileEntryPoint: ViewModifier {
    func body(content: Content) -> some View {
        content
            // Value-based, NOT `.navigationDestination(isPresented:)`.
            //
            // The boolean form was the root of a long-running navigation
            // problem. Round 9.5 recorded that pushing a value-based
            // destination ON TOP of a boolean-pushed screen misbehaves —
            // and `ProfileView` is boolean-pushed from here, so EVERY value
            // push downstream of it was affected: Followers/Following, and
            // then tapping a name inside that list (which did nothing at
            // all). Round 9.5 worked around it per-screen with
            // `.navigationDestination(item:)`, but that has its own failure
            // (Round 9.9: an item-bound destination re-presents itself when
            // something is pushed on top of it), so the two workarounds just
            // trade one bug for the other.
            //
            // Fixing the boolean push at the source makes the whole chain
            // uniformly value-based — tab root → own profile → follow list →
            // someone's profile — which is the shape SwiftUI actually
            // handles correctly, and removes the need for either workaround.
            .navigationDestination(for: OwnProfileRoute.self) { _ in
                ProfileView()
            }
            .navigationDestination(for: InboxRoute.self) { _ in
                InboxView()
            }
    }
}

extension View {
    /// Registers the own-profile push destination. Apply once per tab root
    /// (`HomeView`, `FeedView`, `NearMeView`, `ShelfView`, `SearchView`);
    /// pair it with a `ProfileAvatarButton`/`ProfileAvatarRow` in that
    /// screen's own layout.
    func profileEntryPoint() -> some View {
        modifier(ProfileEntryPoint())
    }
}
