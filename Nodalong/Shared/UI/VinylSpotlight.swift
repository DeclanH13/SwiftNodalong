import SwiftUI

/// A stage light hung directly above a vinyl disc, pointing straight down —
/// a soft beam narrowing to a point off the top of the screen, and a faint
/// pool of light spilling onto the surface the record sits on.
///
/// Deliberately paints nothing ON the record itself. An earlier version added
/// a lit band across its top edge; against real cover art that read as a
/// wash sitting on the vinyl rather than light falling across it, and
/// `VinylArtworkView` already has its own base gradient and specular sheen
/// doing that job. The light stays in the air and on the floor.
///
/// Applied via `.vinylSpotlight(size:isEnabled:)` to the album detail hero,
/// and deliberately nowhere else: this is a single deliberate focal point on
/// one non-scrolling screen, not an effect every album tile in the app wears.
///
/// One thing about the composition is load-bearing rather than stylistic: the
/// beam is a `.background` applied AFTER the hero's own `.clipShape`. A beam
/// drawn inside that clip is cut off flat at the artwork's frame, which is
/// exactly the shape of light you don't want — the point of a beam is that it
/// comes from somewhere above. `.background` content is free to render outside
/// its host's bounds, so it reaches up into the headroom the hero reserves.
///
/// The pool's geometry derives from `VinylArtworkView.discScale` rather than a
/// second hardcoded `0.88`, so it can't drift out of alignment with the disc
/// it sits under if that ever changes.
struct VinylSpotlight: ViewModifier {
    /// The artwork slot size — the same value handed to `ArtworkThumbnail`.
    /// The disc inside it is `size * VinylArtworkView.discScale`.
    let size: CGFloat
    /// False in square-artwork mode: a beam and a round pool of light under a
    /// flat square cover reads as staging for something that isn't there.
    var isEnabled: Bool = true

    /// Light mode's background is a pale mauve, so white light has far less
    /// to work against and the same opacities read as a grey smudge rather
    /// than a beam. Scaled down rather than switched off — the effect still
    /// reads, just quieter.
    @Environment(\.colorScheme) private var colorScheme
    private var intensity: Double { colorScheme == .dark ? 1.0 : 0.78 }

    /// How far above the artwork slot the beam reaches. The hero reserves
    /// matching headroom (`AlbumDetailSearchView.spotlightHeadroom`) so the
    /// beam has somewhere to go instead of being clipped by the scroll view.
    static func beamHeight(for size: CGFloat) -> CGFloat { size * 0.30 }

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .background(alignment: .bottom) { beamAndPool }
        } else {
            content
        }
    }

    /// Drawn BEHIND the disc: the beam in the air above it, plus the pool of
    /// light spilling onto the surface around its base. Behind rather than in
    /// front so the record is never seen through a haze — it keeps its own
    /// contrast, and the light reads as passing around it.
    private var beamAndPool: some View {
        let beam = Self.beamHeight(for: size)
        let disc = size * VinylArtworkView.discScale

        return ZStack {
            // Light spilling onto the surface UNDER the record. The disc is
            // centred in the slot, so its base is `disc / 2` below centre —
            // offsetting by anything less puts this band across the middle of
            // the record instead, which reads as a smear on the vinyl rather
            // than light on the floor beneath it.
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.16 * intensity), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: disc * 0.5
                    )
                )
                .frame(width: disc * 1.05, height: disc * 0.16)
                .offset(y: disc * 0.52)

            BeamShape()
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.34 * intensity),
                            .white.opacity(0.15 * intensity),
                            .white.opacity(0.0),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: size, height: beam + size * 0.55)
                .blur(radius: size * 0.035)
                .frame(height: beam + size, alignment: .top)
                .offset(y: -beam)
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }

}

/// The cone itself: near-a-point at the top (the light source is off-screen
/// above), opening out to the full width by the time it reaches the record.
private struct BeamShape: Shape {
    /// Fraction of the width the beam occupies at its narrow end.
    var topWidth: CGFloat = 0.10

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let halfTop = rect.width * topWidth / 2
        path.move(to: CGPoint(x: rect.midX - halfTop, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX + halfTop, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

extension View {
    /// Hangs a spotlight above a vinyl hero. Apply AFTER any `.clipShape` on
    /// the artwork, or the beam is cut off at the artwork's own frame.
    func vinylSpotlight(size: CGFloat, isEnabled: Bool = true) -> some View {
        modifier(VinylSpotlight(size: size, isEnabled: isEnabled))
    }
}
