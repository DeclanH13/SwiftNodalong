import SwiftUI
import NodalongKit

/// The full contents of one of Home's capped rails.
///
/// Every rail on Home shows at most ten items and, before this, had nowhere
/// to go — only "Recommended for You" had a see-all. This is one screen for
/// all of them, switching on `HomeSectionID`.
///
/// Modelled on `RecommendedForYouView`: same `ScreenHeader` + `ScrollView` +
/// hidden nav bar + `bgBase`, and deliberately **no** local
/// `.navigationDestination` — it is always pushed onto `HomeView`'s own
/// stack, which already registers every value type pushed from here
/// (`RecentAlbum`, `AlbumResult`, `AlbumGroup`, `FriendsListeningAlbum`), so
/// a duplicate registration here would be redundant at best.
///
/// Every section here reads the SAME already-loaded array its rail does, just
/// without the cap — so opening one costs nothing. The only network it causes
/// is the per-cell DESTINATION prefetch (see `prefetchResolve`), the same one
/// every Home rail tile does. Top Charts used to be the exception (its rail was
/// capped at the fetch, so its see-all re-fetched at 50), and that section has
/// since been retired along with the fetch.
struct HomeSeeAllView: View {
    let section: HomeSectionID

    @EnvironmentObject private var homeVM:      HomeViewModel
    @EnvironmentObject private var libraryVM:   LibraryViewModel
    @EnvironmentObject private var feedVM:      FeedViewModel
    @EnvironmentObject private var playerVM:    PlayerViewModel
    @EnvironmentObject private var musicService: AppleMusicService

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                // In-content heading: this screen is a bare grid or list, so
                // the section name is its only identity.
                ScreenTitle(section.title)
                content
                    .padding(.vertical, 16)
                if playerVM.nowPlaying != nil {
                    Color.clear.frame(height: 70)
                }
            }
            .gatesMarqueeToScrollSettle()
        }
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .screenControls()
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .jumpBackIn:
            grid(homeVM.recentAlbums) { album in
                NavigationLink(value: album) {
                    albumTile(artwork: album.artwork, title: album.albumName,
                              subtitle: album.artistName, isExplicit: album.isExplicit)
                }
                .buttonStyle(.plain)
                .task(id: album.id, priority: .utility) {
                    await prefetchResolve(key: album.id, uri: album.uri, isrc: album.isrc, albumName: album.albumName,
                                          artistName: album.artistName, trackTitle: album.trackTitle, artwork: album.artwork)
                }
            }

        case .newReleases:
            grid(homeVM.newReleases) { album in
                NavigationLink(value: album) {
                    albumTile(artwork: album.artwork, title: album.name,
                              subtitle: releaseSubtitle(album), isExplicit: album.isExplicit)
                }
                .buttonStyle(.plain)
                .task(id: album.id, priority: .utility) {
                    guard playerVM.activeService == .appleMusic else { return }
                    await CatalogPrefetch.album(id: album.id, name: album.name, artwork: album.artwork,
                                                releaseDate: album.releaseDate, artist: album.artistName,
                                                service: musicService)
                }
            }

        case .friendsListening:
            grid(feedVM.friendsListeningAlbums) { album in
                NavigationLink(value: album) {
                    albumTile(artwork: album.artwork, title: album.albumName,
                              subtitle: album.artistName, isExplicit: false)
                }
                .buttonStyle(.plain)
                .task(id: album.id, priority: .utility) {
                    await prefetchResolve(key: album.id, uri: album.uri, isrc: album.isrc, albumName: album.albumName,
                                          artistName: album.artistName, trackTitle: album.trackTitle, artwork: album.artwork)
                }
            }

        case .recentlyAdded:
            // `libraryVM.recentAlbumGroups` is itself capped at 10, so this
            // re-derives the full list from `albumGroups` with the same
            // newest-save-first ordering rather than reusing it.
            grid(libraryVM.albumGroupsByRecency) { group in
                NavigationLink(value: group) {
                    albumTile(artwork: group.artwork, title: group.albumName,
                              subtitle: group.artistName, isExplicit: group.isExplicit)
                }
                .buttonStyle(.plain)
            }

        case .cityCharts:
            trackList(homeVM.cityChartSongs, songs: homeVM.cityChartSongs)

        case .genreCharts:
            trackList(homeVM.genreChartSongs, songs: homeVM.genreChartSongs)

        case .mostNodded:
            trackList(NodalongKit.mostNoddedPosts(from: feedVM.posts, since: weekAgoMs, limit: 50))

        // `hasSeeAll` is false for these, so the header never offers a link
        // and this branch is unreachable in practice — kept exhaustive
        // rather than defaulting, so adding a section forces a decision here.
        case .liveNow, .friendsSpotlights, .madeByPeople, .foundForYou, .recommended, .newMusicDaily, .weeklyRecap:
            Text("Nothing more to show here.")
                .font(Font.nodalong.caption)
                .foregroundStyle(Color.nodalong.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        }
    }

    // MARK: - Pieces

    /// Per-cell prefetch for the two sections whose destination resolves a
    /// track to its album (`RecentAlbum`, `FriendsListeningAlbum`). Same key
    /// as the Home rail tile and the destination — `album.id` — so all three
    /// share one cache entry. The cells sit in a `LazyVGrid`, so only cells
    /// actually built (and lingered on) cost anything.
    private func prefetchResolve(key: String, uri: String, isrc: String?, albumName: String,
                                 artistName: String, trackTitle: String, artwork: String) async {
        guard playerVM.activeService == .appleMusic else { return }
        await CatalogPrefetch.albumResolve(key: key, uri: uri, isrc: isrc, albumName: albumName,
                                           artistName: artistName, trackTitle: trackTitle,
                                           artwork: artwork, service: musicService)
    }

    @ViewBuilder
    private func grid<T: Hashable, Cell: View>(
        _ items: [T],
        @ViewBuilder cell: @escaping (T) -> Cell
    ) -> some View {
        if items.isEmpty {
            emptyState
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(items, id: \.self) { cell($0) }
            }
            .padding(.horizontal, 16)
        }
    }

    private func albumTile(artwork: String, title: String, subtitle: String, isExplicit: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkThumbnail(url: artwork, size: tileWidth, isAlbum: true, onStand: true)
            HStack(spacing: 4) {
                MarqueeText(text: title, font: Font.nodalong.captionSemibold, color: Color.nodalong.textPrimary)
                if isExplicit { ExplicitBadge() }
            }
            Text(subtitle)
                .font(Font.nodalong.caption2)
                .foregroundStyle(Color.nodalong.textSecondary)
                .lineLimit(1)
        }
        .frame(width: tileWidth, alignment: .leading)
    }

    /// Two columns inside the same 16pt page margins the rails use, with a
    /// 14pt gutter — derived rather than hardcoded so it stays right on
    /// every device width.
    private var tileWidth: CGFloat {
        (ScreenMetrics.bounds.width - 32 - 14) / 2
    }

    /// Track rows. `songs` is what tapping plays in context; when it's nil
    /// the rows are `Post`-derived and play the whole list the same way.
    @ViewBuilder
    private func trackList(_ posts: [Post]) -> some View {
        if posts.isEmpty {
            emptyState
        } else {
            let songs = posts.map { Song.from(post: $0) }
            LazyVStack(spacing: 0) {
                ForEach(Array(posts.enumerated()), id: \.element.id) { index, post in
                    Button {
                        Task { await playerVM.play(songs, startingAt: index) }
                    } label: {
                        trackRow(
                            rank: index + 1, artwork: post.artwork,
                            title: post.title, artist: post.artist, nods: post.nods
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color.nodalong.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func trackList(_ items: [Song], songs: [Song]) -> some View {
        if items.isEmpty {
            emptyState
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, song in
                    Button {
                        Task { await playerVM.play(songs, startingAt: index) }
                    } label: {
                        trackRow(
                            rank: index + 1, artwork: song.artwork,
                            title: song.title, artist: song.artist, nods: nil
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color.nodalong.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
            .padding(.horizontal, 16)
        }
    }

    private func trackRow(rank: Int, artwork: String, title: String, artist: String, nods: Int?) -> some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(Font.nodalong.subheadlineMedium)
                .foregroundStyle(Color.nodalong.textSecondary)
                .frame(width: 24, alignment: .trailing)
            ArtworkThumbnail(url: artwork, size: 40, isTrack: true)
            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(text: title, font: Font.nodalong.subheadlineMedium, color: Color.nodalong.textPrimary)
                Text(artist)
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let nods {
                HStack(spacing: 3) {
                    Image(systemName: "flame.fill").font(.system(size: 12))
                    Text("\(nods)").font(Font.nodalong.captionMedium)
                }
                .foregroundStyle(Color.nodalong.gold)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .contentShape(.rect)
    }

    private var emptyState: some View {
        Text("Nothing here yet.")
            .font(Font.nodalong.caption)
            .foregroundStyle(Color.nodalong.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
    }

    // MARK: - Data

    private var weekAgoMs: Double {
        Date().addingTimeInterval(-7 * 24 * 3600).timeIntervalSince1970 * 1000
    }

    /// "Bon Iver · 2 days ago" — the release's own recency is the whole
    /// reason it's in this section, so it earns the subtitle slot.
    private func releaseSubtitle(_ album: AlbumResult) -> String {
        guard let date = Self.releaseDateFormatter.date(from: album.releaseDate) else {
            return album.artistName
        }
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        let when: String
        switch days {
        case ..<1:  when = "today"
        case 1:     when = "yesterday"
        case ..<7:  when = "\(days) days ago"
        case ..<14: when = "last week"
        default:    when = "\(days / 7) weeks ago"
        }
        return "\(album.artistName) · \(when)"
    }

    private static let releaseDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

#if DEBUG
#Preview {
    NavigationStack {
        HomeSeeAllView(section: .mostNodded)
    }
    .withPreviewEnvironment()
}
#endif
