import SwiftUI

/// The app's page background: an animated, "lava lamp" 3×3 mesh built from
/// the brand palette.
///
/// Replaces the flat `Color.nodalong.bgBase` fill every screen used to paint.
/// The flat colour is still the right answer for *cards* and *rows* — this is
/// only for full screens; see `screenBackground()`.
///
/// **Animated, but gated on scene phase — and the gate is the load-bearing
/// part.** This shipped static first, deliberately: the app has a documented
/// jetsam-kill history from sustained background work (the 60 fps NearMe timer,
/// 2026-06-14) and declares `UIBackgroundModes: audio`, so it keeps running
/// while locked. A full-screen GPU layer redrawing forever is exactly that
/// class of cost.
///
/// Motion was asked for afterwards, so the risk is addressed rather than
/// ignored: the drift runs through `TimelineView(.animation(paused:))` keyed on
/// `scenePhase`, which is the same proven-safe mechanism `MiniPlayerBar` uses
/// for its spinning disc. That pattern exists in this codebase precisely
/// because a naive `.repeatForever` there wedged the render server and caused
/// the purple-screen-on-reopen bug. Backgrounded or locked, this stops dead.
///
/// 36 fps, not 60 — bumped a third time (was 20, then 24, then 28) alongside
/// the larger `drift` and shorter periods below, so the now-bigger
/// per-frame delta still reads smooth rather than stepping. Still the same
/// gated `TimelineView`, so the cost is one small constant, not a new class
/// of risk.
///
/// `MeshGradient` is iOS 18+; this project's deployment target is 26.1, so no
/// availability gate is needed. Note it is NOT listed in the SDK's SwiftUI
/// `.swiftinterface` — that file is a partial stub. It was confirmed with a
/// `swiftc -typecheck` probe instead, which is the reliable check.
struct ScreenBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase

    /// How far a point may wander from its resting position, in unit space.
    ///
    /// 0.22 — settled here after going too far the OTHER way. 0.16 read as
    /// barely moving (a real visibility problem: Home's cards are fully
    /// opaque, so only thin strips of mesh are ever exposed, and a small
    /// fixed window onto a drifting canvas mostly shows colour CHANGE, not
    /// visible motion — `pulseOpacity` below exists specifically to read
    /// through that kind of thin gap where positional drift alone doesn't).
    /// Pushing to 0.30 chasing more of it went too far: confirmed on device,
    /// a hard-edged fold/crease artifact appeared in the mesh (most visible
    /// top-right) — exactly the risk named in the margin note below, which
    /// was written as a caution and then not actually heeded before
    /// shipping 0.30. 0.22 is a value that has never itself produced the
    /// artifact. Bumping this at all is purely geometric either way:
    /// `MeshGradient` assigns each `colors` entry to a fixed grid INDEX, not
    /// a fixed screen position, so moving a point around never changes
    /// which colour is there — only where its influence is centred, and how
    /// far it's safe to move it. The contrast analysis on `dark`/`light`
    /// below is per-colour and untouched by any of this.
    private static let drift: Float = 0.22

    /// Peak opacity of the safe-direction breathing overlay (see
    /// `pulseOpacity(at:)`) and how long one breath takes. Deliberately a
    /// SEPARATE, non-matching period from any of the position wobbles below
    /// — a pulse in lockstep with a positional swing would read as one
    /// bigger motion instead of two independent, overlapping ones.
    private static let pulseAmplitude: Double = 0.12
    private static let pulsePeriod: Double = 5.0

    /// Resting 3×3 control grid. Interior points are nudged off-centre so the
    /// blobs read as organic rather than as a symmetrical cross.
    ///
    /// 🔴 How much each point is allowed to move is NOT uniform, and getting it
    /// wrong detaches the mesh from the screen:
    /// - **corners** (0, 2, 6, 8) are locked on both axes;
    /// - **edge midpoints** (1, 3, 5, 7) may slide ALONG their edge only — point
    ///   1 lives on the top edge, so its `x` is free and its `y` must stay 0;
    /// - **the centre** (4) is free in both.
    ///
    /// Move an edge point off its edge and that edge bows inward, exposing
    /// whatever sits behind the mesh at the corners.
    ///
    /// Every drifting value stays comfortably inside 0...1 at this amplitude
    /// (the tightest is 0.40 ± 0.22 → 0.18...0.62) — but staying inside
    /// 0...1 is NOT the same as staying artifact-free, which 0.30 already
    /// disproved (see `drift`'s own doc comment): the centre point (4) moves
    /// on BOTH axes at once, so it's the one that reaches furthest into a
    /// fixed corner's territory, and that's a fold/twist risk a same-axis
    /// edge point doesn't share even at equal amplitude. If more motion is
    /// ever wanted again, treat 0.22 as a real ceiling to re-verify ON
    /// DEVICE past, not a number to raise on the same reasoning that
    /// produced 0.30 — `pulseOpacity` or a finer control grid are the
    /// levers that don't carry this risk at all.
    private static func points(at date: Date) -> [SIMD2<Float>] {
        // 🔴 `t` MUST stay `Double` through the `sin()` call. By 2026,
        // `timeIntervalSinceReferenceDate` is ~811 million — `Float` (32-bit,
        // ~7 significant digits) has no precision left over at that
        // magnitude to represent a sub-second change at all, so an early
        // cast to `Float` silently freezes the oscillation input: `sin()`
        // keeps receiving the same quantized value tick after tick. This is
        // what "mesh visible but not moving" on device actually was —
        // confirmed via a live console capture showing `pt1.x` byte-identical
        // across ticks with `t` itself barely changing. Only the FINAL
        // wobble amount, tiny and magnitude-independent, converts to `Float`.
        let t = date.timeIntervalSinceReferenceDate
        func wobble(phase: Double, period: Double) -> Float {
            Float(Double(drift) * sin(t * (2 * .pi / period) + phase))
        }
        // Periods 3.5-6.5s (down from 6-11s, itself down from 9-16s, itself
        // down from the original 17-25s) — still mutually non-divisible so
        // the axes never sync into a visible pulse; it should read as a
        // lava lamp, not a heartbeat.
        return [
            .init(0.00, 0.00),
            .init(0.55 + wobble(phase: 0.0, period: 4.5), 0.00),
            .init(1.00, 0.00),

            .init(0.00, 0.45 + wobble(phase: 1.7, period: 5.5)),
            .init(0.62 + wobble(phase: 3.1, period: 3.5),
                  0.52 + wobble(phase: 0.9, period: 5)),
            .init(1.00, 0.40 + wobble(phase: 4.6, period: 6.5)),

            .init(0.00, 1.00),
            .init(0.42 + wobble(phase: 2.3, period: 4), 1.00),
            .init(1.00, 1.00)
        ]
    }

    /// A uniform brightness "breath" layered over the whole mesh, oscillating
    /// between fully transparent and `pulseAmplitude` — the fix for what
    /// positional drift alone can't do: read as motion through a THIN gap
    /// between opaque cards, where you can't see a blob's edge sweep past
    /// but you CAN see the whole visible strip brighten and dim uniformly.
    ///
    /// 🔴 Deliberately unidirectional, never symmetric around zero, and
    /// always blends TOWARD the direction that can only ever IMPROVE
    /// contrast, never risk it: black for dark mode (white text gets MORE
    /// separation from a darker background), white for light mode (dark ink
    /// gets MORE separation from a lighter background). Because the peak can
    /// only move contrast in the safe direction from an already-verified
    /// baseline, this needs no per-colour re-check against `dark`/`light`.
    private static func pulseOpacity(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        let raw = sin(t * (2 * .pi / pulsePeriod))  // -1...1
        return pulseAmplitude * (raw * 0.5 + 0.5)   // 0...1, scaled by amplitude
    }

    /// 🔴 Every stop is contrast-checked against the text that sits on it, and
    /// the two modes need genuinely different colours — not the same ramp
    /// inverted.
    ///
    /// Dark mode carries white text, so the LIGHTEST stop is the constraint:
    /// `purpleAccent` (#926897) measures **4.52:1** against white — it passes,
    /// and it is the ceiling. Nothing lighter goes in this array. `purpleMid`
    /// (5.28:1) and `purpleBold` (4.54:1) both pass too and were added for
    /// this pass — two more distinct hues (blue-violet and magenta-violet,
    /// vs `purpleAccent`/`purpleDark`'s own ~264°), so dark mode now draws
    /// from 6 colours instead of 4.
    ///
    /// Light mode carries dark ink (#241542), so the DARKEST stop constrains —
    /// and this is the trap: light `purpleAccent` (#6B4FA0) measures **2.58:1**
    /// and is unusable here, even though its dark-mode counterpart is fine;
    /// `purpleMid`/`purpleBold` fail even harder (1.84:1 / 1.92:1) since they're
    /// action-emphasis tokens meant to sit under LIGHT text, not to host dark
    /// ink. Hence the two arrays share no token by accident: the light mesh is
    /// built only from colours that already bear text elsewhere in the app
    /// (9.02 / 7.26 / 6.04:1) — still just 3, unchanged from before.
    ///
    /// 🔴 **Which colour sits at which of the 9 grid indices was rewritten**,
    /// independent of the point-movement rules above (colour assignment and
    /// point position are unrelated — reordering this never touches `points`).
    /// The previous arrangement repeated a colour across EDGE-ADJACENT indices
    /// in several places — e.g. dark's old bottom row was `bgDeep, bgDeep,
    /// purpleDark`, so indices 6 and 7 were the literal same colour and that
    /// whole edge never actually varied. Both arrays below are now a proper
    /// graph colouring of the 3×3 adjacency grid: no two edge-adjacent indices
    /// share a colour, so there is no flat dead zone anywhere in the mesh —
    /// this is most of what "not very prominent" actually was, independent of
    /// the drift amount.
    ///
    /// Both modes still run lighter at the top and darker at the bottom
    /// (checked at the CORNERS specifically, which anchor the overall
    /// impression) — dark mode's aren't perfectly monotonic row-by-row now
    /// that 6 colours are in play, but the bottom corners are still the
    /// darkest available tone and the top corners the lightest, which also
    /// gives the floating mini player and tab bar a darker field to sit on.
    private static let dark: [Color] = [
        Color.nodalong.purpleAccent, Color.nodalong.purpleBold, Color.nodalong.purpleMid,
        Color.nodalong.purpleMid,    Color.nodalong.bgBase,     Color.nodalong.purpleDark,
        Color.nodalong.bgDeep,       Color.nodalong.purpleDark, Color.nodalong.bgBase
    ]

    private static let light: [Color] = [
        Color.nodalong.bgBase,     Color.nodalong.bgElevated, Color.nodalong.bgBase,
        Color.nodalong.bgElevated, Color.nodalong.bgBase,     Color.nodalong.bgElevated,
        Color.nodalong.bgCard,     Color.nodalong.bgElevated, Color.nodalong.bgCard
    ]

    var body: some View {
        // The A/B that froze this is finished: frame-by-frame analysis of a
        // device recording put all ten dropped-frame hitches on header
        // toggles, not on mesh ticks, so the drift is cleared and restored.
        TimelineView(.animation(minimumInterval: 1.0 / 36.0, paused: scenePhase != .active)) { context in
            MeshGradient(
                width: 3, height: 3,
                points: Self.points(at: context.date),
                colors: scheme == .dark ? Self.dark : Self.light
            )
            .overlay {
                (scheme == .dark ? Color.black : Color.white)
                    .opacity(Self.pulseOpacity(at: context.date))
                    .allowsHitTesting(false)
            }
            .ignoresSafeArea()
        }
    }
}

extension View {
    /// Use in place of `.background(Color.nodalong.bgBase)` on a full SCREEN.
    ///
    /// Cards, rows and carousel containers keep the flat fill — they are
    /// surfaces *on* the page, not the page. `NearMe`'s canvas keeps it too:
    /// the park draws its own procedural scenery and a purple mesh underneath
    /// would fight it.
    func screenBackground() -> some View {
        background(ScreenBackground())
    }

    /// Groups a list of track cards — Feed, and the Recent Tracks / Spotlight
    /// carousels on Profile.
    ///
    /// 🔴 **Deliberately has no fill of its own.** It is spacing, not a
    /// surface: the mesh page background reads straight through, so the cards
    /// float directly on the page.
    ///
    /// This took three wrong answers to land, and they're recorded so nobody
    /// re-adds a fill:
    /// - `bgBase` (original) — the same colour as the flat page, so invisible.
    ///   Fine then; against a mesh it becomes an opaque flat patch punched out
    ///   of the gradient.
    /// - `bgCard` — fixed "invisible" by making it a *visible* opaque patch,
    ///   which is the same problem stated louder.
    /// - `.ultraThinMaterial` — a distinct frosted layer with its own edge, so
    ///   the cards sat on a surface that sat on the mesh. Mesh inside a mesh.
    ///
    /// The cards already carry their own background, corner radius and shadow.
    /// Anything behind them is a second surface nobody asked for.
    ///
    /// `padding(6)` stays: `SpotlightCarousel`'s page-height maths accounts for
    /// it (see `containerPadding` there), so removing it would mis-size that
    /// carousel — the one thing in here that is load-bearing rather than
    /// cosmetic.
    ///
    /// Kept as a named modifier even though it is now one line, so the decision
    /// lives somewhere rather than looking like a stray `padding` at four call
    /// sites.
    func trackListContainer() -> some View {
        padding(6)
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 16) {
        Text("Good evening, bigdeccyh")
            .font(Font.nodalong.title2Bold)
            .foregroundStyle(Color.nodalong.textPrimary)
        Text("Body text over the mesh")
            .font(Font.nodalong.subheadline)
            .foregroundStyle(Color.nodalong.textSecondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .screenBackground()
}
#endif
