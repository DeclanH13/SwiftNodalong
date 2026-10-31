import CoreGraphics

/// The app's single corner radius.
///
/// Matched to the queue's own rounding, which is not a value in our code at
/// all — `QueueView` uses `.listStyle(.insetGrouped)`, so its corners come
/// from the system. Measured off a device screenshot rather than guessed: a
/// tall inset-grouped section was rendered beside `.continuous` comparators
/// of known radius and the target interpolated against them.
///
/// (A short section had to be discarded first — with a radius near half its
/// own height it clamps toward a capsule and reads far too high. The
/// measurement below uses a section tall enough that no clamping occurs.)
///
/// | known | measured |
/// |-------|----------|
/// | 16pt  | 17.8pt   |
/// | 20pt  | 23.5pt   |
/// | 22pt  | 26.2pt   |
/// | target| 30.3pt → ~25pt |
///
/// **Always pair this with `style: .continuous`.** iOS corners are squircles,
/// not circular arcs; a plain `RoundedRectangle(cornerRadius:)` renders a
/// visibly different curve at the same nominal radius and won't match the
/// queue.
///
/// One deliberate exception: `MiniPlayerBar` keeps its own 32pt pill. It's a
/// floating capsule-shaped control, not a container surface.
enum Corner {
    /// Every container, card, tile, button and badge in the app.
    static let container: CGFloat = 25

    /// Album art, playlist covers and track thumbnails — **square, by
    /// deliberate design choice**.
    ///
    /// Artwork is the one thing in the app that carries no rounding at all.
    /// It's a picture rather than a surface: the sleeve reads as the record
    /// itself, so it sits flush inside the rounded container around it rather
    /// than echoing its shape. Covers everything image-shaped — track-card
    /// sleeves, playlist covers, Top Charts tiles, album heroes.
    ///
    /// Kept as a named constant rather than dropping the `clipShape` calls
    /// entirely so the decision stays visible and reversible in one place.
    /// Circular artwork (avatars, the spinning mini-player disc, a vinyl
    /// label) clips to `Circle()` on its own path and is unaffected.
    static let artwork: CGFloat = 0

    /// Playlist covers. Unlike an album sleeve, a playlist cover is a
    /// collage/picked image with no "record" to preserve, and square corners
    /// read as harsh against the rounded containers around it.
    static let playlistCover: CGFloat = 14
}
