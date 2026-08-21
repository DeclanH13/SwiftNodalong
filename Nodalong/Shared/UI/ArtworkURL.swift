import UIKit

/// Rewrites Apple Music artwork URLs to request a display-appropriate pixel
/// size from Apple's CDN.
///
/// `AppleMusicService.artworkURL` bakes every artwork URL at **600×600**. When
/// that image is shown in a 44–48 pt thumbnail, `AsyncImage` still downloads and
/// decodes the full 600×600 bitmap — ~17× more pixels than the thumbnail needs,
/// which inflated the app's resident memory. Apple's CDN will serve any size we
/// put in the URL path, so we rewrite the size token at the point of use.
///
/// Apple Music (`mzstatic`) artwork URLs end in a `{w}x{h}{crop}.{ext}` segment,
/// e.g. `.../600x600bb.jpg`. Only that token is swapped. URLs that don't match
/// (legacy Spotify-CDN art on pre-port tracks, already-sized, or malformed) are
/// returned unchanged. Non-`http(s)` schemes (e.g. a `musicKit://artwork/library/...`
/// on-device-only reference) are rejected outright — returned as `""` — since
/// they can never be fetched over plain networking regardless of sizing.
enum ArtworkURL {
    /// The pixel size every artwork URL is baked at by
    /// `AppleMusicService.artworkURL`. Requesting more than this from the CDN
    /// just upscales — same visible quality, but a proportionally larger bitmap
    /// in RAM — so we never ask for more than the source has.
    static let sourcePixels = 600

    /// Every `sized(_:points:)` request is rounded UP to one of these — never
    /// down, so nothing gets softer than it would have anyway. Without this,
    /// one album's artwork could end up fetched at up to 8 distinct pixel
    /// sizes across the app (a 44pt thumbnail, an 80pt album header, a
    /// 160pt resolving-view placeholder, a full-width 600pt hero, ...) —
    /// each a separate `URLCache` entry and a separate network round trip
    /// for the same picture. Bucketing collapses that down to at most 3
    /// distinct downloads per image, shared across whichever surfaces land
    /// in the same bucket.
    private static let buckets = [160, 320, 600]

    /// True only for a fetchable `http(s)` URL. Empty strings, scheme-less
    /// strings, and non-`http(s)` schemes (e.g. a `musicKit://artwork/library/…`
    /// device-local reference) are **not** usable — they can never be loaded
    /// over the network. Single source of truth for "is this artwork string
    /// something `AsyncImage` could actually render," shared by the catalog
    /// repair + the catalog-preferred read patch.
    static func isFetchable(_ s: String) -> Bool {
        guard !s.isEmpty, let scheme = URL(string: s)?.scheme else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Returns `urlString` with its dimension token rewritten to the
    /// smallest `buckets` entry that's at least `points × scale` pixels
    /// (falling back to `sourcePixels` if the request exceeds every
    /// bucket), capped at `maxPixels`. No-op for non-matching URLs.
    ///
    /// `maxPixels` defaults to `sourcePixels` (600): full-width artwork on a 3×
    /// device would otherwise resolve to ~1080–1180 px and decode to a 4–5 MB
    /// bitmap for no quality gain over the 600 px the CDN actually has.
    /// Compiled once. This is called from inside `ArtworkThumbnail`'s body
    /// (the shared artwork primitive behind ~39 call sites) and `TrackCard`'s
    /// body — so recompiling it per call meant a fresh `NSRegularExpression`
    /// construction for every visible tile, every frame, while scrolling.
    private static let sizeTokenRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"/\d+x\d+(?=[a-z]{0,4}\.(?:jpg|jpeg|png|webp))"#
    )

    @MainActor
    static func sized(
        _ urlString: String,
        points: CGFloat,
        scale: CGFloat = ScreenMetrics.scale,
        maxPixels: Int = sourcePixels
    ) -> String {
        guard !urlString.isEmpty else { return urlString }
        // Some persisted artwork strings are a `musicKit://artwork/library/...`
        // reference — a device-local artwork-catalog scheme (from a
        // library-matched recently-played track) that plain networking can
        // never resolve. `AppleMusicService.artworkURL` filters this at write
        // time for anything synced by *this* device going forward, but that
        // can't reach docs already persisted before the fix, docs for tracks
        // that have since aged out of the most-recent-25 sync window, or
        // posts written by another user's device on an older build. Rejecting
        // any non-http(s) scheme here catches all of those at render time.
        if let scheme = URL(string: urlString)?.scheme, scheme != "http", scheme != "https" {
            return ""
        }
        let raw = max(1, Int((points * scale).rounded()))
        let px = min(maxPixels, buckets.first(where: { $0 >= raw }) ?? sourcePixels)
        // `/{w}x{h}` immediately before an optional crop suffix + image extension.
        guard let regex = sizeTokenRegex else { return urlString }
        let range = NSRange(urlString.startIndex..., in: urlString)
        return regex.stringByReplacingMatches(
            in: urlString, range: range, withTemplate: "/\(px)x\(px)"
        )
    }
}
