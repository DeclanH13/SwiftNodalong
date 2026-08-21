import SwiftUI

private struct MarqueeTextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct MarqueeContainerWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Opt-in signal that some ancestor scroll view is actively moving. Defaults
/// to `true` (always "settled") so every existing `MarqueeText` call site —
/// none of which are wired to this — behaves exactly as before. Only screens
/// that explicitly apply `.gatesMarqueeToScrollSettle()` to their
/// `ScrollView` override it.
private struct MarqueeScrollSettledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    fileprivate var isScrollSettled: Bool {
        get { self[MarqueeScrollSettledKey.self] }
        set { self[MarqueeScrollSettledKey.self] = newValue }
    }
}

/// Tracks a `ScrollView`'s phase and republishes it as `\.isScrollSettled`
/// for any `MarqueeText` inside — those hold off starting (or stop
/// mid-cycle, restarting fresh once settled) their pause-then-scroll cycle
/// until this scroll view is genuinely idle, matching "I stop scrolling,
/// THEN the title I'm looking at scrolls" rather than titles animating while
/// still flying past.
///
/// Apply to each independently-scrollable container that hosts marquee
/// titles — both the page's own outer `ScrollView` AND any nested horizontal
/// carousel `ScrollView`s within it, since dragging a carousel doesn't
/// change the outer scroll's phase. Environment writes from a more deeply
/// nested view override the outer one only for ITS OWN descendants, so this
/// composes correctly without any coordination between call sites.
///
/// **Self-heals if the phase never reports back to `.idle`.** Confirmed
/// on-device: interacting with a nested horizontal carousel inside a gated
/// outer `ScrollView` can leave the OUTER gate's phase permanently stuck
/// non-idle — plausibly the touch getting "claimed" by the inner scroll
/// view's own gesture recognizer mid-tracking, so the outer one never gets
/// the matching lift-off/decelerate-to-idle callback that would normally
/// close its own cycle. Reproducing the exact SwiftUI-internal mechanism
/// wasn't possible from this environment (synthetic simulator touch input
/// doesn't reliably drive `.onScrollPhaseChange` through a realistic
/// tracking/decelerating/idle sequence at all, so it can't be used to
/// pin down which step drops the ball) — instead of chasing that further,
/// this gate is just made unable to stay stuck: any non-idle phase arms a
/// bounded watchdog that force-settles after `stuckTimeout` if no further
/// phase update arrives first. A genuine still-in-progress scroll keeps
/// resetting the watchdog via its own ordinary phase callbacks, so this
/// only ever fires for the "abandoned mid-gesture" case, never a normal
/// drag/fling.
private struct MarqueeScrollGate: ViewModifier {
    @State private var isSettled = true
    @State private var watchdog: Task<Void, Never>?
    private static let stuckTimeout: Double = 3.0

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, newPhase in
                watchdog?.cancel()
                let settled = (newPhase == .idle)
                isSettled = settled
                guard !settled else { return }
                watchdog = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(Self.stuckTimeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    isSettled = true
                }
            }
            .environment(\.isScrollSettled, isSettled)
    }
}

extension View {
    func gatesMarqueeToScrollSettle() -> some View {
        modifier(MarqueeScrollGate())
    }
}

/// A single-line label that, when its text is too wide for the space it's
/// given, pauses briefly then scrolls leftward once — revealing the full
/// text — and settles back to its resting position, rather than bouncing
/// back and forth. Two copies of the text sit side by side with a gap; by
/// the time the first has scrolled fully out of view, the second is exactly
/// where the first started, so even a single pass reads as a clean loop
/// back to the start with no visible jump or reversal.
///
/// **Loops exactly once per "focus" by default** (`repeats: false`) —
/// re-triggered the next time it becomes eligible to animate again (comes
/// back on screen, an ancestor scroll settles again, etc.), not on a timer.
/// Pass `repeats: true` for a genuinely continuous ticker — reserved for the
/// mini player and the full-screen player, where the title is the primary,
/// long-lived focus of the screen; everywhere else (Home tiles, Search,
/// artist discography, Party, …) a single reveal per focus is enough to
/// read the whole title without becoming a distraction on every re-render.
///
/// Drop-in for `Text(...).lineLimit(1)` — no surrounding layout change
/// needed beyond removing anything that was only there to make the OLD
/// plain `Text` shrink-wrap instead of expand (see call sites).
///
/// **Motion is driven by `TimelineView(.animation(paused:))` — a pure
/// function of wall-clock time — deliberately NOT
/// `withAnimation(...repeatForever...)`.** This app declares
/// `UIBackgroundModes: audio`, so the process keeps running while the
/// screen is locked mid-playback; a genuinely continuous, standing
/// CoreAnimation loop in that state is the confirmed root cause of the
/// "purple screen on reopen" bug fixed elsewhere this session (see
/// `SpinWhilePlaying` and `MiniPlayerBar`'s own doc comments — the render
/// server can't service a repeat-forever CAAnimation while locked, which
/// wedges the fence for the next foreground return). This mirrors that
/// same proven-safe pattern — including gating on `\.scenePhase` — rather
/// than reintroducing the risk in a new component just because this one
/// happens to animate text instead of a rotation.
///
/// Only ever animates while genuinely on screen AND (if an ancestor opted in
/// via `.gatesMarqueeToScrollSettle()`) while that scroll is idle — on-screen
/// detection is `.onGeometryChange(for: CGRect.self, of: { $0.frame(in:
/// .global) })`, compared against `ScreenMetrics.bounds`. Deliberately NOT a
/// hand-rolled `PreferenceKey` + `.onPreferenceChange` (which is what this
/// used originally): with three `.onPreferenceChange` calls chained on the
/// same node, the visibility one — fed from a `.background(GeometryReader)`
/// sibling to the other two, which are fed from nested descendants — reliably
/// fired exactly ONCE with the key's `.zero` default and never again, even
/// though the underlying `GeometryReader` kept recomputing the correct rect
/// on every subsequent layout pass (confirmed on-device: the `preference(key
/// :value:)` call and the GeometryReader body both saw the real rect; only
/// the `onPreferenceChange` closure never got it) — which is what silently
/// pinned `isVisible` at `false` forever and is why NO marquee text scrolled
/// anywhere in the app. `onGeometryChange` doesn't go through the
/// multi-key-chain preference-propagation path at all, and doesn't exhibit
/// the bug. Both checks still fail safe: worst case is "doesn't animate,"
/// never a crash or a stuck state.
///
/// Three copies of the text do three separate jobs a single `Text` can't:
/// - A hidden, plain (non-`fixedSize`) copy negotiates layout EXACTLY like
///   the old `Text` did, reporting the space actually available
///   (`containerWidth`).
/// - A hidden, `fixedSize` copy measures the text's TRUE full width
///   (`textWidth`) — used to decide whether to scroll at all, and how far
///   one loop needs to travel.
/// - Two VISIBLE, `fixedSize` copies (only rendered once overflow is
///   confirmed) sit side by side with `loopGap` between them and animate
///   together — this pair, not a single copy bouncing, is what makes the
///   wrap-around read as continuous rather than a jump-cut back to start.
struct MarqueeText: View {
    let text: String
    var font: Font
    var color: Color
    var alignment: Alignment = .leading
    /// How long the text sits still before scrolling begins — and, when
    /// `repeats` is true, the same rest held between the end of one lap and
    /// the start of the next.
    var pause: Double = 1.6
    /// Points per second while scrolling.
    var speed: Double = 32
    /// `false` (default): scroll through once per focus, then settle back
    /// to rest until re-triggered. `true`: keep looping with `pause`
    /// between laps for as long as it stays eligible to animate — see the
    /// type's own doc comment for which call sites should set this.
    var repeats: Bool = false

    /// Gap between the end of one copy and the start of the next while
    /// looping — wide enough to read as a clean separation between "end of
    /// title" and "start of title again," not run together.
    private let loopGap: CGFloat = 32

    @State private var containerWidth: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var isScrolling = false
    /// Anchor for the pure-time-function offset below — set the instant
    /// scrolling begins, so the very first frame renders at offset 0
    /// (not wherever in the cycle the CURRENT wall-clock time happens to
    /// land, which is what a naive `date.timeIntervalSinceReferenceDate`
    /// read would produce — a jarring pop instead of a smooth start).
    @State private var scrollStartDate: Date?
    @State private var startTask: Task<Void, Never>?
    /// Whether this instance's own laid-out frame currently overlaps the
    /// device screen — see the `.onGeometryChange` call in `body`. Defaults
    /// `true` so it behaves normally before the first geometry read lands.
    @State private var isVisible = true

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isScrollSettled) private var isScrollSettled

    private var overflow: CGFloat { max(0, textWidth - containerWidth) }
    private var travelDistance: CGFloat { textWidth + loopGap }
    private var canAnimate: Bool { isVisible && isScrollSettled }

    var body: some View {
        ZStack(alignment: alignment) {
            Text(text)
                .font(font)
                .lineLimit(1)
                .hidden()
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: MarqueeContainerWidthKey.self, value: proxy.size.width)
                    }
                )

            if containerWidth > 0 {
                // `.background(GeometryReader{...})` reads this Text's own
                // TRUE, `fixedSize` width BEFORE the trailing
                // `.frame(width: containerWidth).clipped()` runs — so the
                // measurement is still the full, unclamped width. The
                // trailing frame/clip is what stops this hidden element
                // from leaking that full width into the ZStack's own
                // reported size, the way it did without them: an
                // unconstrained hidden clone contributes its TRUE (often
                // very wide) size to the ZStack's natural sizing, which
                // then propagated outward past whatever padding the call
                // site applied — the confirmed cause of `NowPlayingView`'s
                // title bleeding all the way to the physical screen edges,
                // ignoring its 24pt horizontal padding, rather than
                // clipping within its intended bounds.
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .hidden()
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: MarqueeTextWidthKey.self, value: proxy.size.width)
                        }
                    )
                    .frame(width: containerWidth, alignment: alignment)
                    .clipped()

                // Visible content — same frame/clip treatment, for the same
                // reason: never let raw content width escape this
                // component's own bounds. This is ALSO what stops the
                // outer `ZStack` from ever squeezing the CONTAINER-width
                // measuring `Text` above (see that element's own doc
                // comment) — the two hidden clones + this visible content
                // block are three siblings the ZStack sizes itself
                // against; only the top one (the container-width probe) is
                // ever allowed to be genuinely unconstrained.
                Group {
                    if overflow > 0 {
                        TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                                 paused: !isScrolling || scenePhase != .active || !canAnimate)) { context in
                            HStack(spacing: loopGap) {
                                Text(text).font(font).foregroundStyle(color).lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                Text(text).font(font).foregroundStyle(color).lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .offset(x: -xOffset(at: context.date))
                        }
                    } else {
                        Text(text)
                            .font(font)
                            .foregroundStyle(color)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .frame(width: containerWidth, alignment: alignment)
                .clipped()
            }
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { rect in
            let visible = rect.width > 0 && rect.height > 0 && ScreenMetrics.bounds.intersects(rect)
            guard visible != isVisible else { return }
            isVisible = visible
            restart()
        }
        .onPreferenceChange(MarqueeContainerWidthKey.self) { newValue in
            guard containerWidth != newValue else { return }
            containerWidth = newValue
            restart()
        }
        .onPreferenceChange(MarqueeTextWidthKey.self) { newValue in
            guard textWidth != newValue else { return }
            textWidth = newValue
            restart()
        }
        .onChange(of: text) {
            restart()
        }
        .onChange(of: isScrollSettled) {
            restart()
        }
        .onDisappear {
            startTask?.cancel()
        }
    }

    /// Pure function of wall-clock time (relative to `scrollStartDate`).
    /// Each period is `cycleSeconds` of continuous scroll (0 → `travelDistance`
    /// — visually, copy 2 arrives exactly where copy 1 started, so this is
    /// indistinguishable from a clean loop back to the beginning) followed
    /// by `pause` seconds held at that same start position — a true
    /// endless scroll with no rest point reads as relentless rather than
    /// readable, so this rebuilds in the same "settle, then move" rhythm
    /// the very first scroll already had, just repeated every lap instead
    /// of only before the first one. `TimelineView`'s own `paused:` freezes
    /// `context.date` (not this function) while inactive, so pausing there
    /// costs nothing and resuming continues smoothly from wherever the
    /// cycle was — no reset, no jump.
    private func xOffset(at date: Date) -> CGFloat {
        guard travelDistance > 0, let start = scrollStartDate else { return 0 }
        let elapsed = date.timeIntervalSince(start)
        guard elapsed > 0 else { return 0 }
        let cycleSeconds = Double(travelDistance) / speed
        guard cycleSeconds > 0 else { return 0 }
        let periodSeconds = cycleSeconds + pause
        let phase = elapsed.truncatingRemainder(dividingBy: periodSeconds)
        guard phase < cycleSeconds else { return 0 }   // in the post-loop rest window
        let progress = phase / cycleSeconds
        return CGFloat(progress) * travelDistance
    }

    private func restart() {
        startTask?.cancel()
        isScrolling = false
        scrollStartDate = nil
        // Not on screen, or an ancestor scroll is actively moving — don't
        // even start counting down the pause. Whatever made this false will
        // flip back and call `restart()` again, starting a genuinely fresh
        // "settle, then scroll" cycle rather than resuming mid-count.
        guard overflow > 0, canAnimate else { return }
        startTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
            guard !Task.isCancelled else { return }
            scrollStartDate = Date()
            isScrolling = true
            guard !repeats else { return }
            // Single-loop mode: stop right as the one pass completes —
            // `xOffset` is periodic with period `travelDistance`, so
            // freezing at (or just past) the end of the first cycle reads
            // identically to resting at the start (see that function's own
            // doc comment) — no separate "snap back" needed.
            let cycleSeconds = Double(travelDistance) / speed
            try? await Task.sleep(nanoseconds: UInt64(max(0, cycleSeconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            isScrolling = false
        }
    }
}

#if DEBUG
#Preview {
    VStack(alignment: .leading, spacing: 24) {
        MarqueeText(text: "Short Title", font: Font.nodalong.title3Bold, color: .primary)
        MarqueeText(text: "A Very Long Song Title That Definitely Will Not Fit On One Line", font: Font.nodalong.title3Bold, color: .primary)
    }
    .padding()
}
#endif
