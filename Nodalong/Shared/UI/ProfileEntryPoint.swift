import SwiftUI
import NodalongKit

/// Adds a persistent avatar button to a screen's navigation bar that pushes
/// the current user's own `ProfileView` onto THAT screen's navigation
/// stack — so the back button always returns to wherever the user tapped
/// from. Part of Tab Navigation 2.0: Profile is no longer its own tab, but a
/// global entry point reachable from every tab.
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

struct ProfileEntryPoint: ViewModifier {
    @Environment(FirebaseAuthViewModel.self) private var authVM

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(value: OwnProfileRoute()) {
                        AvatarView(
                            emoji: authVM.profile?.avatarEmoji,
                            colorHex: authVM.profile?.avatarColor,
                            size: 30
                        )
                    }
                }
            }
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
    }
}

extension View {
    /// Adds the persistent own-profile avatar button + push destination.
    /// Apply once per tab root (`HomeView`, `FeedView`, `NearMeView`,
    /// `ShelfView`).
    func profileEntryPoint() -> some View {
        modifier(ProfileEntryPoint())
    }
}
