import SwiftUI

extension Color {
    enum nodalong {
        // MARK: — Backgrounds
        /// Primary screen background. Also used directly by Feed, the
        /// Recent Tracks carousel, and the Spotlight carousel for their own
        /// OUTER container — those three deliberately merge into the page
        /// rather than reading as a separate surface, so the `TrackCard`
        /// rows inside them (at `bgCard`) are the thing that visually lifts
        /// off the page, not the container around them.
        static let bgBase    = Color("bgBase")
        /// The one shared "everything else" card/container surface — track
        /// rows, list rows, section wrappers, nested sub-sections, tiles.
        /// Two tiers only: `bgBase` (the page, plus the three named
        /// exceptions above) and this. Not used by Feed/Recent Tracks/
        /// Spotlight's own containers — see `bgBase`'s doc comment.
        static let bgCard    = Color("bgCard")
        /// Deepest background — splash and auth screens.
        static let bgDeep    = Color("bgDeep")
        /// Narrow, decorative-only token — used by exactly one place:
        /// `SearchView.genreTiles`' "Hip-hop"/"R&B" entries, part of a
        /// deliberate 4-color mix (alongside `purpleAccent`/`gold`/`error`)
        /// across the genre browse grid, unrelated to the app's container
        /// hierarchy. Was previously that hierarchy's middle tier (nested
        /// inside a now-deleted `bgSurface`); kept at its original value
        /// specifically so those two genre tiles don't silently change
        /// color now that the hierarchy itself has collapsed to `bgBase`/
        /// `bgCard`. Don't reach for this anywhere else — use `bgCard`.
        static let bgElevated = Color("bgElevated")

        // MARK: — Purple scale
        // Each of the four active tokens below is a *distinct hue* within the
        // violet family (not just a lightness step of one shared hue) so
        // different components read as related-but-separate accents. All
        // four are tuned so `textOnAccent` (fixed white) stays legible on top
        // in both light and dark mode — see `textOnAccent`'s doc comment.
        /// Main accent, hue ≈264° — hearts/likes, tab highlights, playlist
        /// and party "Play"/"Join" buttons. The most widely used token.
        static let purpleAccent = Color("purpleAccent")
        /// Bold accent, hue ≈282° (more magenta/orchid) — NearMe's primary
        /// action (a livelier tone for the discovery/exploration feature).
        static let purpleBold   = Color("purpleBold")
        /// Mid accent, hue ≈250° (more blue-violet) — auth CTAs (Sign In,
        /// Create Account, Connect Apple Music, Send Reset Link) and
        /// follow/view-profile buttons (a calmer tone for account actions).
        static let purpleMid    = Color("purpleMid")
        /// Dark accent, hue ≈264° (same hue as `purpleAccent`, richest/
        /// deepest) — brand identity: the mini player pill and Shelf's
        /// syncing banner.
        static let purpleDark   = Color("purpleDark")

        // MARK: — Semantic
        /// Gold / amber — Apple Music badges, spotlight stars.
        static let gold      = Color("gold")
        /// Error — destructive actions and error states.
        static let error     = Color("error")
        /// Apple Music's brand red — fixed, universal (not adaptive per
        /// appearance), used for the "Connect/Connected/Preview Apple Music"
        /// button and its icon badge.
        static let appleMusicRed = Color("appleMusicRed")

        // MARK: — Text
        /// Primary body text / icon tint — adaptive: white in dark mode,
        /// deep plum ink in light mode. Use this instead of `.white` for
        /// any text/icon color that should track the app's own background,
        /// not an absolute color.
        static let textPrimary   = Color("textPrimary")
        /// Secondary body text — 60% opacity, adaptive per appearance.
        static let textSecondary = Color("textSecondary")
        /// Tertiary / hint text — 35% opacity, adaptive per appearance.
        static let textTertiary  = Color("textTertiary")
        /// Text/icon color for content sitting on a filled purple-family
        /// button background (`purpleAccent`/`purpleMid`/`purpleBold`/
        /// `purpleDark`) — fixed white in both appearances. These
        /// backgrounds are tuned for white-on-top contrast in both light
        /// and dark mode, unlike `bgBase`/`bgCard` which are plain
        /// adaptive surfaces meant to pair with `textPrimary`. Using
        /// `textPrimary` (dark ink in light mode) on these buttons instead
        /// would be nearly unreadable — that was a real bug fixed 2026-07-12.
        static let textOnAccent  = Color("textOnAccent")
    }
}

// Hex initialiser used by `AvatarView` and any other dynamic per-user
// accent colour rendering.
extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8)  & 0xFF) / 255
        let b = Double( int        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
