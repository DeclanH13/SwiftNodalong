import SwiftUI

/// Rebuilds its content once, right after it first appears.
///
/// A paging `TabView` (`.tabViewStyle(.page)`) that already has its pages
/// when it is first built inside a scroll view draws BLANK, and stays blank
/// until something rebuilds it. Seen on device 2026-10-30: Profile's
/// Spotlight and Recent Tracks carousels (seeded from the snapshot in
/// `ProfileView.init`) showed an empty area until the background refresh
/// landed, and the artist page's Top Songs drew an empty card when seeded in
/// `init`. Content that arrived a moment AFTER appearing never hit it, which
/// is why it only surfaced once screens started painting from cache.
///
/// Rebuilding once after `onAppear` means the pager is constructed while it
/// is already in place, exactly as the late-arriving case was. Costs one
/// frame — far less than waiting for the network to force the rebuild.
private struct RemountOnAppear: ViewModifier {
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .id(appeared)
            .onAppear { appeared = true }
    }
}

extension View {
    /// See `RemountOnAppear`. Apply to a paging `TabView` that can be handed
    /// its content before it first appears.
    func remountOnAppear() -> some View { modifier(RemountOnAppear()) }
}
