import SwiftUI

/// The standard boxed-E explicit-content mark, matching the convention other
/// music apps use — shown inline next to a title, never stamped on the
/// artwork itself.
///
/// Deliberately the Unicode glyph rather than a drawn shape or an SF Symbol:
/// it renders identically everywhere and needs no asset. It stays on
/// `.system` for the same reason emoji do elsewhere in this app — Quicksand
/// has no glyph for it, so `Font.nodalong` would fall back anyway.
///
/// Originated as a private `explicitBadge` inside `ArtistDetailSearchView`,
/// which was the only screen showing it at all. Extracted here when the mark
/// was rolled out to every album surface, so there is one definition rather
/// than a copy per site.
struct ExplicitBadge: View {
    var body: some View {
        Text("🅴")
            .font(Font.nodalong.caption)
            .foregroundStyle(Color.nodalong.textSecondary)
            .fixedSize()
            .accessibilityLabel("Explicit")
    }
}
