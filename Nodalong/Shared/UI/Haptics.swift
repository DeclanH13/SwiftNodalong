import UIKit

/// Long-lived, pre-warmed impact generators.
///
/// Every call site in this app used to construct a `UIImpactFeedbackGenerator`
/// fresh and fire it immediately. That is the one usage Apple's own
/// documentation calls out: the Taptic Engine is powered down while idle, and
/// an impact on a generator that was never `prepare()`d blocks the calling
/// thread — the main thread, at all four of those call sites — while the
/// engine spins up. It only bites once per idle period, which is exactly the
/// shape of "the FIRST press of a fresh run is slow, the rest are instant".
///
/// Two things fix it together, and both matter:
///
/// - The generator is **retained**, so it isn't rebuilt (and re-warmed from
///   cold) on every tap.
/// - It is **re-prepared after each impact**, so a rapid second interaction
///   never pays the warm-up again, and `prepare()` at launch gives the first
///   one a head start.
///
/// `prepare()` itself doesn't block — it's a request to warm up, not a wait.
@MainActor
enum Haptics {
    private static var generators: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = [:]

    private static func generator(_ style: UIImpactFeedbackGenerator.FeedbackStyle) -> UIImpactFeedbackGenerator {
        if let existing = generators[style] { return existing }
        let made = UIImpactFeedbackGenerator(style: style)
        generators[style] = made
        return made
    }

    /// Warm the engine ahead of a likely interaction. Safe to call often.
    static func prepare(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        generator(style).prepare()
    }

    /// Fire an impact, then immediately re-warm for the next one.
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = generator(style)
        generator.impactOccurred()
        generator.prepare()
    }
}
