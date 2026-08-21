import Foundation
import NodalongKit

/// Lifecycle state of a single avatar on the NearMe canvas. The 10fps tick
/// in `NearMeCanvasView` advances each avatar between these states based
/// on its position and collisions with neighbours.
///
/// - `wandering`: cruising toward a random target on the canvas
/// - `listening`: paused, "listening" to a track. The park redesign uses
///    this as the "sitting on the grass" state — every alive avatar dips
///    into `.listening` periodically to give the park a natural rhythm.
/// - `bumping`: just collided with another avatar; pushed back briefly
///    before returning to wandering
public enum AvatarAnimState: Equatable {
    case wandering
    case listening
    case bumping
}

/// Where in its visit to the park this avatar is.
///
/// - `entering`: just spawned, fading + scaling in.
/// - `alive`:    visible, full opacity, wandering / listening / bumping.
/// - `leaving`:  fading + scaling out before despawn.
///
/// Drives the pool rotation in `NearMeCanvasView` — once an avatar finishes
/// `.leaving`, its slot opens up for another nearby user (if any are waiting
/// off-canvas).
public enum AvatarLifecycle: Equatable {
    case entering
    case alive
    case leaving
}

/// Per-avatar physics + animation state held by `NearMeCanvasView`.
/// Lives outside the SwiftUI view so the canvas can update positions on a
/// timer without re-creating the struct on every render.
struct AvatarAnimationState {
    var x:         CGFloat
    var y:         CGFloat
    var targetX:   CGFloat
    var targetY:   CGFloat
    var speed:     CGFloat         = CGFloat.random(in: 20...50)
    var animState: AvatarAnimState = .wandering
    var bumpTimer: Double          = 0

    // Lifecycle — see `AvatarLifecycle`.
    var lifecycle:       AvatarLifecycle = .entering
    /// Current render opacity, 0…1. Drives fade-in/out for `.entering`/`.leaving`.
    var opacity:         CGFloat         = 0
    /// Seconds remaining in the current lifecycle phase. The tick decrements
    /// this; transitions fire when it hits 0.
    /// - During `.entering`: fade-in duration (≈0.6s).
    /// - During `.alive`:    total visit length (≈60–120s random).
    /// - During `.leaving`:  fade-out duration (≈0.6s).
    var lifeRemaining:   TimeInterval    = 0.6
    /// Seconds until the next spontaneous `.listening` lull during `.alive`.
    /// Decremented while wandering; when it hits 0, the avatar pauses for
    /// `listeningDuration` then returns to `.wandering`.
    var nextListenIn:    TimeInterval    = TimeInterval.random(in: 8...20)
    /// Seconds remaining in the current `.listening` lull. Ignored unless
    /// `animState == .listening`.
    var listenRemaining: TimeInterval    = 0

    /// Total length of an `alive` visit, in seconds. Range mirrors the
    /// product decision ("medium ~60–120s visits").
    static let visitDurationRange: ClosedRange<TimeInterval> = 60...120
    /// Fade-in / fade-out duration shared by `.entering` and `.leaving`.
    static let fadeDuration: TimeInterval = 0.6
    /// How long a `.listening` lull lasts.
    static let listeningDurationRange: ClosedRange<TimeInterval> = 3...6

    /// Spawn an avatar at a park-edge point so it reads as "walking in"
    /// rather than appearing mid-canvas. Wander target is well inside the
    /// canvas so the avatar moves *into* the park immediately.
    static func spawning(canvasSize: CGFloat) -> AvatarAnimationState {
        let margin: CGFloat = 40
        let inset:  CGFloat = canvasSize * 0.2
        // Pick a random edge to enter from.
        let (x, y): (CGFloat, CGFloat)
        switch Int.random(in: 0..<4) {
        case 0: x = CGFloat.random(in: margin...(canvasSize - margin)); y = margin                       // top
        case 1: x = CGFloat.random(in: margin...(canvasSize - margin)); y = canvasSize - margin          // bottom
        case 2: x = margin;                                              y = CGFloat.random(in: margin...(canvasSize - margin)) // left
        default: x = canvasSize - margin;                                y = CGFloat.random(in: margin...(canvasSize - margin)) // right
        }
        let tx = CGFloat.random(in: inset...(canvasSize - inset))
        let ty = CGFloat.random(in: inset...(canvasSize - inset))
        var s = AvatarAnimationState(x: x, y: y, targetX: tx, targetY: ty)
        s.lifecycle     = .entering
        s.opacity       = 0
        s.lifeRemaining = fadeDuration
        return s
    }
}
