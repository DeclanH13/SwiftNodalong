import SwiftUI

/// Album artwork rendered as a black vinyl disc — a shaded circular
/// "record" with real groove texture, a specular light sheen, a defined
/// outer rim, the real album cover as a smaller inner circle (the "label"),
/// and a tiny spindle hole at the center. Originally built for the artist
/// page's discography grid only; extracted here so any album-artwork
/// context can opt in via `ArtworkThumbnail(isAlbum: true)`, gated behind
/// the user's `AlbumArtworkStyle` setting.
///
/// **Rendering, back to front:** a widened radial base gradient for real
/// curvature, then a groove-texture + specular-sheen composite (the
/// annulus between the label and the outer edge — the two never spatially
/// overlap, so z-order relative to the label doesn't matter in practice), a
/// rim highlight, then the label + spindle on top. Earlier versions of this
/// view drew two groove rings at 0.045 opacity with no sheen at all, which
/// read as a near-flat black circle — the sheen (two opposing light arcs,
/// an `AngularGradient`) is what actually reads as "record" at a glance;
/// the grooves add texture once you're looking closely.
///
/// Uses `ArtworkThumbnail`'s existing `circular: true` support for the
/// inner artwork (deliberately leaving `isAlbum` at its default `false` on
/// that inner call — this is what prevents infinite recursion), so it goes
/// through the same decoded-image cache/blur-up/failure-state handling as
/// every other artwork in the app — nothing new to load or cache here.
///
/// The disc itself renders slightly SMALLER than its allotted `size` and is
/// centered within it (the outer `.frame(width: size, height: size)` keeps
/// the same layout footprint a plain square thumbnail would have) — this is
/// what creates breathing room between two adjacent discs in a grid, on top
/// of whatever gap/padding the grid itself already applies.
///
/// `showsGrooves` defaults `true` (every existing album-context call site —
/// carousels, headers, the artist page's discography — is unaffected).
/// `ArtworkThumbnail(isTrack: true)` passes `false`: a track floating in a
/// mixed-artist list (a playlist, Top Songs, Liked) reads as a distinct,
/// deliberately calmer "small vinyl" at the same pixel sizes an album
/// context can appear at (both can be 44pt) — confirmed via a live preview
/// before implementing, not assumed identical just because the sizes match.
/// The sheen and rim apply REGARDLESS of `showsGrooves` — those are what
/// make it read as a record at all; only the fine groove texture is the
/// album-vs-track distinction.
struct VinylArtworkView: View {
    let url: String
    let size: CGFloat
    var showsGrooves: Bool = true
    /// Bundles two motions that are really one feature, not two independent
    /// toggles: while idle, the disc continuously rocks a few degrees
    /// either way on its flip axis — a literal, running preview of the tap
    /// gesture, not generic ambient motion — and tapping it completes a
    /// full 360° turn back to the same face. Confirmed via three rounds of
    /// live preview before implementing.
    ///
    /// The idle rock is a genuine departure from this app's usual "never
    /// leave a CoreAnimation running while inactive" rule (see
    /// `TrackCard`/`SpinWhilePlaying`'s own doc comments, and the earlier
    /// performance pass this session that removed several similar costs
    /// from Home's carousels) — deliberately scoped to a single view
    /// instance on a single non-scrolling screen (the album detail hero),
    /// not the carousel-density context that motivated the rule. Still
    /// gated on `\.scenePhase` internally via the same `TimelineView`
    /// pattern `SpinWhilePlaying` already proved safe, so it costs nothing
    /// while backgrounded.
    var flipsOnTap: Bool = false

    /// Cumulative rotation in degrees. Grows by a full 360 per completed
    /// flip (not reset to 0 mid-gesture) so the animation always continues
    /// forward from wherever it is; normalized back into 0..<360 with
    /// animations disabled right as each flip completes.
    @State private var flipAngle: Double = 0
    @State private var isFlipping = false
    @Environment(\.scenePhase) private var scenePhase

    init(url: String, size: CGFloat, showsGrooves: Bool = true, flipsOnTap: Bool = false) {
        self.url = url
        self.size = size
        self.showsGrooves = showsGrooves
        self.flipsOnTap = flipsOnTap
    }

    var body: some View {
        // `flipsOnTap` gates whether a gesture recognizer exists AT ALL, not
        // just whether the tap does anything. A prior version attached
        // `.onTapGesture` unconditionally and only no-op'd the closure body
        // for non-interactive instances — but SwiftUI still registers that
        // as a tap target regardless of what the closure does, so it was
        // silently intercepting taps before they ever reached whichever
        // NavigationLink/Button wraps the album tile (every album tile
        // app-wide except the one opted-in hero — Search results, Home
        // rails, Shelf grids, artist discography), breaking navigation into
        // an album everywhere except that one screen. Branching here means
        // every non-interactive instance has zero gesture recognizers, the
        // same as before this feature existed.
        Group {
            if flipsOnTap {
                animatedDisc
                    .contentShape(Circle())
                    .onTapGesture { flip() }
            } else {
                animatedDisc
            }
        }
    }

    private var animatedDisc: some View {
        let discSize = size * 0.88
        let labelSize = discSize * 0.44

        // Paused (not ticking at all) whenever `flipsOnTap` is false — which
        // is every `isAlbum: true` disc app-wide EXCEPT the one opted-in
        // hero. Without this, the TimelineView still renders at least one
        // frame even while "paused" on entry, which would freeze every one
        // of those discs at whatever `idleTiltDegrees` happened to evaluate
        // to at that instant — a fixed, seemingly random tilt rather than
        // the flat disc every non-interactive context expects. The
        // `flipsOnTap ? … : 0` below is the actual correctness fix; the
        // `!flipsOnTap` pause condition is what stops those instances from
        // doing any per-frame work in the first place.
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                        paused: !flipsOnTap || isFlipping || scenePhase != .active)) { context in
            disc(discSize: discSize, labelSize: labelSize)
                .rotation3DEffect(
                    .degrees(flipsOnTap ? (isFlipping ? flipAngle : idleTiltDegrees(at: context.date)) : 0),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.35
                )
        }
    }

    private func flip() {
        guard !isFlipping else { return }
        isFlipping = true
        let target = flipAngle + 360
        withAnimation(.timingCurve(0.45, 0.05, 0.15, 1.0, duration: 0.85),
                      completionCriteria: .logicallyComplete) {
            flipAngle = target
        } completion: {
            // Disable animations explicitly — a plain assignment here
            // would inherit the just-finished `withAnimation` context
            // and visibly spin back to the equivalent angle.
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                flipAngle = target.truncatingRemainder(dividingBy: 360)
            }
            isFlipping = false
        }
    }

    @ViewBuilder
    private func disc(discSize: CGFloat, labelSize: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(white: 0.20), Color.black],
                        center: UnitPoint(x: 0.36, y: 0.33),
                        startRadius: 0,
                        endRadius: discSize * 0.75
                    )
                )
            grooveAndSheen(discSize: discSize, labelSize: labelSize)
            Circle()
                .strokeBorder(Color.white.opacity(0.13), lineWidth: 0.5)
            ArtworkThumbnail(url: url, size: labelSize, circular: true)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            Circle()
                .fill(Color.black)
                .frame(width: 6, height: 6)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
        }
        .frame(width: discSize, height: discSize)
        // Scales with size — a whisper of lift at 44pt, real depth at a
        // hero size, rather than one constant shadow that's either
        // invisible on small discs or too heavy on large ones.
        .shadow(color: .black.opacity(0.4), radius: size * 0.045, y: size * 0.015)
        .frame(width: size, height: size)
    }

    /// Pure function of wall-clock time — a cosine wave hits -amplitude at
    /// phase 0, +amplitude at phase 0.5, back to -amplitude at phase 1, so
    /// the disc rocks smoothly through center in both directions rather
    /// than dipping only one way.
    private func idleTiltDegrees(at date: Date) -> Double {
        let period: Double = 4.0
        let amplitude: Double = 13.0
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: period) / period
        return -amplitude * cos(phase * 2 * .pi)
    }

    /// Grooves and the specular sheen are drawn together, in one `Canvas`
    /// pass, over the whole disc — one draw call regardless of groove
    /// count. The obvious alternative, a `ForEach` of `Circle().strokeBorder`
    /// rings, would put ~40 individual views inside every disc; Home alone
    /// renders a dozen album tiles at once, which is exactly the view-tree
    /// cost the performance pass removed from this app's carousels.
    ///
    /// Groove spacing is a constant PITCH (`groovePitch`), not a fixed
    /// count — so a 44pt disc gets a handful of grooves and a hero-sized
    /// one gets ~40, the same physical texture at every size, instead of
    /// either moiré noise when small or four lonely rings when large.
    @ViewBuilder
    private func grooveAndSheen(discSize: CGFloat, labelSize: CGFloat) -> some View {
        Canvas { ctx, canvasSize in
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            guard showsGrooves else { return }

            let outerR = discSize / 2 * 0.965
            // Deadwax — the smooth, groove-free run-out band between the
            // last groove and the label. Real records have one; omitting it
            // was part of why the previous version read as a flat texture
            // swatch rather than a pressed record.
            let innerR = labelSize / 2 * 1.32
            guard outerR > innerR else { return }

            let count = Int((outerR - innerR) / Self.groovePitch)
            guard count > 0 else { return }

            for i in 0..<count {
                let r = innerR + CGFloat(i) * Self.groovePitch
                // Every third ring slightly brighter — pure even spacing at
                // one opacity reads as a mechanical screen-door pattern
                // rather than pressed vinyl.
                let opacity = (i % 3 == 0) ? 0.085 : 0.05
                ctx.stroke(
                    Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r,
                                            width: r * 2, height: r * 2)),
                    with: .color(.white.opacity(opacity)),
                    lineWidth: 0.5
                )
            }
        }
        .allowsHitTesting(false)

        // Two opposing light arcs — the single biggest contributor to
        // reading as vinyl rather than a dark circle. Applies regardless of
        // `showsGrooves`; a groove-less "small vinyl" track disc still
        // benefits from catching light.
        AngularGradient(
            gradient: Gradient(stops: [
                .init(color: .white.opacity(0.13), location: 0.00),
                .init(color: .white.opacity(0.00), location: 0.17),
                .init(color: .white.opacity(0.03), location: 0.33),
                .init(color: .white.opacity(0.15), location: 0.50),
                .init(color: .white.opacity(0.00), location: 0.67),
                .init(color: .white.opacity(0.03), location: 0.83),
                .init(color: .white.opacity(0.13), location: 1.00),
            ]),
            center: .center,
            angle: .degrees(210)
        )
        .clipShape(Circle())
        .allowsHitTesting(false)
    }

    private static let groovePitch: CGFloat = 3
}
