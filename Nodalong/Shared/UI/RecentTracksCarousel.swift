import SwiftUI
import NodalongKit

/// Paged vertical-stack carousel of a user's recent tracks.
///
/// Used by both `ProfileView` (own recents — full callback set) and
/// `UserProfileView` (other user's recents — read-only-ish, no spotlight
/// affordance). Chunks the input post list into pages of `pageSize`
/// (default 10), renders each page as a vertical stack of `TrackCard`s, and
/// lets the user swipe horizontally between pages.
///
/// Page-indicator dots sit beneath the cards. Page count is derived from
/// `posts.count / pageSize`.
struct RecentTracksCarousel: View {
    let posts:        [Post]
    let isSpotlit:    (Post) -> Bool
    let isLiked:      (Post) -> Bool
    let onPlay:       (Post) -> Void
    /// `nil` disables the spotlight button entirely — set this when viewing
    /// someone else's profile (you can't spotlight on their behalf).
    let onSpotlight:  ((Post) -> Void)?
    let onLike:       (Post) -> Void
    /// Optional "Add to Queue" action, offered via each card's "..." button
    /// (`TrackActionsMenuButton`). When `nil`, cards show no queue action.
    var onAddToQueue: ((Post) -> Void)? = nil

    /// Tracks per page. 3 cards × (160 pt card + 6 pt gap) = 498 pt total,
    /// which fits cleanly on every iPhone size class. The old default of 6
    /// looked clipped because `perCard` was 86 pt — half the real TrackCard
    /// height of 160 pt — so only ~3 cards were ever actually visible.
    var pageSize: Int = 6

    @State private var currentPage: Int
    /// The height the *current* page should be right now, sized to its
    /// ACTUAL track count rather than always `pageSize` — fixes a short
    /// last page (fewer than `pageSize` tracks) leaving dead trailing space
    /// inside the rounded `bgBase` box instead of hugging real content.
    /// Mirrors `SpotlightCarousel`'s exact two-layer pinned/animated-crop
    /// pattern: the `TabView`'s own frame stays pinned to `maxPageHeight` so
    /// its UIKit paging view never has to relayout mid-swipe, while this
    /// separate, animated outer crop resizes to the current page's real
    /// height.
    @State private var displayedHeight: CGFloat

    init(posts: [Post],
         isSpotlit: @escaping (Post) -> Bool,
         isLiked: @escaping (Post) -> Bool,
         onPlay: @escaping (Post) -> Void,
         onSpotlight: ((Post) -> Void)?,
         onLike: @escaping (Post) -> Void,
         onAddToQueue: ((Post) -> Void)? = nil,
         pageSize: Int = 6) {
        self.posts = posts
        self.isSpotlit = isSpotlit
        self.isLiked = isLiked
        self.onPlay = onPlay
        self.onSpotlight = onSpotlight
        self.onLike = onLike
        self.onAddToQueue = onAddToQueue
        self.pageSize = pageSize
        _currentPage = State(initialValue: 0)
        let firstPage = Self.computePages(posts: posts, pageSize: pageSize).first ?? []
        _displayedHeight = State(initialValue: Self.pageHeight(for: firstPage))
    }

    private var pages: [[Post]] { Self.computePages(posts: posts, pageSize: pageSize) }

    private static func computePages(posts: [Post], pageSize: Int) -> [[Post]] {
        guard !posts.isEmpty else { return [] }
        return stride(from: 0, to: posts.count, by: pageSize).map { start in
            Array(posts[start..<min(start + pageSize, posts.count)])
        }
    }

    /// Height for one page, sized to its actual track count (not always
    /// `pageSize`). `TrackCard.rowHeight` is the fixed `.row` card height;
    /// the VStack between cards uses 6 pt spacing, so each slot is
    /// `rowHeight + 6`. Reads the constant (not a second hardcoded literal)
    /// for the same reason `SpotlightCarousel` does — so the two can't drift
    /// apart the way `pageHeight` and the card's real rendered size have
    /// before.
    private static func pageHeight(for pagePosts: [Post]) -> CGFloat {
        let perCard: CGFloat = TrackCard.rowHeight + 6
        return CGFloat(max(1, pagePosts.count)) * perCard
    }

    /// The tallest any page will ever render — the TabView's own frame is
    /// pinned here so its internal UIKit paging view never has to resize
    /// itself. Same reasoning as `SpotlightCarousel.maxPageHeight`.
    private var maxPageHeight: CGFloat { CGFloat(pageSize) * (TrackCard.rowHeight + 6) }

    var body: some View {
        if pages.isEmpty {
            EmptyView()
        } else {
            let safeIndex = min(currentPage, pages.count - 1)
            let targetHeight = Self.pageHeight(for: pages[safeIndex])

            VStack(spacing: 8) {
                TabView(selection: $currentPage) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { idx, pagePosts in
                        // The rounded box wraps ONLY the track stack (hugging
                        // its real content height) — the `Spacer` that
                        // absorbs the slack up to the TabView's pinned
                        // `maxPageHeight` sits OUTSIDE it, so a short page
                        // never stretches the box itself. See
                        // `SpotlightCarousel`'s identical fix for the same
                        // bug class.
                        VStack(spacing: 0) {
                            VStack(spacing: 6) {
                                ForEach(pagePosts) { post in
                                    // `layout: .row` — matches Feed's
                                    // TrackCard. `onSpotlight`, when
                                    // non-nil (own profile), routes into the
                                    // "..." menu automatically (same as
                                    // `SpotlightCarousel`) rather than a 4th
                                    // standalone icon — `.row`'s icon column
                                    // is capped at 3 by its 44pt-per-icon
                                    // tap-target minimum, see
                                    // `TrackCard.rowHeight`'s doc comment.
                                    TrackCard(
                                        title:        post.title,
                                        artist:       post.artist,
                                        album:        post.album,
                                        artwork:      post.artwork,
                                        layout:       .row,
                                        nods:         post.nods,
                                        isSpotlit:    isSpotlit(post),
                                        onPlay:       { onPlay(post) },
                                        onSpotlight:  onSpotlight.map { fn in { fn(post) } },
                                        onToggleLike: { onLike(post) },
                                        isLiked:      isLiked(post),
                                        onAddToQueue: onAddToQueue.map { fn in { fn(post) } },
                                        addToPlaylistSong: .from(post: post)
                                    )
                                }
                            }
                            .padding(6)
                            .background(Color.nodalong.bgBase)
                            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                            Spacer(minLength: 0)
                        }
                        .tag(idx)
                        .padding(.horizontal, 2)
                    }
                }
                // .id resets the paging scroll position when the page count
                // changes (e.g. recents finish loading).
                .id(pages.count)
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: maxPageHeight + 12)
                .frame(height: displayedHeight + 12, alignment: .top)
                .clipped()

                // Left/right chevrons (bottom of the container, matching
                // `SpotlightCarousel`'s bare-glyph style — no background
                // circle, no border) with the existing dots centered
                // between them, all on one bottom row — a discrete row, not
                // an overlay, so it can't sit on top of the cards above it.
                if pages.count > 1 {
                    pageArrowsAndDots
                }
            }
            // Widens the WHOLE component (TabView + arrows row together) out
            // from under ProfileView/UserProfileView's ambient
            // .padding(.horizontal, 24) — 8pt more than Feed's own 16pt box
            // padding — landing at that same effective 16pt inset. Must
            // happen at THIS level, not inside the TabView: a negative
            // padding on a page's own content only makes that content WANT
            // to be wider — the TabView still clips each page to its own
            // frame, set by ITS parent, not by what a child page asks for.
            // (An earlier attempt applied this to the page's own `.tag(...)`
            // instead — it visibly clipped the card's left/right edges,
            // since the TabView's frame never actually grew.)
            .padding(.horizontal, -8)
            .onChange(of: targetHeight) { _, newHeight in
                withAnimation(.easeInOut(duration: 0.25)) {
                    displayedHeight = newHeight
                }
            }
        }
    }

    /// Bare chevrons only — no page dots. The dots were a second, redundant
    /// pagination cue once the arrows already communicate "more pages
    /// exist"; removed rather than kept alongside. (Matches `PageArrowsRow`'s
    /// bare-glyph style — no background circle, no border — hand-built
    /// rather than reusing `PageArrowsRow` directly, since that component's
    /// center slot is a plain text label, not the empty space this needs.)
    private var pageArrowsAndDots: some View {
        HStack {
            Button {
                withAnimation { currentPage -= 1 }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(currentPage == 0 ? Color.nodalong.textTertiary : Color.nodalong.textPrimary)
            }
            .disabled(currentPage == 0)

            Spacer()

            Button {
                withAnimation { currentPage += 1 }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(currentPage == pages.count - 1 ? Color.nodalong.textTertiary : Color.nodalong.textPrimary)
            }
            .disabled(currentPage == pages.count - 1)
        }
    }
}

#if DEBUG
#Preview("Carousel – own profile (spotlight + like)") {
    ScrollView {
        RecentTracksCarousel(
            posts:       PreviewFixtures.posts,
            isSpotlit:   { _ in false },
            isLiked:     { _ in false },
            onPlay:      { _ in },
            onSpotlight: { _ in },
            onLike:      { _ in }
        )
        .padding(.horizontal, 16)
    }
    .background(Color.nodalong.bgBase)
    .withPreviewEnvironment()
}

#Preview("Carousel – other user (read-only)") {
    ScrollView {
        RecentTracksCarousel(
            posts:       PreviewFixtures.posts,
            isSpotlit:   { _ in true },
            isLiked:     { _ in false },
            onPlay:      { _ in },
            onSpotlight: nil,    // nil hides the spotlight button
            onLike:      { _ in }
        )
        .padding(.horizontal, 16)
    }
    .background(Color.nodalong.bgBase)
    .withPreviewEnvironment()
}
#endif
