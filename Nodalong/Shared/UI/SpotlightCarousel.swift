import SwiftUI
import NodalongKit

struct SpotlightDay: Identifiable {
    let dateKey: String
    let tracks: [SpotlightTrack]
    let isToday: Bool
    var id: String { dateKey }
}

/// Horizontally-paginated carousel of spotlight tracks, grouped by day.
///
/// Used on `ProfileView` (own; with `onRemove` / `onPlay`) and
/// `UserProfileView` (read-only). Each page is one `SpotlightDay`.
struct SpotlightCarousel: View {
    let days: [SpotlightDay]
    var onRemove: ((String) -> Void)? = nil
    var onPlay:   ((SpotlightTrack) -> Void)? = nil
    var onAddToQueue: ((SpotlightTrack) -> Void)? = nil

    @State private var currentIndex: Int
    @State private var displayedHeight: CGFloat

    init(days: [SpotlightDay],
         onRemove: ((String) -> Void)? = nil,
         onPlay:   ((SpotlightTrack) -> Void)? = nil,
         onAddToQueue: ((SpotlightTrack) -> Void)? = nil) {
        self.days         = days
        self.onRemove     = onRemove
        self.onPlay       = onPlay
        self.onAddToQueue = onAddToQueue
        let initialIndex = max(0, days.count - 1)
        _currentIndex     = State(initialValue: initialIndex)
        _displayedHeight  = State(initialValue: Self.pageHeight(days: days, index: initialIndex))
    }

    var body: some View {
        // Clamp safeIndex before any subscript so we never crash when `days`
        // becomes empty (e.g. the last spotlight is removed) or when
        // `currentIndex` is stale after the array shrinks.
        let safeIndex = days.isEmpty ? 0 : min(currentIndex, days.count - 1)
        // The height the *current* page should be right now. Computed fresh
        // every render so it reflects not just which page is showing but also
        // that page's own track count — e.g. adding a 2nd/3rd spotlight to
        // today doesn't change `days.count` or `safeIndex`, only this.
        let targetHeight = Self.pageHeight(days: days, index: safeIndex)

        VStack(spacing: 12) {
            HStack {
                Button { withAnimation { currentIndex -= 1 } } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(currentIndex == 0 ? Color.nodalong.textTertiary : Color.nodalong.textPrimary)
                }
                .disabled(currentIndex == 0)

                Spacer()

                if !days.isEmpty {
                    Text(dayLabel(for: days[safeIndex]))
                        .font(Font.nodalong.subheadlineMedium)
                        .foregroundStyle(Color.nodalong.textPrimary)
                }

                Spacer()

                Button { withAnimation { currentIndex += 1 } } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(currentIndex == days.count - 1 ? Color.nodalong.textTertiary : Color.nodalong.textPrimary)
                }
                .disabled(currentIndex == days.count - 1)
            }

            TabView(selection: $currentIndex) {
                ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                    // The rounded box wraps ONLY the track stack (hugging its
                    // real content height) — the `Spacer` that absorbs the
                    // slack up to the TabView's pinned `maxPageHeight` sits
                    // OUTSIDE it. Putting the `Spacer` inside the box (as
                    // before) stretched the box itself to `maxPageHeight`,
                    // so the outer `displayedHeight` crop below sliced
                    // through its middle before the bottom rounded corner
                    // ever got to render — a flat, square-cut bottom edge.
                    VStack(spacing: 0) {
                        VStack(spacing: 12) {
                            // .prefix(maxSpotlights) — the product cap is
                            // currently enforced only client-side at write
                            // time (see `FirebaseAuthViewModel.addToSpotlight`),
                            // so a stale-state race could in principle leave
                            // more than the cap for one day server-side. This
                            // display-layer clamp guarantees the carousel
                            // never renders more than `maxPageHeight` was
                            // pinned for, regardless of the underlying data.
                            ForEach(day.tracks.prefix(maxSpotlights), id: \.trackId) { track in
                                // `onSpotlight` (un-spotlight) is routed into
                                // the "..." menu, not a standalone icon —
                                // `.row`'s icon column already holds heart +
                                // add-to-queue + "...", and a 4th icon can't
                                // fit at the 44pt-per-icon tap-target minimum
                                // that sizes this card (see
                                // `TrackCard.rowHeight`'s doc comment).
                                // `TrackActionsMenuButton` already supports
                                // this via its own `onSpotlight`/`isSpotlit`
                                // params.
                                TrackCard(
                                    title:    track.title,
                                    artist:   track.artist,
                                    album:    track.album,
                                    artwork:  track.artwork,
                                    layout:   .row,
                                    isSpotlit: true,
                                    onPlay:      onPlay.map { fn in { fn(track) } },
                                    onSpotlight: day.isToday ? { onRemove?(track.trackId) } : nil,
                                    onAddToQueue: onAddToQueue.map { fn in { fn(track) } },
                                    addToPlaylistSong: .from(spotlight: track)
                                )
                            }
                        }
                        .padding(6)
                        .background(Color.nodalong.bgBase)
                        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                        Spacer(minLength: 0)
                    }
                    .tag(i)
                    .padding(.horizontal, 2)
                    .padding(.top, Self.shadowInset)
                }
            }
            // .id resets the paging scroll position when the page count changes,
            // ensuring the TabView re-initialises to `currentIndex` (today's page).
            //
            // Height is applied in two layers rather than one animated
            // `.frame(height:)` on the TabView directly: animating a paged
            // TabView's own frame makes its underlying UIKit page-view
            // machinery re-layout mid-transition, which produced both a
            // jarring snap AND a persistently clipped first card. Instead,
            // the TabView's *internal* height is pinned to the tallest page
            // it will ever show (`maxPageHeight`) so its UIKit paging view
            // never has to resize itself — then a second, animated
            // `.frame(height: displayedHeight)` + `.clipped()` crops the
            // *visible window* down to the current page's real height. That
            // outer crop is an ordinary SwiftUI frame animation (no UIKit
            // bridging involved), so it — and the Recent Tracks section
            // below it — resize smoothly in lockstep.
            .id(days.count)
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: maxPageHeight)
            .frame(height: displayedHeight, alignment: .top)
            .clipped()
        }
        // Widens the WHOLE component (header row + TabView together, so
        // they stay aligned) out from under ProfileView/UserProfileView's
        // ambient .padding(.horizontal, 24) — 8pt more than Feed's own
        // 16pt box padding — landing at that same effective 16pt inset.
        // This has to happen at THIS level, not inside the TabView: a
        // negative padding applied to a page's own content (tried first,
        // and reverted) only makes that content WANT to be wider — the
        // TabView still clips each page to its own frame, which is set by
        // ITS parent, not by what a child page asks for. Widening the
        // TabView's actual frame (by widening this whole outer view) is
        // what removes the clip, not padding tricks on the content inside it.
        .padding(.horizontal, -8)
        // When spotlightHistory finishes loading and `days` grows, jump to
        // today (the last / highest-index page). State init is captured once so
        // we can't rely on the initialValue — this onChange is the fix. Height
        // is deliberately NOT set here — the `targetHeight` onChange below is
        // the single path for that, so every height change (new day, page
        // swipe, or the current page's own track count changing) animates
        // uniformly instead of some paths snapping and others not.
        .onChange(of: days.count) {
            currentIndex = max(0, days.count - 1)
        }
        .onChange(of: targetHeight) { _, newHeight in
            withAnimation(.easeInOut(duration: 0.25)) {
                displayedHeight = newHeight
            }
        }
    }

    /// The tallest any page will EVER render — the TabView's own frame is
    /// pinned here so its internal paging view never has to resize itself.
    ///
    /// Deliberately a hardcoded constant from the product-level spotlight cap
    /// (`maxSpotlights`), NOT derived from the current `days` data. An earlier
    /// version computed this as `days.map { $0.tracks.count }.max()`, which
    /// still changed (e.g. 1 → 2 → 3) as spotlights were added to today —
    /// meaning the "pinned" height wasn't actually pinned, and the TabView's
    /// underlying UIKit paging view still had to re-layout on every increase,
    /// reproducing the exact clipping bug this pin was meant to eliminate.
    /// Since `maxSpotlights` is a hard product cap, this value can never
    /// legitimately be exceeded, so hardcoding it makes the pin a true
    /// constant for the view's entire lifetime.
    private var maxPageHeight: CGFloat {
        CGFloat(maxSpotlights) * TrackCard.rowHeight + CGFloat(maxSpotlights - 1) * 12 + Self.shadowInset + Self.containerPadding
    }

    /// Room for the topmost card's drop shadow to render above it before the
    /// outer `.clipped()` boundary — without this, the first card's shadow
    /// (unlike cards 2/3, which have `spacing: 12` between them) sits flush
    /// against the clip edge and gets sliced off, even when there's no
    /// height mismatch to crop. Applied as top padding on each page's
    /// content, and added to both height formulas so it doesn't eat into
    /// space reserved for cards.
    ///
    /// Sized for `.fullBleed`'s shadow (`radius: 14, y: 4`, ~10pt upward
    /// bleed) — carried over unchanged for `.row`'s smaller shadow
    /// (`radius: 8, y: 2`), which needs less headroom, not more, so this
    /// stays a safe, conservative value without needing to be re-tuned.
    private static let shadowInset: CGFloat = 12

    /// The `bgBase` container wrapping each page's cards adds 6pt padding
    /// above and below the card stack — added to both height formulas for
    /// the same reason as `shadowInset`.
    private static let containerPadding: CGFloat = 12

    private static func pageHeight(days: [SpotlightDay], index: Int) -> CGFloat {
        guard !days.isEmpty, days.indices.contains(index) else {
            return TrackCard.rowHeight + shadowInset + containerPadding
        }
        // Clamped to `maxSpotlights` — mirrors the `.prefix(maxSpotlights)` in
        // the rendering loop below, so a day whose underlying data somehow
        // exceeds the cap never sizes taller than `maxPageHeight` was pinned
        // for (which would otherwise clip the container mid-height with a
        // flat, unrounded bottom edge).
        let n = min(maxSpotlights, max(1, days[index].tracks.count))
        return CGFloat(n) * TrackCard.rowHeight + CGFloat(max(0, n - 1)) * 12 + shadowInset + containerPadding
    }

    private func dayLabel(for day: SpotlightDay) -> String {
        if day.isToday { return "Today" }
        guard let date = parseDate(day.dateKey) else { return day.dateKey }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE d MMM"
        return fmt.string(from: date)
    }

    private func parseDate(_ key: String) -> Date? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = .current
        return fmt.date(from: key)
    }
}

#if DEBUG
#Preview {
    // Two days with different track counts, to verify the carousel resizes
    // per-page instead of locking to the historical max (previously a day
    // with 1 spotlight reserved height for 3, leaving a dead gap).
    SpotlightCarousel(days: [
        SpotlightDay(
            dateKey: "2026-06-05",
            tracks: (0..<3).map { i in
                let base = PreviewFixtures.myProfile.spotlightTracks[0]
                return SpotlightTrack(
                    trackId: "catalog-00\(i)",
                    title: base.title, artist: base.artist, album: base.album,
                    artwork: base.artwork, uri: base.uri, spotlitAt: base.spotlitAt,
                    catalogId: base.catalogId, sourceService: base.sourceService
                )
            },
            isToday: false
        ),
        SpotlightDay(
            dateKey: "2026-06-06",
            tracks:  PreviewFixtures.myProfile.spotlightTracks,
            isToday: true
        )
    ])
    .padding()
    .background(Color.black)
}
#endif
