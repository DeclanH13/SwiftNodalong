import SwiftUI

/// The back chevron and any trailing control (the profile avatar, an "Edit"
/// button), floating OVER a screen's content rather than sitting in a band
/// above it.
///
/// Replaces `ScreenHeader`, which reserved roughly 52pt at the top of every
/// screen — frequently to hold nothing but a back chevron. An album detail
/// screen spent that band on one button while its artwork was pushed down and
/// clipped. As an overlay the controls consume no layout space at all, so
/// content starts at the top of the screen and artwork bleeds under the status
/// bar.
///
/// 🔴 **This retired the collapsing-header system.** `CollapsingHeader` existed
/// to animate that band out of the way on scroll, and its insert/remove
/// transition was measured — frame-by-frame, from a device recording — as the
/// direct cause of 50–100ms scroll hitches: ten dropped-frame stalls, every
/// one of them on a header HIDE. With no band there is nothing to collapse, so
/// that entire class of stutter is structurally impossible rather than fixed.
/// A title that needs to scroll away now simply lives in the scroll content.
///
/// 🔴 **Carries `.enablesInteractiveSwipeBack()`, which `ScreenHeader` owned.**
/// This is not incidental. Hiding the navigation bar app-wide also disabled
/// UIKit's edge-swipe-back, and `SwipeBackInstaller` re-asserts the pop-gesture
/// delegate on every update; `SwipeBackGesture.swift` records that
/// `PlaylistDetailView` draws its own header and depends on an ancestor's
/// install to get the gesture at all. Removing the header without carrying
/// this forward is a regression that has already happened once in this
/// codebase. Installing twice is idempotent, so tab roots keeping their own
/// hoisted copy is harmless.
private struct ScreenControls<Trailing: View>: ViewModifier {
    let showsBack: Bool
    let tint: Color
    let onBack: (() -> Void)?
    // Plain stored value, NOT `@ViewBuilder`: the attribute belongs on the
    // `screenControls(trailing:)` parameter below. On a stored property it
    // makes the memberwise init demand a closure instead of a view.
    let trailing: Trailing

    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                HStack(spacing: 10) {
                    if showsBack {
                        Button {
                            if let onBack { onBack() } else { dismiss() }
                        } label: {
                            HeaderGlyph("chevron.left", tint: tint)
                        }
                        .buttonStyle(.plain)
                        // The system back button supplied this for free; a
                        // hand-rolled one must say so or VoiceOver announces a
                        // bare chevron.
                        .accessibilityLabel("Back")
                    }
                    Spacer(minLength: 0)
                    trailing
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                // Only the controls take touches. Without this the transparent
                // full-width HStack would swallow taps and scroll gestures
                // across the top of every screen — the one real hazard of
                // moving from a band to an overlay.
                .allowsHitTesting(true)
            }
            .enablesInteractiveSwipeBack()
    }
}

extension View {
    /// Floats a screen's back chevron and trailing control over its content.
    ///
    /// Apply to the screen's outermost container, so the controls sit above
    /// everything and the content below can scroll freely underneath them.
    ///
    /// - Parameters:
    ///   - showsBack: `false` on tab roots, which have nothing to pop back to.
    ///   - tint: Defaults to `textPrimary`, correct on `bgBase`. The auth
    ///     screens sit on `bgDeep` — a mid-purple in BOTH appearances — where
    ///     `textPrimary` resolves to dark ink in light mode and measures ~2:1
    ///     against it. That exact pairing has already produced one real
    ///     on-device contrast bug, so they pass `textOnAccent`.
    ///   - onBack: Replaces the default single-level `dismiss()`. Exists for
    ///     the artist page, which pops the whole contiguous run of artist
    ///     pages at once (`AppRouter.popArtistRun`) so artist-hopping doesn't
    ///     cost n back presses to leave. **Dropping it silently breaks that
    ///     screen — the chevron is its only trigger.**
    func screenControls<Trailing: View>(
        showsBack: Bool = true,
        tint: Color = Color.nodalong.textPrimary,
        onBack: (() -> Void)? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        modifier(ScreenControls(showsBack: showsBack, tint: tint, onBack: onBack, trailing: trailing()))
    }

    /// Chevron-only convenience — the common case on a pushed screen.
    func screenControls(
        showsBack: Bool = true,
        tint: Color = Color.nodalong.textPrimary,
        onBack: (() -> Void)? = nil
    ) -> some View {
        screenControls(showsBack: showsBack, tint: tint, onBack: onBack) { EmptyView() }
    }
}

/// A heading rendered INSIDE a screen's scroll content, for screens whose
/// title is their only identity — a follow list is otherwise just a list of
/// people, with nothing saying whether it's Followers or Following.
///
/// Deliberately part of the content rather than pinned: it scrolls away under
/// the floating controls, which is the behaviour `CollapsingHeader` spent four
/// attempts trying to fake for a pinned band.
///
/// `.isHeader` because the navigation bar's title used to carry that trait,
/// and VoiceOver's rotor uses it to jump between sections.
struct ScreenTitle: View {
    private let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Font.nodalong.title2Bold)
            .foregroundStyle(Color.nodalong.textPrimary)
            .lineLimit(2)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Clears the floating chevron, which occupies the leading 44pt of
            // the same strip this sits in.
            .padding(.leading, 56)
            .padding(.trailing, 16)
            .padding(.top, 8)
    }
}

/// A 44×44 circular control on frosted glass — the shape the system back
/// button already had under iOS 26's Liquid Glass styling, so replacing it
/// by hand doesn't change the visual language.
///
/// Extracted from `NowPlayingView`'s own top bar (which had this first, for
/// its chevron-down and queue buttons) so there is one definition rather than
/// two that can drift. 44pt is the minimum comfortable hit target, and the
/// frosted backing is what keeps a glyph legible over arbitrary artwork —
/// no fixed colour can, since the backdrop is user content.
struct HeaderGlyph: View {
    private let systemName: String
    private let tint: Color
    init(_ systemName: String, tint: Color = Color.nodalong.textPrimary) {
        self.systemName = systemName
        self.tint = tint
    }

    var body: some View {
        Image(systemName: systemName)
            .font(Font.nodalong.title3Semibold)
            .foregroundStyle(tint)
            .frame(width: 44, height: 44)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(
                Circle().strokeBorder(tint.opacity(0.10), lineWidth: 0.5)
            )
            .contentShape(Circle())
    }
}
