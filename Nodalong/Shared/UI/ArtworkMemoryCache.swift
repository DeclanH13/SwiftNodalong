import UIKit

/// In-memory cache of **decoded** artwork bitmaps, keyed by the already-sized
/// URL string produced by `ArtworkURL.sized`.
///
/// `URLCache.shared` (configured in `AppDelegate`) caches compressed *bytes* —
/// it does not cache decoded images, and `AsyncImage` has no image cache of
/// its own. So every time a view reappeared (scrolling a carousel back,
/// popping a navigation stack, a snapshot-restored Home re-rendering) the
/// JPEG was decoded from scratch and the shimmer placeholder flashed again.
/// That re-decode flash is the "pop in" this closes; `URLCache` still handles
/// the bytes underneath, so nothing here duplicates it.
///
/// This is also a regression fix: Kingfisher used to provide exactly this
/// layer, and when it was removed (see the decisions log) `URLCache` was kept
/// as "the one cache the app uses" — but the two are not equivalent, and the
/// decoded-image layer was simply lost.
///
/// `NSCache` is deliberate over a plain dictionary: it evicts automatically
/// under memory pressure, which matters given this project's documented
/// history of jetsam kills caused by artwork memory.
enum ArtworkMemoryCache {
    /// `nonisolated(unsafe)` because `NSCache` is documented thread-safe
    /// ("You can add, remove, and query items in the cache from different
    /// threads without having to lock the cache yourself") but isn't marked
    /// `Sendable`. Accessed from both the main actor (the synchronous read in
    /// `CachedArtworkImage.init`) and background decode tasks, so the
    /// annotation is load-bearing, not a silencer. Mirrors the same pattern
    /// already used for `PlayerViewModel.lastExplicitPauseAt`.
    private nonisolated(unsafe) static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        // Cost is tracked in bytes of decoded bitmap (see `store`), so this is
        // a real memory ceiling rather than an object count.
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()

    static func image(for key: String) -> UIImage? {
        guard !key.isEmpty else { return nil }
        return cache.object(forKey: key as NSString)
    }

    static func store(_ image: UIImage, for key: String) {
        guard !key.isEmpty else { return }
        // 4 bytes per pixel of the *decoded* bitmap — `size` is in points, so
        // scale must be squared in.
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        cache.setObject(image, forKey: key as NSString, cost: Int(pixels) * 4)
    }

    /// Not wired to sign-out: artwork is public catalog imagery, not user
    /// data, so it's safe (and desirable) to keep across an account switch.
    /// Exposed for memory-pressure handling and tests.
    static func clear() { cache.removeAllObjects() }

    /// Downloads and decodes `url` at the size a destination screen will ask
    /// for, so that screen's `CachedArtworkImage` hits on its FIRST frame.
    ///
    /// Data prefetching alone leaves the hero artwork cold: a tile shows the
    /// 160/320px bucket, the screen it opens asks for 600px, and those are
    /// different keys. The key written here is exactly the one
    /// `CachedArtworkImage` reads, because both go through `ArtworkURL.sized`
    /// with the same point size — its bucketing (160/320/600) is what makes
    /// "the same size" a forgiving match.
    @MainActor
    static func prefetch(_ url: String, points: CGFloat) async {
        let key = ArtworkURL.sized(url, points: points)
        guard !key.isEmpty, image(for: key) == nil, !Task.isCancelled,
              let u = URL(string: key),
              let (data, _) = try? await URLSession.shared.data(from: u),
              let raw = UIImage(data: data),
              let decoded = await raw.byPreparingForDisplay()
        else { return }
        store(decoded, for: key)
    }

    /// Warms a hero that may render either way the artwork-style setting
    /// allows: the full square at `points`, or the label of the vinyl disc
    /// drawn at that size (`VinylArtworkView` — a smaller circle, so on some
    /// devices a different bucket). When both resolve to the same key the
    /// second call is a free cache hit.
    @MainActor
    static func prefetchHero(_ url: String, points: CGFloat) async {
        await prefetch(url, points: points)
        await prefetch(url, points: points * VinylArtworkView.discScale * VinylArtworkView.labelScale)
    }
}
