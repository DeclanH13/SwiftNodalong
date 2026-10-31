import SwiftUI
import NodalongKit

/// Full-bleed artwork card matching the React Native TrackCard design.
/// Artwork fills the background; a dark gradient overlay floats the content.
/// Reusable track card used by Feed, Profile, Shelf, and Search.
///
/// Shows artwork, title, artist, optional user attribution (avatar + name),
/// nod count, spotlight indicator, like button. All callbacks are optional so
/// each screen wires up only what it needs.
///
/// When `onAddToQueue` or `addToPlaylistSong` is provided, the card shows a
/// visible **"..." button** (`TrackActionsMenuButton`) offering "Add to
/// Queue" / "Add to Playlist…" — like/spotlight stay as TrackCard's own
/// separate visible icons since there's room for them here. (This replaced
/// an undiscoverable long-press menu, which itself had replaced an even
/// older right-swipe affordance that collided with the system interactive
/// back-swipe.)
struct TrackCard: View {
    /// Which physical shape this card renders as.
    ///
    /// `.fullBleed` is the original: artwork fills a 160pt card with a black
    /// scrim and white text floated on top. Still used by Profile's Recent
    /// Tracks and Home's Friends' Spotlights rail — the latter is a
    /// horizontally-scrolling 220pt-wide rail, where a wide row genuinely
    /// does not fit (confirmed by mockup: after the sleeve cluster and icon
    /// column, the title is left ~60pt and collapses to an ellipsis).
    ///
    /// `.row` is the vinyl sleeve layout: a record sleeve with the disc
    /// sliding out from behind it on the left, a three-line text column, and
    /// a vertical icon column on the right. Used by Feed and the Spotlight
    /// carousel.
    enum Layout { case fullBleed, row }

    /// Fixed height of a `.row` card. Derived from the icon column, which is
    /// the binding constraint: three controls at Apple's 44pt minimum touch
    /// target (132pt) plus 12pt padding top and bottom. Anything less makes
    /// adjacent icons' touch regions overlap so they steal each other's taps.
    ///
    /// `SpotlightCarousel` sizes its pages off this rather than its own
    /// literal — that file's own doc comments record a multi-round history of
    /// a "pinned" height silently drifting out of step with what actually
    /// rendered, so the two must read from one source.
    static let rowHeight: CGFloat = 156

    let title:      String
    let artist:     String
    let album:      String
    let artwork:    String

    var layout: Layout = .fullBleed

    var username:    String? = nil
    var avatarColor: String? = nil
    var nods:        Int?    = nil
    var isSpotlit:   Bool    = false

    var onPlay:        (() -> Void)? = nil
    var onToggleLike:  (() -> Void)? = nil
    var isLiked:       Bool          = false
    var onAddToQueue:  (() -> Void)? = nil
    /// When set, the long-press menu also offers "Add to Playlist…" for this
    /// track. Optional so callers that only support queueing can omit it.
    var addToPlaylistSong: Song? = nil
    /// When set, tapping the attribution chip (avatar + username) navigates
    /// to that user's profile instead of doing nothing — separate from the
    /// card's own `onPlay` tap, which covers the rest of the card.
    var onTapUser: (() -> Void)? = nil

    /// Drives the spotlit glow/border/badge breathing pulse — ping-pongs
    /// 0↔1 via a single `repeatForever` animation (`onAppear`, spotlit cards
    /// only), so every visual property below is a plain derived expression,
    /// not its own timer. GPU-composited (shadow + scale), and SwiftUI
    /// suspends the animation automatically once the view leaves the screen.
    ///
    /// `.row` never starts this — the gold wash it animates is a wash OVER
    /// artwork, which `.row` doesn't have (it sits on a solid `bgCard`,
    /// not a full-bleed photo), and every card in `SpotlightCarousel` is
    /// spotlit, so a full page running three concurrent breathing
    /// animations was flagged as an idle-CPU cost worth avoiding rather
    /// than paying for a visual `.row` can't use anyway.
    @State private var spotlightPulse: CGFloat = 0

    /// Follows the app-wide vinyl/square preference (Profile → "Artwork
    /// Style") that every other album-artwork context already respects via
    /// `ArtworkThumbnail(isAlbum:/isTrack:)`. `.row`'s sleeve-and-disc cluster
    /// is built from `VinylArtworkView` directly (not through that flag, since
    /// it composes the disc with a second, separately-clipped sleeve layer
    /// `ArtworkThumbnail` doesn't support) — reading the same `@AppStorage`
    /// key here is what keeps it obeying the same user setting instead of
    /// silently ignoring it for just these two surfaces.
    @AppStorage(albumArtworkStyleKey) private var albumArtworkStyleRaw = AlbumArtworkStyle.vinyl.rawValue

    var body: some View {
        switch layout {
        case .fullBleed: fullBleedBody
        case .row:        rowBody
        }
    }

    // MARK: - Spotlit row ink
    //
    // `.row` sits on the app's own `bgCard`, not on artwork, so when it turns
    // to foil there is nothing dark behind the text — every label has to flip
    // to ink or it disappears. `.fullBleed` needs no equivalent: its text sits
    // on the black legibility scrim at the bottom of the card.

    private var rowPrimaryInk: Color {
        isSpotlit ? SpotlightFoil.ink : Color.nodalong.textPrimary
    }
    private var rowSecondaryInk: Color {
        isSpotlit ? SpotlightFoil.ink.opacity(0.75) : Color.nodalong.textSecondary
    }

    private var fullBleedBody: some View {
        cardContent
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
            .overlay {
                // A spotlit card no longer needs a gold RING — the whole card
                // is foil. What it still needs is definition against the
                // background, so it keeps a hairline in the ramp's darkest
                // stop rather than the bright token.
                RoundedRectangle(cornerRadius: Corner.container, style: .continuous)
                    .strokeBorder(
                        isSpotlit
                            ? Color(hex: "#8E6C1F").opacity(0.9)
                            : Color.nodalong.textOnAccent.opacity(0.08),
                        lineWidth: isSpotlit ? 1 : 0.5
                    )
            }
            .shadow(color: .black.opacity(0.2), radius: 14, y: 4)
            .shadow(
                color: isSpotlit ? SpotlightFoil.glow.opacity(0.40 + 0.45 * spotlightPulse) : .clear,
                radius: isSpotlit ? 16 + 18 * spotlightPulse : 0
            )
            .onAppear {
                guard isSpotlit else { return }
                withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                    spotlightPulse = 1
                }
            }
    }

    // MARK: - Card content

    private var cardContent: some View {
        // Cap the decode at the 600 px source rather than the (larger) 3× display
        // width — same on-screen quality, far smaller bitmap in RAM.
        let sizedArtwork = ArtworkURL.sized(artwork, points: ScreenMetrics.bounds.width)
        return Group {
            if isSpotlit {
                // Foil is the SURFACE; the artwork below is composited onto
                // it rather than the other way round. See `SpotlightFoil`.
                SpotlightFoil.sheen
            } else {
                Color.nodalong.bgCard
            }
        }
            .overlay {
                if sizedArtwork.isEmpty {
                    // No artwork exists for this track (MusicKit catalog gap) —
                    // show this immediately rather than an AsyncImage stuck
                    // forever in `.empty` waiting on a URL that will never arrive.
                    noArtworkPlaceholder
                } else {
                    CachedArtworkImage(
                        urlString: sizedArtwork,
                        placeholder: { ShimmerView() },
                        failure: { noArtworkPlaceholder }
                    )
                    // `.multiply` keeps the foil dominant and lets the cover
                    // modulate it — the art reads as pressed into the metal.
                    // Multiply is commutative, so compositing the art over
                    // the foil gives the same result as the reverse.
                    .opacity(isSpotlit ? SpotlightFoil.artworkOpacity : 1)
                    .blendMode(isSpotlit ? .multiply : .normal)
                }
            }
            // Confines the blend to this card — without it `.multiply` would
            // composite against whatever sits behind the card too.
            .compositingGroup()
            .overlay {
                // Deliberately absolute black, not an adaptive token — this
                // scrims text over unpredictable album-art photos for
                // legibility, not the app's own background, so it shouldn't
                // change with light/dark mode.
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.0),  location: 0.0),
                        .init(color: .black.opacity(0.0),  location: 0.55),
                        .init(color: .black.opacity(0.55), location: 0.80),
                        .init(color: .black.opacity(0.88), location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .overlay {
                VStack(spacing: 0) {
                    // Top row
                    HStack(alignment: .center, spacing: 8) {
                        if let username {
                            userChip(username: username, color: avatarColor, nods: nods)
                        } else if let nods, nods > 0 {
                            nodChip(nods: nods)
                        } else {
                            Spacer().frame(height: 24)
                        }
                        Spacer(minLength: 8)
                        HStack(spacing: 14) {
                            if isSpotlit {
                                HStack(spacing: 3) {
                                    Image(systemName: Icons.star)
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(SpotlightFoil.ink)
                                    Text("Spotlight")
                                        .font(Font.nodalong.custom(10, .medium))
                                        .foregroundStyle(SpotlightFoil.ink)
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                // Frosted, not gold — a gold pill on a gold
                                // card is invisible.
                                .background(SpotlightFoil.badgeBacking)
                                .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                                .scaleEffect(1 + 0.12 * spotlightPulse)
                                // Never compress/wrap this badge — under
                                // space pressure (badge + like + "..." all
                                // competing for room), let the username chip
                                // truncate further instead (it already has
                                // .lineLimit(1)), not "Spotlight" wrapping to
                                // two lines.
                                .fixedSize(horizontal: true, vertical: false)
                            }
                            if let onToggleLike {
                                Button(action: onToggleLike) {
                                    Image(systemName: isLiked ? Icons.heart : Icons.heartOutline)
                                        .font(.system(size: 22))
                                        .foregroundStyle(isLiked ? Color.nodalong.purpleAccent : Color.nodalong.textOnAccent.opacity(0.85))
                                        .shadow(color: .black.opacity(0.7), radius: 4, y: 1)
                                }
                                .buttonStyle(.plain)
                            }
                            // One-tap queueing alongside the other visible
                            // actions. Party-aware via `AddToQueueButton` —
                            // see its doc comment for why this can't just
                            // call `onAddToQueue` directly.
                            if onAddToQueue != nil {
                                AddToQueueButton(
                                    song: addToPlaylistSong,
                                    onAddToQueue: onAddToQueue,
                                    overArtwork: true
                                )
                            }
                        }
                    }

                    Spacer()

                    // Bottom: track info + "..." menu, bottom-right.
                    HStack(alignment: .bottom, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title)
                                .font(Font.nodalong.custom(15, .semibold))
                                .foregroundStyle(Color.nodalong.textOnAccent)
                                .lineLimit(1)
                                .shadow(color: .black.opacity(0.8), radius: 6, y: 1)
                            Text(album.isEmpty ? artist : "\(artist) · \(album)")
                                .font(Font.nodalong.custom(12))
                                .foregroundStyle(Color.nodalong.textOnAccent.opacity(0.9))
                                .lineLimit(1)
                                .shadow(color: .black.opacity(0.7), radius: 4, y: 1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if let addToPlaylistSong {
                            TrackActionsMenuButton(song: addToPlaylistSong, onAddToQueue: onAddToQueue)
                                .shadow(color: .black.opacity(0.7), radius: 4, y: 1)
                        }
                    }
                }
                .padding(14)
            }
            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
            .onTapGesture { onPlay?() }
    }

    // MARK: - Row layout

    /// A record sleeve with the disc sliding out from behind it — real
    /// artwork at full square size PLUS the vinyl motif, rather than the
    /// bare disc `VinylArtworkView` alone would give (which shows only
    /// ~29pt of actual artwork at this cluster size, per the mockup that
    /// ruled it out).
    private var rowBody: some View {
        HStack(alignment: .center, spacing: 12) {
            sleeveAndDisc

            VStack(alignment: .leading, spacing: 4) {
                if isSpotlit {
                    HStack(spacing: 3) {
                        Image(systemName: Icons.star)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(SpotlightFoil.ink)
                        Text("Spotlight")
                            .font(Font.nodalong.custom(10, .medium))
                            .foregroundStyle(SpotlightFoil.ink)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(SpotlightFoil.badgeBacking)
                    .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                    .fixedSize(horizontal: true, vertical: false)
                }
                Text(title)
                    .font(Font.nodalong.custom(15, .semibold))
                    .foregroundStyle(rowPrimaryInk)
                    .lineLimit(1)
                Text(artist)
                    .font(Font.nodalong.custom(12))
                    .foregroundStyle(rowSecondaryInk)
                    .lineLimit(1)
                if !album.isEmpty {
                    Text(album)
                        .font(Font.nodalong.custom(12))
                        .foregroundStyle(rowSecondaryInk.opacity(0.8))
                        .lineLimit(1)
                }
                if let username {
                    rowAttribution(username: username, color: avatarColor, nods: nods)
                } else if let nods, nods > 0 {
                    Text("\(nods) \(nods == 1 ? "nod" : "nods")")
                        .font(Font.nodalong.custom(11))
                        .foregroundStyle(rowSecondaryInk)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            rowIconColumn
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(height: Self.rowHeight)
        .background {
            // Whole-row foil, matching `.fullBleed`. No artwork multiply here
            // — the row shows its cover as a separate sleeve/disc cluster
            // rather than as the surface itself.
            if isSpotlit { SpotlightFoil.sheen } else { Color.nodalong.bgCard }
        }
        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Corner.container, style: .continuous)
                .strokeBorder(
                    isSpotlit ? Color(hex: "#8E6C1F").opacity(0.9) : Color.nodalong.textPrimary.opacity(0.08),
                    lineWidth: isSpotlit ? 1 : 0.5
                )
        }
        // Much lighter than `.fullBleed`'s shadow — this card sits on the
        // app's own flat `bgCard`, not a floating photo, and it's already
        // distinct from `bgBase` via color contrast alone. A heavier shadow
        // read as "the card is sitting inside its own little container,"
        // which is exactly the boxed look the bgBase/bgCard two-tier system
        // was built to move away from — this is a whisper of lift, not a
        // container cue.
        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        .onTapGesture { onPlay?() }
    }

    /// Respects the app-wide vinyl/square preference (see `albumArtworkStyleRaw`
    /// above) — with vinyl OFF, this collapses to a single plain square rather
    /// than rendering two identical, indistinguishable squares stacked on top
    /// of each other. Frame width stays fixed either way, so the text column
    /// doesn't shift when the setting is toggled.
    private var sleeveAndDisc: some View {
        let sleeveSize: CGFloat = 108
        let discOffset: CGFloat = 30
        let isVinylStyle = AlbumArtworkStyle(rawValue: albumArtworkStyleRaw) == .vinyl
        return ZStack(alignment: .leading) {
            if isVinylStyle {
                // `showsGrooves: false` — matches `ArtworkThumbnail(isTrack:
                // true)`'s existing convention: a single track in a mixed
                // list gets the calmer groove-less disc, distinct from a
                // genuine album context (`isAlbum: true`, grooves shown).
                VinylArtworkView(url: artwork, size: sleeveSize, showsGrooves: false)
                    .offset(x: discOffset)
            }
            ArtworkThumbnail(url: artwork, size: sleeveSize)
                .clipShape(RoundedRectangle(cornerRadius: Corner.artwork, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Corner.artwork, style: .continuous)
                        .strokeBorder(Color.nodalong.textPrimary.opacity(0.12), lineWidth: 0.5)
                )
        }
        .frame(width: sleeveSize + discOffset, height: sleeveSize, alignment: .leading)
    }

    @ViewBuilder
    private func rowAttribution(username: String, color: String?, nods: Int?) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color(hex: color ?? Theme.Colors.purpleMid))
                .frame(width: 16, height: 16)
                .overlay {
                    Text(String(username.prefix(1)).uppercased())
                        .font(Font.nodalong.custom(8, .bold))
                        .foregroundStyle(Color.nodalong.textOnAccent)
                }
            Text(username)
                .font(Font.nodalong.custom(11, .medium))
                .foregroundStyle(Color.nodalong.textSecondary)
                .lineLimit(1)
            if let nods, nods > 0 {
                Text("· \(nods) \(nods == 1 ? "nod" : "nods")")
                    .font(Font.nodalong.custom(11))
                    .foregroundStyle(Color.nodalong.textSecondary.opacity(0.75))
            }
        }
        .contentShape(.rect)
        .onTapGesture { onTapUser?() }
    }

    private var rowIconColumn: some View {
        VStack(spacing: 0) {
            if let onToggleLike {
                Button(action: onToggleLike) {
                    Image(systemName: isLiked ? Icons.heart : Icons.heartOutline)
                        .font(.system(size: 20))
                        .foregroundStyle(isLiked ? Color.nodalong.purpleAccent : rowSecondaryInk.opacity(0.8))
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            // A standalone queue icon lived here once and was removed,
            // because it called `onAddToQueue` directly and so silently
            // added to the PERSONAL queue even during a live party
            // (confirmed on device). It's back by request as a one-tap
            // affordance — but via `AddToQueueButton`, which applies the
            // same party routing the "..." menu does. The menu keeps its own
            // queue entry too; both now reach the same destination, so
            // having two entry points is no longer a correctness problem.
            if onAddToQueue != nil {
                AddToQueueButton(song: addToPlaylistSong, onAddToQueue: onAddToQueue,
                                 tint: isSpotlit ? SpotlightFoil.ink.opacity(0.8) : nil)
                    .frame(width: 44, height: 44)
            }
            if let addToPlaylistSong {
                TrackActionsMenuButton(
                    song: addToPlaylistSong,
                    onAddToQueue: onAddToQueue,
                    tint: isSpotlit ? SpotlightFoil.ink.opacity(0.8) : nil
                )
                .frame(width: 44, height: 44)
            }
        }
    }

    // MARK: - Sub-views

    /// Shown both when a track has no artwork (empty URL) and when a real
    /// artwork URL fails to load — a deliberate "no art" state reads as
    /// intentional rather than broken.
    private var noArtworkPlaceholder: some View {
        Color.nodalong.bgCard
            .overlay {
                Image(systemName: Icons.musicalNote)
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(Color.nodalong.textPrimary.opacity(0.25))
            }
    }

    @ViewBuilder
    private func userChip(username: String, color: String?, nods: Int?) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color(hex: color ?? Theme.Colors.purpleMid))
                .frame(width: 18, height: 18)
                .overlay {
                    Text(String(username.prefix(1)).uppercased())
                        .font(Font.nodalong.custom(9, .bold))
                        .foregroundStyle(Color.nodalong.textOnAccent)
                }
            Text(username)
                .font(Font.nodalong.custom(11, .medium))
                .foregroundStyle(Color.nodalong.textOnAccent)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.7), radius: 4, y: 1)
            if let nods, nods > 0 {
                Text("· \(nods) \(nods == 1 ? "nod" : "nods")")
                    .font(Font.nodalong.custom(11))
                    .foregroundStyle(Color.nodalong.textOnAccent.opacity(0.85))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.black.opacity(0.40))
        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        .onTapGesture { onTapUser?() }
    }

    @ViewBuilder
    private func nodChip(nods: Int) -> some View {
        Text("\(nods) \(nods == 1 ? "nod" : "nods")")
            .font(Font.nodalong.custom(11))
            .foregroundStyle(Color.nodalong.textOnAccent.opacity(0.85))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.black.opacity(0.40))
            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
    }
}

#if DEBUG
#Preview {
    ScrollView {
        VStack(spacing: 12) {
            TrackCard(
                title:        PreviewFixtures.song.title,
                artist:       PreviewFixtures.song.artist,
                album:        PreviewFixtures.song.album,
                artwork:      PreviewFixtures.song.artwork,
                username:     "alex",
                avatarColor:  "#F59E0B",
                nods:         7,
                isSpotlit:    true,
                onPlay:       {},
                isLiked:      true,
                onAddToQueue: {}
            )
            TrackCard(
                title:        "No queue action",
                artist:       "No swipe",
                album:        "",
                artwork:      PreviewFixtures.song.artwork
            )
            TrackCard(
                title:        "No artwork available",
                artist:       "Missing catalog art",
                album:        "",
                artwork:      ""
            )

            Divider().padding(.vertical, 8)

            TrackCard(
                title:        PreviewFixtures.song.title,
                artist:       PreviewFixtures.song.artist,
                album:        PreviewFixtures.song.album,
                artwork:      PreviewFixtures.song.artwork,
                layout:       .row,
                username:     "alex",
                avatarColor:  "#F59E0B",
                nods:         7,
                onPlay:       {},
                onToggleLike: {},
                isLiked:      true,
                onAddToQueue: {},
                addToPlaylistSong: PreviewFixtures.song
            )
            TrackCard(
                title:        "Row, spotlit",
                artist:       "No album line",
                album:        "",
                artwork:      PreviewFixtures.song.artwork,
                layout:       .row,
                nods:         12,
                isSpotlit:    true,
                onPlay:       {},
                onToggleLike: {},
                onAddToQueue: {},
                addToPlaylistSong: PreviewFixtures.song
            )
        }
        .padding()
    }
    .background(Color.black)
}
#endif
