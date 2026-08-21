import SwiftUI
import NodalongKit

/// The animated "park" the NearMe tab is built around.
///
/// Visual model: a top-down stylised park (`ParkBackgroundView`) populated
/// by up to `poolCap` avatars who wander in, hang out for ~60–120 seconds,
/// and drift off again. The view never shows real-world coordinates — the
/// canvas is symbolic, not geographic, by design (privacy).
///
/// **Sizing.** The park is sized to ~1.3× the available screen via
/// `GeometryReader`, then centred. Default zoom is 1.0, so the whole park
/// is on screen with no panning required (fixes the "you have to zoom out
/// to find anyone" UX before this change). Pinch + pan still work for
/// closer inspection.
///
/// **Pool rotation.** If `users.count > poolCap`, only `poolCap` avatars
/// are alive on the canvas at any time. As each one finishes `.leaving`,
/// a random unused nearby user spawns in. Over a session, everyone gets a
/// turn on screen.
///
/// **Tick loop.** Split into three passes for readability:
/// `tickLifecycle` (fade / spawn / despawn), `tickPhysics` (wander toward
/// target, listening lulls), `tickCollisions` (push apart + bump-pop).
struct NearMeCanvasView: View {
    let users:          [UserProfile]
    let featuredTracks: [String: Post]
    let onSelectUser:   (UserProfile) -> Void

    /// Pauses the physics loop whenever the app leaves the foreground. The app
    /// runs in the background during audio playback (`UIBackgroundModes: audio`),
    /// so without this the 60 fps loop would keep burning CPU while the phone is
    /// locked — the root cause of the background-CPU jetsam kills.
    @Environment(\.scenePhase) private var scenePhase

    @State private var avatarStates: [String: AvatarAnimationState] = [:]
    /// uids currently on the canvas — `avatarStates.keys`, but kept as an
    /// array so iteration order is stable (matters for the collision pass).
    @State private var activePool:   [String] = []
    /// uids waiting off-canvas to rotate in once an active avatar leaves.
    @State private var unusedQueue:  [String] = []

    @State private var canvasScale:  CGFloat = 1.0
    @State private var baseScale:    CGFloat = 1.0
    @State private var canvasOffset: CGSize  = .zero
    @State private var baseOffset:   CGSize  = .zero
    /// Resolved from `GeometryReader`'s reported size. Kept in state because
    /// so much of the per-avatar math depends on it. Recomputed on every
    /// `geo.size` change (not just first appear) so the pan-clamp stays
    /// honest on iOS 26 where the playfield can settle to a smaller size
    /// after the initial layout pass.
    @State private var canvasSize:   CGFloat = 0
    /// Container (playfield) size — recomputed on every `geo.size` change.
    /// The pan-clamp uses this to keep the park's edges from sliding past
    /// the playfield bounds. Previously cached once on `.onAppear`, which
    /// allowed a stale value to slip in when iOS 26 layout settled later.
    @State private var containerSize: CGSize = .zero
    /// Flips to `true` after `spawnInitial` runs for the first non-zero
    /// container size. Stops re-spawning on later size changes (rotation,
    /// tab return, etc.).
    @State private var hasSpawned:   Bool    = false

    // Tunables — see top-of-file comment.
    private let poolCap:          Int     = 12
    private let collisionRadius:  CGFloat = 70
    private let avatarDisplaySize: CGFloat = 60
    /// Physics tick interval. 30 fps is smooth for this gentle wander/breathe
    /// motion and halves the per-frame cost vs. the old 60 fps loop (the 10 fps
    /// it replaced looked visibly stepped). The tick is driven by `tickTimer`,
    /// which only runs while the canvas is on-screen AND the scene is active.
    private let tickInterval: TimeInterval = 1.0 / 30.0
    /// The running physics timer. Started in `.onAppear`, invalidated in
    /// `.onDisappear` and whenever `scenePhase != .active`, so it never fires
    /// off-screen (other tabs) or in the background (locked phone).
    @State private var tickTimer: Timer?

    // Inside NearMeCanvasView.swift
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .center) {
                Color.nodalong.bgBase
                
                // The interactive park canvas layer
                ZStack {
                    ParkBackgroundView(size: canvasSize)
                    avatarLayerStack
                }
                .frame(width: canvasSize, height: canvasSize)
                // ADD THIS LINE BELOW TO CURVE THE PARK CORNERS
                .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                .scaleEffect(canvasScale, anchor: .center)
                .offset(canvasOffset)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            .onAppear {
                applyLayout(geo.size)
                startTicking()
            }
            .onDisappear { stopTicking() }
            .onChange(of: scenePhase) { _, phase in
                // Background/inactive → stop all UI work (audio keeps playing).
                phase == .active ? startTicking() : stopTicking()
            }
            .onChange(of: geo.size) { _, newSize in applyLayout(newSize) }
            .onChange(of: users.map { $0.uid }) {
                reconcileQueue()
            }
            .gesture(panGesture)
            .simultaneousGesture(pinchGesture)
        }
    }

    /// All avatars currently alive on the canvas. Pulled out so the
    /// `ForEach` body stays compact.
    private var avatarLayerStack: some View {
        ZStack {
            ForEach(activePool, id: \.self) { uid in
                if let state = avatarStates[uid],
                   let user  = users.first(where: { $0.uid == uid }) {
                    avatarLayer(user: user, state: state)
                }
            }
        }
    }

    /// One avatar on the canvas.
    @ViewBuilder
    private func avatarLayer(user: UserProfile, state: AvatarAnimationState) -> some View {
        AvatarView(
            emoji:     user.avatarEmoji,
            colorHex:  user.avatarColor,
            size:      avatarDisplaySize,
            animated:  true,
            animState: state.animState,
            lifecycle: state.lifecycle
        )
        .opacity(state.opacity)
        .position(x: state.x, y: state.y)
        .onTapGesture { onSelectUser(user) }
    }

    // MARK: - Gestures (rubber-banded)

    private let minScale: CGFloat = 0.7
    private let maxScale: CGFloat = 2.5

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { v in
                let raw = CGSize(
                    width:  baseOffset.width  + v.translation.width,
                    height: baseOffset.height + v.translation.height
                )
                canvasOffset = rubberBandedOffset(raw, scale: canvasScale)
            }
            .onEnded { _ in
                let target = clampedOffset(canvasOffset, scale: canvasScale)
                if target != canvasOffset {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        canvasOffset = target
                    }
                }
                baseOffset = target
            }
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { v in
                let raw = baseScale * v
                canvasScale = rubberBandedScale(raw)
                canvasOffset = rubberBandedOffset(canvasOffset, scale: canvasScale)
            }
            .onEnded { _ in
                let targetScale  = max(minScale, min(maxScale, canvasScale))
                let targetOffset = clampedOffset(canvasOffset, scale: targetScale)
                if targetScale != canvasScale || targetOffset != canvasOffset {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        canvasScale  = targetScale
                        canvasOffset = targetOffset
                    }
                }
                baseScale  = targetScale
                baseOffset = targetOffset
            }
    }

    // MARK: - Absolute Algorithmic Boundary Logic
    
    /// Hard clamp — ensures the edges of the scaled canvas can NEVER slide
    /// past the edges of the visible playfield container.
    private func clampedOffset(_ candidate: CGSize, scale: CGFloat) -> CGSize {
        let parkEffective = canvasSize * scale
        
        // 1. If the canvas is smaller than or equal to the container size,
        // pin it to dead center immediately.
        guard parkEffective > containerSize.width, parkEffective > containerSize.height else {
            return .zero
        }
        
        // 2. Maximum allowable distance the frame center can slide outward.
        let maxX = (parkEffective - containerSize.width) / 2
        let maxY = (parkEffective - containerSize.height) / 2
        
        // 3. Prevent any scrolling pass from breaking past these boundaries.
        return CGSize(
            width:  max(-maxX, min(maxX, candidate.width)),
            height: max(-maxY, min(maxY, candidate.height))
        )
    }

    /// Like `clampedOffset` but applies rubber-band resistance past the
    /// bounds rather than hard-stopping so the user feels the edge wall.
    private func rubberBandedOffset(_ candidate: CGSize, scale: CGFloat) -> CGSize {
        let parkEffective = canvasSize * scale
        
        guard parkEffective > containerSize.width, parkEffective > containerSize.height else {
            return .zero
        }
        
        let maxX = (parkEffective - containerSize.width) / 2
        let maxY = (parkEffective - containerSize.height) / 2
        
        return CGSize(
            width:  rubberBand(candidate.width,  limit: maxX),
            height: rubberBand(candidate.height, limit: maxY)
        )
    }

    private func rubberBandedScale(_ candidate: CGFloat) -> CGFloat {
        if candidate < minScale {
            let over = minScale - candidate
            return minScale - over * 0.3
        }
        if candidate > maxScale {
            let over = candidate - maxScale
            return maxScale + over * 0.3
        }
        return candidate
    }

    private func rubberBand(_ value: CGFloat, limit: CGFloat) -> CGFloat {
        guard abs(value) > limit else { return value }
        let over = abs(value) - limit
        let sign: CGFloat = value > 0 ? 1 : -1
        return sign * (limit + over * 0.3)
    }

    // MARK: - Sizing / spawn

    private func applyLayout(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        updateSizing(size)
        if !hasSpawned {
            spawnInitial(size)
            hasSpawned = true
        }
    }

    private func updateSizing(_ size: CGSize) {
        let stableDim = max(size.width, size.height) * 1.5
        if abs(canvasSize - stableDim) > 1 {
            canvasSize = stableDim
        }
        
        containerSize = size
        canvasOffset = clampedOffset(canvasOffset, scale: canvasScale)
        baseOffset   = canvasOffset
    }

    private func spawnInitial(_ size: CGSize) {
        let shuffled = users.shuffled()
        let initialActive = shuffled.prefix(poolCap)
        unusedQueue = Array(shuffled.dropFirst(initialActive.count)).map { $0.uid }

        for user in initialActive {
            var state = AvatarAnimationState.spawning(canvasSize: canvasSize)
            state.lifeRemaining = AvatarAnimationState.fadeDuration
            avatarStates[user.uid] = state
            activePool.append(user.uid)
        }
    }

    private func reconcileQueue() {
        let nearbyUids = Set(users.map { $0.uid })

        for uid in activePool {
            if !nearbyUids.contains(uid),
               var s = avatarStates[uid],
               s.lifecycle == .alive {
                s.lifecycle     = .leaving
                s.lifeRemaining = AvatarAnimationState.fadeDuration
                avatarStates[uid] = s
            }
        }

        let activeSet = Set(activePool)
        unusedQueue = users
            .map { $0.uid }
            .filter { !activeSet.contains($0) }
            .shuffled()
    }

    // MARK: - Timer lifecycle

    /// Starts the physics timer if it isn't already running and the scene is
    /// active. Idempotent — safe to call from both `.onAppear` and the
    /// scenePhase change handler.
    private func startTicking() {
        guard tickTimer == nil, scenePhase == .active else { return }
        tickTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { _ in
            tick()
        }
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: - Tick

    /// One physics step. All three passes mutate **local copies** of the
    /// canvas state and are written back to the `@State` properties exactly
    /// once at the end — so SwiftUI invalidates the canvas a single time per
    /// frame instead of dozens of times (the old code assigned
    /// `avatarStates[uid]` per avatar plus 4 writes per collision pair).
    private func tick() {
        let dt = tickInterval
        var states = avatarStates
        var pool   = activePool
        var queue  = unusedQueue

        tickLifecycle(dt: dt, states: &states, pool: &pool, queue: &queue)
        tickPhysics(dt: CGFloat(dt), states: &states, pool: pool)
        tickCollisions(states: &states, pool: pool)

        avatarStates = states
        activePool   = pool
        unusedQueue  = queue
    }

    private func tickLifecycle(
        dt: TimeInterval,
        states: inout [String: AvatarAnimationState],
        pool: inout [String],
        queue: inout [String]
    ) {
        var despawned: [String] = []

        for uid in pool {
            guard var s = states[uid] else { continue }
            s.lifeRemaining -= dt

            switch s.lifecycle {
            case .entering:
                let elapsed = AvatarAnimationState.fadeDuration - s.lifeRemaining
                s.opacity = max(0, min(1, CGFloat(elapsed / AvatarAnimationState.fadeDuration)))
                if s.lifeRemaining <= 0 {
                    s.lifecycle     = .alive
                    s.opacity       = 1
                    s.lifeRemaining = TimeInterval.random(in: AvatarAnimationState.visitDurationRange)
                }
            case .alive:
                s.opacity = 1
                if s.lifeRemaining <= 0 {
                    s.lifecycle     = .leaving
                    s.lifeRemaining = AvatarAnimationState.fadeDuration
                }
            case .leaving:
                let elapsed = AvatarAnimationState.fadeDuration - s.lifeRemaining
                s.opacity = max(0, 1 - CGFloat(elapsed / AvatarAnimationState.fadeDuration))
                if s.lifeRemaining <= 0 {
                    despawned.append(uid)
                }
            }

            states[uid] = s
        }

        for uid in despawned {
            states.removeValue(forKey: uid)
            pool.removeAll { $0 == uid }

            let activeSet = Set(pool)
            if users.contains(where: { $0.uid == uid }), !activeSet.contains(uid) {
                queue.append(uid)
            }

            if let nextUid = queue.first {
                queue.removeFirst()
                states[nextUid] = AvatarAnimationState.spawning(canvasSize: canvasSize)
                pool.append(nextUid)
            }
        }
    }

    private func tickPhysics(
        dt: CGFloat,
        states: inout [String: AvatarAnimationState],
        pool: [String]
    ) {
        let margin: CGFloat = 60

        for uid in pool {
            guard var s = states[uid] else { continue }
            guard s.lifecycle == .alive else { continue }

            switch s.animState {
            case .wandering:
                let dx = s.targetX - s.x
                let dy = s.targetY - s.y
                let dist = hypot(dx, dy)
                if dist < 4 {
                    s.targetX = CGFloat.random(in: margin...(canvasSize - margin))
                    s.targetY = CGFloat.random(in: margin...(canvasSize - margin))
                } else {
                    let speed = s.speed * dt
                    s.x += (dx / dist) * speed
                    s.y += (dy / dist) * speed
                }
                s.nextListenIn -= TimeInterval(dt)
                if s.nextListenIn <= 0 {
                    s.animState       = .listening
                    s.listenRemaining = TimeInterval.random(in: AvatarAnimationState.listeningDurationRange)
                }

            case .listening:
                s.listenRemaining -= TimeInterval(dt)
                if s.listenRemaining <= 0 {
                    s.animState   = .wandering
                    s.nextListenIn = TimeInterval.random(in: 8...20)
                    s.targetX = CGFloat.random(in: margin...(canvasSize - margin))
                    s.targetY = CGFloat.random(in: margin...(canvasSize - margin))
                }

            case .bumping:
                s.bumpTimer -= Double(dt)
                if s.bumpTimer <= 0 { s.animState = .wandering }
            }

            states[uid] = s
        }
    }

    private func tickCollisions(
        states: inout [String: AvatarAnimationState],
        pool: [String]
    ) {
        let alive = pool.filter { states[$0]?.lifecycle == .alive }
        for i in 0..<alive.count {
            for j in (i + 1)..<alive.count {
                guard let a = states[alive[i]], let b = states[alive[j]] else { continue }
                let dist = hypot(a.x - b.x, a.y - b.y)
                guard dist < collisionRadius else { continue }
                let angle = atan2(b.y - a.y, b.x - a.x)
                let push: CGFloat = (collisionRadius - dist) / 2 + 2
                states[alive[i]]?.x -= cos(angle) * push
                states[alive[i]]?.y -= sin(angle) * push
                states[alive[j]]?.x += cos(angle) * push
                states[alive[j]]?.y += sin(angle) * push
                if states[alive[i]]?.animState == .wandering {
                    states[alive[i]]?.animState = .bumping
                    states[alive[i]]?.bumpTimer = 0.4
                }
                if states[alive[j]]?.animState == .wandering {
                    states[alive[j]]?.animState = .bumping
                    states[alive[j]]?.bumpTimer = 0.4
                }
            }
        }
    }
}

#if DEBUG
#Preview("Canvas – populated") {
    NearMeCanvasView(
        users: PreviewFixtures.nearbyProfiles,
        featuredTracks: [:],
        onSelectUser: { _ in }
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.nodalong.bgBase)
}

#Preview("Canvas – empty") {
    NearMeCanvasView(
        users: [],
        featuredTracks: [:],
        onSelectUser: { _ in }
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.nodalong.bgBase)
}
#endif

