import SwiftUI

/// The gold-foil treatment for a spotlit `TrackCard`.
///
/// Replaces the previous "gold border + soft top wash" styling, which read as
/// too subtle — a spotlight is a friend's deliberate one-a-day pick, and it
/// should be unmistakable in a fast scroll.
///
/// **Why a gradient rather than a flat colour.** The app's `gold` token
/// (`#F6BC0C`) is a high-saturation amber and reads as *yellow*, not metal.
/// What sells gold is the light→dark→light banding of a reflective surface,
/// so this is a multi-stop ramp rather than one hex. Deliberately NOT added
/// to the asset catalog: a colorset holds a single colour per appearance, and
/// this ramp only means anything as an ordered sequence.
///
/// The ramp is appearance-independent on purpose. It sits on top of album
/// artwork (arbitrary user content) rather than on the app's own background,
/// so — like the black legibility scrim in `TrackCard` — it must not shift
/// with light/dark mode.
enum SpotlightFoil {

    /// Angled foil sheen. Angle approximates CSS `115deg` — mostly across the
    /// card, tilted slightly down, so the highlight band cuts a diagonal
    /// rather than sitting flat.
    static let sheen = LinearGradient(
        stops: [
            .init(color: Color(hex: "#8E6C1F"), location: 0.00),
            .init(color: Color(hex: "#D4AF37"), location: 0.18),
            .init(color: Color(hex: "#F9F0C8"), location: 0.32),
            .init(color: Color(hex: "#D4AF37"), location: 0.46),
            .init(color: Color(hex: "#8E6C1F"), location: 0.64),
            .init(color: Color(hex: "#C9A227"), location: 0.82),
            .init(color: Color(hex: "#F0DFA0"), location: 1.00),
        ],
        startPoint: UnitPoint(x: 0, y: 0.30),
        endPoint:   UnitPoint(x: 1, y: 0.70)
    )

    /// How much of the album art shows through the foil.
    ///
    /// The art is composited with `.multiply`, so the foil stays dominant and
    /// the art modulates it — the cover reads as pressed INTO the foil rather
    /// than sitting on top. This is the number to tune: higher = more
    /// recognisable artwork, lower = more metal. 0.42 keeps the cover
    /// identifiable while the card still reads gold at a glance.
    static let artworkOpacity: Double = 0.42

    /// Dark ink for anything drawn directly ON the foil (the badge, the
    /// spotlight star). The usual white-on-artwork treatment disappears
    /// against a bright gold card, and the app's own `gold` token would be
    /// gold-on-gold.
    static let ink = Color(hex: "#3B2E08")

    /// Frosted backing for the "Spotlight" badge so its dark ink stays
    /// legible wherever the sheen happens to be darkest.
    static let badgeBacking = Color.white.opacity(0.55)

    /// Outer glow. Warmer and wider than the old `gold`-based one so the card
    /// separates from neighbours in a rail.
    static let glow = Color(hex: "#D4AF37")
}
