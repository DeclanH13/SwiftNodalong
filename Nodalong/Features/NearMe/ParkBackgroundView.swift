import SwiftUI

/// Decorative park backdrop drawn under the NearMe avatars.
///
/// Pure visuals — no interaction, no hit testing, no collision with avatars.
/// The point is to make the canvas read as "a place" rather than a black void
/// while staying intentionally abstract: real-world coordinates are never
/// shown for privacy reasons, so the park is symbolic, not geographic.
///
/// **Stable per session.** The tree layout is generated from a seeded
/// `SystemRandomNumberGenerator` replacement so re-renders (zoom, pan,
/// lifecycle ticks) don't shift the scenery underneath the avatars. A new
/// seed only kicks in on a new instance — usually a fresh navigation into
/// the tab.
///
/// **Theme.** Sits on top of `Color.nodalong.bgBase`. The gradient picks up
/// a green tint without going daytime-bright; the trees are darker still so
/// they recede behind the avatars rather than competing with them.
struct ParkBackgroundView: View {
    /// Total size of the park canvas — matches whatever `NearMeCanvasView`
    /// is using so the gradient + trees fill it edge to edge.
    let size: CGFloat

    /// Number of decorative tree props. Picked once on init.
    private let trees: [Tree]

    init(size: CGFloat, treeCount: Int = 8, seed: UInt64 = 0xBADC_0FFE_E0DD_F00D) {
        self.size = size
        var rng = SeededRNG(seed: seed)
        // Place trees on a coarse grid + jitter so they look natural but
        // don't clump or overlap heavily. The grid cell is `size / cellsPerSide`
        // wide; each tree lands at a jittered point inside its cell.
        let cellsPerSide = max(2, Int(Double(treeCount).squareRoot().rounded(.up)))
        let cell = size / CGFloat(cellsPerSide)
        var placed: [Tree] = []
        for row in 0..<cellsPerSide {
            for col in 0..<cellsPerSide {
                guard placed.count < treeCount else { break }
                let baseX = CGFloat(col) * cell + cell * 0.5
                let baseY = CGFloat(row) * cell + cell * 0.5
                let jitterX = CGFloat.random(in: -cell * 0.3...cell * 0.3, using: &rng)
                let jitterY = CGFloat.random(in: -cell * 0.3...cell * 0.3, using: &rng)
                let radius  = CGFloat.random(in: 36...62, using: &rng)
                let shade   = CGFloat.random(in: 0.55...0.85, using: &rng)
                placed.append(Tree(
                    x:      baseX + jitterX,
                    y:      baseY + jitterY,
                    radius: radius,
                    shade:  shade
                ))
            }
        }
        self.trees = placed
    }

    var body: some View {
        Canvas { ctx, _ in
            // Base gradient — top-left brighter, bottom-right deeper. Reads
            // as a moonlit lawn over the app's dark theme.
            let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
            let gradient = Gradient(stops: [
                .init(color: Color(red: 0.22, green: 0.36, blue: 0.26), location: 0.0),
                .init(color: Color(red: 0.16, green: 0.28, blue: 0.20), location: 1.0),
            ])
            ctx.fill(
                Path(bgRect),
                with: .linearGradient(
                    gradient,
                    startPoint: .zero,
                    endPoint:   CGPoint(x: size, y: size)
                )
            )

            // Trees — darker green circles with a faint outer shadow so they
            // pop off the lawn slightly without stealing focus from avatars.
            for tree in trees {
                let treeRect = CGRect(
                    x:      tree.x - tree.radius,
                    y:      tree.y - tree.radius,
                    width:  tree.radius * 2,
                    height: tree.radius * 2
                )
                // Shadow
                ctx.fill(
                    Path(ellipseIn: treeRect.offsetBy(dx: 2, dy: 4)),
                    with: .color(Color.black.opacity(0.20))
                )
                // Body — lifted so trees read as deeper-green than the
                // grass without dropping to near-black silhouettes.
                let canopy = Color(
                    red:   0.10 * tree.shade,
                    green: 0.26 * tree.shade,
                    blue:  0.14 * tree.shade
                )
                ctx.fill(Path(ellipseIn: treeRect), with: .color(canopy))
                // Highlight rim — single off-centre ellipse for a hint of
                // dimensionality without spending real lighting math.
                let highlightRect = treeRect
                    .insetBy(dx: tree.radius * 0.25, dy: tree.radius * 0.25)
                    .offsetBy(dx: -tree.radius * 0.15, dy: -tree.radius * 0.15)
                ctx.fill(
                    Path(ellipseIn: highlightRect),
                    with: .color(Color.nodalong.textPrimary.opacity(0.07))
                )
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }

    /// One decorative tree.
    private struct Tree {
        let x:      CGFloat
        let y:      CGFloat
        let radius: CGFloat
        /// Brightness multiplier 0…1, lets different trees shade slightly
        /// differently so the park doesn't look stamped.
        let shade:  CGFloat
    }
}

/// Minimal deterministic RNG so `ParkBackgroundView` lays out the same trees
/// across re-renders within a single `init`. Splitmix64 — small, fast,
/// good-enough distribution for decorative placement (do not use this for
/// anything security-sensitive).
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z &>> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z &>> 31)
    }
}

#if DEBUG
#Preview {
    ZStack {
        Color.nodalong.bgBase.ignoresSafeArea()
        ParkBackgroundView(size: 600)
    }
}
#endif
