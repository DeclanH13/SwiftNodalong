import SwiftUI
import NodalongKit

/// User avatar — a character on a coloured circle.
///
/// **Render paths**, picked automatically:
/// 1. **PNG asset** (preferred) — if `Assets.xcassets` contains an image
///    named `"avatar_<key>"` (e.g. `"avatar_cat"` for `🐱`), it renders as
///    the avatar foreground. This is how richer character art lands once
///    it exists; the asset catalog drives the lookup, no code change
///    needed.
/// 2. **Emoji fallback** — if no PNG asset exists for the user's pick, the
///    raw emoji character renders instead. Lets the app work end-to-end
///    today.
///
/// **Animation modes** — picked by the `animated` flag:
/// - `animated == false` (default) → flat, static avatar. Used everywhere
///   except the NearMe canvas: profile rows, search results, follow lists,
///   sheets. Calm UI; no motion that distracts from surrounding content.
/// - `animated == true` → procedural "3D-feel" treatment with depth
///   styling and continuous animation. The animation reacts to two
///   optional inputs from the canvas:
///     * `animState` (`.wandering` / `.listening` / `.bumping`) drives the
///       per-frame behaviour:
///         - wandering → slow breathe + 3D tilt (default idle)
///         - listening → side-to-side head sway, slightly raised neck
///         - bumping   → squash-and-stretch pop
///     * `lifecycle` (`.entering` / `.alive` / `.leaving`) drives a one-
///       shot entrance / exit motion:
///         - entering → scale-up pop with a soft ripple ring (~0.6s)
///         - alive    → the per-frame animation above
///         - leaving  → calm fade + scale-down (~0.6s)
///
/// **Future swap path.** When richer assets land (Rive rigs, USDZ models,
/// AI-rendered portraits, hand-drawn PNGs), the call sites do not change.
/// Swap the `foreground` ViewBuilder to a new render path and every place
/// in the app picks it up. Per the 2026-06-07 decision log entry, Spline
/// was tried and dropped — the next experiment goes here.
struct AvatarView: View {
    let emoji: String
    let colorHex: String
    var size: CGFloat = 50

    /// When `true`, applies 3D depth styling + continuous procedural
    /// animation. Used by the NearMe canvas. Defaults to `false` — every
    /// other call site renders flat.
    var animated: Bool = false

    /// Per-frame behaviour state — `wandering` (default), `listening`,
    /// `bumping`. Only consulted when `animated == true`. Optional so flat
    /// call sites don't need to construct it.
    var animState: AvatarAnimState = .wandering

    /// Lifecycle phase — `entering`, `alive`, `leaving`. Only consulted
    /// when `animated == true`. Optional so flat call sites don't need to
    /// construct it.
    var lifecycle: AvatarLifecycle = .alive

    /// Asset name derived from the chosen emoji, e.g. `🐱` → `"avatar_cat"`.
    /// Empty when no mapping exists (uncommon — every entry in the curated
    /// `userAvatarEmojis` palette maps).
    private var assetName: String { Self.assetMapping[emoji] ?? "" }

    /// `true` when `Assets.xcassets` actually contains an image for this
    /// avatar. Cheap check — UIKit caches `UIImage(named:)` lookups.
    private var hasAsset: Bool {
        !assetName.isEmpty && UIImage(named: assetName) != nil
    }

    /// Convenience initialiser from optionals so call sites can pass raw
    /// profile fields without unwrapping.
    init(
        emoji: String?,
        colorHex: String?,
        size: CGFloat = 50,
        animated: Bool = false,
        animState: AvatarAnimState = .wandering,
        lifecycle: AvatarLifecycle = .alive
    ) {
        self.emoji = emoji?.nonEmptyOrNil ?? "🐱"
        self.colorHex = colorHex?.nonEmptyOrNil ?? "#7C3AED"
        self.size = size
        self.animated = animated
        self.animState = animState
        self.lifecycle = lifecycle
    }

    var body: some View {
        ZStack {
            // Entering ripple — soft expanding ring under the avatar so
            // arrivals read as "popped in" rather than "appeared from
            // nowhere". Only shown during `.entering`.
            if animated && lifecycle == .entering {
                EnteringRipple(colorHex: colorHex, size: size)
            }

            Circle()
                .fill(Color(hex: colorHex))

            // 3D-feel overlays only when animated. Static call sites get a
            // clean flat circle.
            if animated {
                highlightLayer
                shadowLayer
            }

            foreground
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .shadow(
            color: animated ? Color(hex: colorHex).opacity(0.4) : .black.opacity(0.18),
            radius: animated ? size * 0.14 : size * 0.05,
            y: animated ? size * 0.07 : size * 0.02
        )
        .modifier(ProceduralAvatarMotion(
            active:    animated,
            size:      size,
            animState: animState,
            lifecycle: lifecycle
        ))
    }

    // MARK: - Foreground

    @ViewBuilder
    private var foreground: some View {
        if hasAsset {
            Image(assetName)
                .resizable()
                .scaledToFit()
                .padding(size * 0.08)
        } else {
            Text(emoji)
                .font(.system(size: size * 0.6))
                .minimumScaleFactor(0.5)
        }
    }

    // MARK: - Depth overlays (only when animated)

    /// Soft white radial gradient in the upper-left — the "lit" highlight.
    private var highlightLayer: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Color.nodalong.textPrimary.opacity(0.45), Color.clear],
                    center: UnitPoint(x: 0.3, y: 0.25),
                    startRadius: 0,
                    endRadius: size * 0.55
                )
            )
            .blendMode(.softLight)
    }

    /// Soft dark radial gradient in the lower-right — the "shadow" side.
    private var shadowLayer: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Color.clear, Color.black.opacity(0.28)],
                    center: UnitPoint(x: 0.7, y: 0.85),
                    startRadius: size * 0.2,
                    endRadius: size * 0.6
                )
            )
            .blendMode(.multiply)
    }

    // MARK: - Emoji → asset mapping

    /// Static lookup from emoji → asset name. Mirrors the curated
    /// `userAvatarEmojis` palette in NodalongKit. When richer art is
    /// dropped into `Assets.xcassets`, the file names must match the
    /// right-hand side of this table.
    private static let assetMapping: [String: String] = [
        "🐶": "avatar_dog",     "🐱": "avatar_cat",     "🐭": "avatar_mouse",
        "🐹": "avatar_hamster", "🐰": "avatar_rabbit",  "🦊": "avatar_fox",
        "🐻": "avatar_bear",    "🐼": "avatar_panda",   "🐨": "avatar_koala",
        "🐯": "avatar_tiger",   "🦁": "avatar_lion",    "🐮": "avatar_cow",
        "🐷": "avatar_pig",     "🐸": "avatar_frog",    "🐵": "avatar_monkey",
        "🐔": "avatar_chicken", "🐧": "avatar_penguin", "🐦": "avatar_bird",
        "🐤": "avatar_chick",   "🦄": "avatar_unicorn", "🐢": "avatar_turtle",
        "🐝": "avatar_bee",     "🦋": "avatar_butterfly","🦉": "avatar_owl",
    ]
}

// MARK: - Procedural motion

/// All the procedural motion the animated avatar performs, layered in one
/// modifier so the call site stays one line. Reacts to per-frame state and
/// lifecycle changes; each motion is intentionally small (a few degrees of
/// tilt, a few percent scale) so 12 of these on the NearMe canvas read as
/// "alive" rather than "busy."
///
/// Why this lives here (and not in NearMeCanvasView): the animation values
/// are deterministic functions of `animState` + `lifecycle` only, and they
/// belong to the avatar's visual identity. NearMe just drives the inputs.
///
/// **Motion layers** (in render order, all multiplied together):
/// 1. **Idle bob + tilt** (always-on when `active`) — slow continuous
///    rotation3DEffect + Y offset. Randomised start delay per instance so
///    a canvas full of avatars never moves in lockstep.
/// 2. **Breathe** (always-on when `active`) — uniform scale 1.0 ↔ 1.03,
///    out of phase with the tilt so the motion compounds naturally.
/// 3. **Listening sway** (`.listening`) — adds gentle head-tilt rotation,
///    sitting-in-the-grass feel. Replaces the wander tilt.
/// 4. **Bumping squash-stretch** (`.bumping`) — short non-uniform scale
///    pulse to telegraph the bump physics; spring-snapped.
/// 5. **Lifecycle scale/opacity** — entering pops up, leaving shrinks
///    down. The avatar's own opacity multiplies the canvas-set value.
private struct ProceduralAvatarMotion: ViewModifier {
    let active:    Bool
    let size:      CGFloat
    let animState: AvatarAnimState
    let lifecycle: AvatarLifecycle

    // Idle bob/tilt — always animating when active.
    @State private var bobRotation:   Double  = 0
    @State private var bobOffset:     CGFloat = 0
    /// Per-instance phase offset (0…2s) so a canvas-full doesn't sync up.
    @State private var bobStartDelay: Double  = Double.random(in: 0..<2.0)
    /// Per-instance breathe duration jitter — between 2.6s and 3.4s so the
    /// breathing rhythm varies slightly avatar-to-avatar.
    @State private var breatheDuration: Double = Double.random(in: 2.6...3.4)
    @State private var breatheScale: CGFloat = 1.0

    func body(content: Content) -> some View {
        content
            // Bumping squash-and-stretch — non-uniform scale pulse.
            // Implemented as a separate scaleEffect so it composes with
            // breathe + lifecycle scaling rather than fighting them.
            .scaleEffect(
                x: bumpScaleX,
                y: bumpScaleY,
                anchor: .bottom
            )
            .animation(.spring(response: 0.22, dampingFraction: 0.5), value: animState)
            // Listening adds a held tilt; wandering tilt comes from the
            // bob below. We add (not replace) so the breathe scale still
            // applies.
            .rotationEffect(.degrees(listeningTilt))
            .animation(.easeInOut(duration: 0.6), value: animState)
            // Idle 3D tilt (always-on while active).
            .rotation3DEffect(
                .degrees(active ? bobRotation : 0),
                axis: (x: 1, y: 0.3, z: 0),
                perspective: 0.6
            )
            // Idle vertical bob (always-on while active).
            .offset(y: bobOffset)
            // Breathe — slow uniform scale, phase-offset from the bob.
            .scaleEffect(active ? breatheScale : 1.0)
            // Lifecycle scale — entering pops from 0.7, leaving shrinks
            // to 0.7. Composes with breathe so the avatar still breathes
            // during its entrance.
            .scaleEffect(lifecycleScale)
            .animation(.spring(response: 0.45, dampingFraction: 0.65), value: lifecycle)
            .onAppear { startIdleLoops() }
    }

    // MARK: - Derived motion values

    /// Squash factor for the bumping pop. Slightly wider, briefly shorter.
    private var bumpScaleX: CGFloat { animState == .bumping ? 1.18 : 1.0 }
    private var bumpScaleY: CGFloat { animState == .bumping ? 0.92 : 1.0 }

    /// Held tilt while listening (sitting in the grass with the head
    /// cocked). Zero in any other state.
    private var listeningTilt: Double { animState == .listening ? 6 : 0 }

    /// Scale during lifecycle phases other than `.alive` — entering and
    /// leaving both render at 0.7 so the spring snaps them into / out of
    /// view. `.alive` is 1.0 (the breathe modifier handles the breathing
    /// variation).
    private var lifecycleScale: CGFloat {
        switch lifecycle {
        case .entering, .leaving: return 0.7
        case .alive:              return 1.0
        }
    }

    // MARK: - Idle animation kickoff

    private func startIdleLoops() {
        guard active else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + bobStartDelay) {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                bobRotation = 8
                bobOffset   = -size * 0.04
            }
            withAnimation(.easeInOut(duration: breatheDuration).repeatForever(autoreverses: true)) {
                breatheScale = 1.03
            }
        }
    }
}

// MARK: - Entering ripple

/// One-shot expanding ring under the avatar during `.entering`. Reads as a
/// soft "pop in" — telegraphs that a new user just arrived in the park.
private struct EnteringRipple: View {
    let colorHex: String
    let size:     CGFloat

    @State private var scale:   CGFloat = 0.4
    @State private var opacity: CGFloat = 0.7

    var body: some View {
        Circle()
            .stroke(Color(hex: colorHex).opacity(opacity), lineWidth: max(2, size * 0.04))
            .frame(width: size, height: size)
            .scaleEffect(scale)
            .onAppear {
                withAnimation(.easeOut(duration: 0.6)) {
                    scale   = 1.6
                    opacity = 0
                }
            }
    }
}

private extension String {
    var nonEmptyOrNil: String? { isEmpty ? nil : self }
}

#if DEBUG
#Preview("Static vs Animated states") {
    VStack(spacing: 28) {
        Text("Static — Profile / lists / cards")
            .font(Font.nodalong.caption).foregroundStyle(Color.nodalong.textPrimary)
        HStack(spacing: 20) {
            AvatarView(emoji: "🐱", colorHex: "#7C3AED", size: 24)
            AvatarView(emoji: "🦊", colorHex: "#F59E0B", size: 36)
            AvatarView(emoji: "🐻", colorHex: "#8B4513", size: 50)
            AvatarView(emoji: "🐧", colorHex: "#3B82F6", size: 64)
            AvatarView(emoji: "🦄", colorHex: "#EC4899", size: 96)
        }

        Text("Animated — wandering")
            .font(Font.nodalong.caption).foregroundStyle(Color.nodalong.textPrimary)
        HStack(spacing: 20) {
            AvatarView(emoji: "🐱", colorHex: "#7C3AED", size: 60, animated: true)
            AvatarView(emoji: "🦊", colorHex: "#F59E0B", size: 60, animated: true)
            AvatarView(emoji: "🐻", colorHex: "#8B4513", size: 60, animated: true)
            AvatarView(emoji: "🐧", colorHex: "#3B82F6", size: 60, animated: true)
        }

        Text("Animated — listening")
            .font(Font.nodalong.caption).foregroundStyle(Color.nodalong.textPrimary)
        HStack(spacing: 20) {
            AvatarView(emoji: "🐰", colorHex: "#EC4899", size: 60, animated: true, animState: .listening)
            AvatarView(emoji: "🦉", colorHex: "#7C3AED", size: 60, animated: true, animState: .listening)
        }

        Text("Animated — entering / leaving")
            .font(Font.nodalong.caption).foregroundStyle(Color.nodalong.textPrimary)
        HStack(spacing: 20) {
            AvatarView(emoji: "🐢", colorHex: "#10B981", size: 60, animated: true, lifecycle: .entering)
            AvatarView(emoji: "🐝", colorHex: "#F59E0B", size: 60, animated: true, lifecycle: .leaving)
        }
    }
    .padding()
    .background(Color.black)
}
#endif
