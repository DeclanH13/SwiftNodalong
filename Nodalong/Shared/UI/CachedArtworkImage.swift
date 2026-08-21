import SwiftUI

/// Drop-in replacement for `AsyncImage`, backed by `ArtworkMemoryCache`.
///
/// Two things this does that `AsyncImage` does not:
///
/// 1. **Reads the decoded-image cache synchronously in `init`.** A cache hit
///    therefore renders on the very first frame, with no placeholder at all.
///    This is the part that removes the shimmer flash every time a view
///    reappears — doing the lookup in `.task` instead would still cost one
///    placeholder frame, which is exactly what reads as "pop in."
/// 2. **Decodes off the main thread** via `byPreparingForDisplay()`, so the
///    bitmap handed to SwiftUI is already draw-ready. `AsyncImage` defers the
///    decode to draw time on the main thread.
///
/// Callers are expected to have already run the URL through
/// `ArtworkURL.sized(_:points:)` — that both keeps requests to the three
/// shared size buckets and makes the sized string a stable cache key.
///
/// **Always guard `urlString.isEmpty` at the call site before using this**,
/// the same way the previous `AsyncImage` call sites did: an empty/absent
/// artwork URL should render the caller's own "no artwork" state immediately
/// rather than a placeholder that never resolves.
struct CachedArtworkImage<Placeholder: View, Failure: View>: View {
    private let urlString: String
    /// A smaller bucket's URL for this SAME artwork (e.g. the 160px bucket
    /// when `urlString` is the 600px hero bucket) — a standard progressive/
    /// "blur-up" image technique. `ArtworkURL`'s bucketing means a small
    /// carousel tile and a full-width hero for the same photo are two
    /// distinct cache keys; without this, tapping a tile you've already SEEN
    /// (its thumbnail decoded and cached) still shows a blank shimmer for the
    /// hero because that specific size was never fetched. When a smaller
    /// rendition happens to already be cached, it's shown scaled up and
    /// blurred while the real size loads behind it — closes exactly that gap
    /// with zero extra network requests when there's nothing cached to use.
    private let lowResURLString: String?
    private let placeholder: () -> Placeholder
    private let failure: () -> Failure

    @State private var image: UIImage?
    @State private var lowResImage: UIImage?
    @State private var didFail = false
    /// Which URL `image` actually belongs to.
    ///
    /// Load-bearing. `@State` survives a view UPDATE — SwiftUI only uses
    /// `init`'s `State(initialValue:)` the first time a view identity is
    /// created, never on subsequent updates. So when this view is reused with
    /// a new `urlString` (the full-screen player is one long-lived view whose
    /// URL changes in place on every track change), `image` still holds the
    /// PREVIOUS track's bitmap. Without this, `load()`'s `image != nil`
    /// short-circuit saw that stale bitmap and returned immediately — the
    /// new artwork never loaded, so the player showed the previous track's
    /// cover while title/artist/album updated correctly.
    @State private var loadedURLString: String?

    init(
        urlString: String,
        lowResURLString: String? = nil,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder failure: @escaping () -> Failure
    ) {
        self.urlString = urlString
        self.lowResURLString = lowResURLString
        self.placeholder = placeholder
        self.failure = failure
        // Synchronous — a hit means zero placeholder frames. See (1) above.
        let initial = ArtworkMemoryCache.image(for: urlString)
        _image = State(initialValue: initial)
        _loadedURLString = State(initialValue: initial == nil ? nil : urlString)
        _lowResImage = State(initialValue: lowResURLString.flatMap { ArtworkMemoryCache.image(for: $0) })
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let lowResImage {
                Image(uiImage: lowResImage)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 8)
                    .transition(.opacity)
            } else if didFail {
                failure()
            } else {
                placeholder()
            }
        }
        .animation(.easeOut(duration: 0.2), value: image == nil)
        // `id:` so a recycled cell repointed at a different URL reloads
        // instead of keeping the previous track's artwork.
        .task(id: urlString) { await load() }
    }

    private func load() async {
        // Reused for a DIFFERENT url: whatever is in `image` belongs to the
        // previous one, so it must not be trusted or shown. See
        // `loadedURLString`.
        if loadedURLString != urlString {
            didFail = false
            lowResImage = lowResURLString.flatMap { ArtworkMemoryCache.image(for: $0) }
            if let hit = ArtworkMemoryCache.image(for: urlString) {
                image = hit
                loadedURLString = urlString
                return
            }
            // Nothing cached for the new url — drop the stale bitmap so the
            // placeholder shows rather than the WRONG artwork.
            image = nil
        }

        // Already satisfied by the synchronous `init` read (or a previous
        // run of this task for the same URL).
        if image != nil { return }

        if let hit = ArtworkMemoryCache.image(for: urlString) {
            image = hit
            loadedURLString = urlString
            return
        }
        guard let url = URL(string: urlString) else {
            didFail = true
            return
        }
        // `URLSession.shared` is backed by the app's configured
        // `URLCache.shared`, so a byte-cached image still skips the network —
        // this adds the decoded layer on top rather than replacing it.
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let raw = UIImage(data: data),
              let decoded = await raw.byPreparingForDisplay()
        else {
            didFail = true
            return
        }
        guard !Task.isCancelled else { return }
        ArtworkMemoryCache.store(decoded, for: urlString)
        image = decoded
        loadedURLString = urlString
    }
}
