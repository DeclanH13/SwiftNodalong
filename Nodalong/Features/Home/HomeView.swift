import SwiftUI
import NodalongKit

/// Home/Hub tab — the "for you" landing screen. Distinct from Feed (strictly
/// "people you follow"): Home is about the individual using the app — who's
/// live right now, albums you've recently resumed (with a replay badge
/// folded in), friends' deliberate spotlight picks, what's trending globally,
/// Apple Music's own personalized album/playlist recommendations, and what
/// you've most recently saved to your library. Each section is a distinct
/// content type and data source, not a re-slice of the same recent-activity
/// data.
///
/// Mirrors `ProfileView`'s established `hasLoaded`/`.refreshable` pattern —
/// loads once per session, pull-to-refresh forces a re-fetch.
struct HomeView: View {
    @Environment(FirebaseAuthViewModel.self) private var authVM
    @EnvironmentObject private var homeVM:      HomeViewModel
    @EnvironmentObject private var musicService: AppleMusicService
    @EnvironmentObject private var spotifyService: SpotifyMusicService
    @EnvironmentObject private var playerVM:    PlayerViewModel
    @EnvironmentObject private var libraryVM:   LibraryViewModel
    @EnvironmentObject private var syncService: LibrarySyncService
    /// Backs "Friends are listening to" / "Most nodded this week" — both are
    /// pure client-side aggregations over the SAME follows-only feed data
    /// `FeedView` already fetches, not a new Firestore query.
    @EnvironmentObject private var feedVM:      FeedViewModel
    /// Owns this tab's own `NavigationPath` (`router.homePath`) — also lets
    /// `NowPlayingView`/`PartyView` push here after dismissing themselves,
    /// which private `@State` never could. See `AppRouter`'s doc comment.
    @EnvironmentObject private var router:      AppRouter

    @State private var hasLoaded = false
    /// Guards a Live Now avatar tap while that user's profile is resolving.
    @State private var isResolvingLiveNowUser = false
    /// Tap→open zoom transition for album tiles — see
    /// `SearchView.zoomNamespace`'s doc comment for why this has to live on
    /// the screen that owns the `NavigationStack`. Threaded into
    /// `RecommendedForYouView` too, since it's pushed onto this same stack
    /// and shares this stack's `AlbumResult` destination.
    @Namespace private var zoomNamespace

    /// Whichever backend is actually connected — the play gate must check
    /// this, not hardcode Apple Music.
    private var activeService: any MusicService {
        activeMusicService(playerVM: playerVM, apple: musicService, spotify: spotifyService)
    }

    /// True only on a genuine first-ever launch — no snapshot to restore from
    /// and nothing has landed from the network yet. `HomeViewModel.load()`
    /// assigns each section as its own fetch completes, so this becomes
    /// false (and the real sections take over one by one) well before the
    /// slowest section finishes.
    private var showFirstLaunchSkeletons: Bool {
        (homeVM.isLoading || libraryVM.isLoading) && !homeVM.restoredFromSnapshot
            && homeVM.recentAlbums.isEmpty && homeVM.topChartSongs.isEmpty
            && libraryVM.tracks.isEmpty && homeVM.recommendationShelves.isEmpty
    }

    /// "Recently Added" — deliberately Nodalong's own Shelf, NOT the user's
    /// Apple Music library (which is what this used to source from; changed
    /// per direct user request — Apple Music additions and Shelf saves are
    /// two independent collections by design, see `ShelfView`'s own doc
    /// comment, and this section is meant to reflect Nodalong activity).
    /// Derived purely from `libraryVM.tracks` (already loaded app-wide, no
    /// separate fetch) via the same `groupByAlbum` Shelf's own grid uses,
    /// then re-sorted by each group's most-recently-saved track instead of
    /// Shelf's own artist-then-release-date ordering.
    /// Computed by `LibraryViewModel` once per library change — NOT here.
    ///
    /// This previously ran the full `groupByAlbum` over the entire library
    /// and then sorted with a comparator that allocated two arrays per
    /// comparison. Because it lived in a view computed property, it re-ran on
    /// every `HomeView` body evaluation — and `HomeView` observes NINE
    /// app-wide objects (~62 `@Published` properties between them), so
    /// something as routine as `isPlaying` toggling re-grouped a 441-track
    /// library on the main thread. That was the Home scroll stutter.
    private var recentShelfAlbums: [AlbumGroup] { libraryVM.recentAlbumGroups }

    var body: some View {
        NavigationStack(path: $router.homePath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    greeting

                    if showFirstLaunchSkeletons {
                        section(title: "Jump Back In") { SkeletonRail() }
                        section(title: "Top Charts") { SkeletonRail() }
                        section(title: "Recently Added") { SkeletonRail() }
                    }

                    if !homeVM.liveNow.isEmpty {
                        section(title: "Live Now") {
                            liveNowRail
                        }
                    }

                    if !homeVM.recentAlbums.isEmpty {
                        section(title: "Jump Back In") {
                            jumpBackInRail
                        }
                    }

                    if !homeVM.friendsSpotlights.isEmpty {
                        section(title: "Friends' Spotlights") {
                            friendsSpotlightsRail
                        }
                    }

                    if !friendsListeningAlbums.isEmpty {
                        section(title: "Friends are listening to") {
                            friendsListeningRail
                        }
                    }

                    if !mostNoddedThisWeek.isEmpty {
                        section(title: "Most nodded this week") {
                            mostNoddedList
                        }
                    }

                    if !homeVM.topChartSongs.isEmpty {
                        section(title: "Top Charts") {
                            topChartsRail
                        }
                    }

                    if !homeVM.recommendationShelves.isEmpty {
                        recommendedSection
                    }

                    if !homeVM.madeForYouPlaylists.isEmpty {
                        section(title: "Made For You") {
                            madeForYouRail
                        }
                    }

                    if !recentShelfAlbums.isEmpty {
                        section(title: "Recently Added") {
                            recentlyAddedFromShelfRail
                        }
                    }

                    if playerVM.nowPlaying != nil {
                        Color.clear.frame(height: 70)
                    }
                }
                .padding(.top, 8)
            }
            .gatesMarqueeToScrollSettle()
            .background(Color.nodalong.bgBase)
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
            .navigationDestination(for: AlbumResult.self) { album in
                AlbumDetailSearchView(album: album)
                    .navigationTransition(.zoom(sourceID: album.key, in: zoomNamespace))
            }
            .navigationDestination(for: ArtistResult.self) { ArtistDetailSearchView(artist: $0) }
            .navigationDestination(for: PlaylistResult.self) { PlaylistDetailSearchView(playlist: $0) }
            // Landed here from `router.dismissThenPush` — NowPlayingView's
            // artist/album tap, or PartyView's — since a push always targets
            // whichever tab happens to be selected, not necessarily this one.
            .navigationDestination(for: PendingArtistResolve.self) { pending in
                ResolvingArtistsView(name: pending.artist) {
                    await resolvePendingArtists(for: pending, playerVM: playerVM, musicService: musicService, activeService: activeService)
                }
            }
            .navigationDestination(for: PendingAlbumResolve.self) { pending in
                ResolvingAlbumView(name: pending.albumName, artistName: pending.artist, artwork: pending.artwork) {
                    await resolvePendingAlbum(for: pending, playerVM: playerVM, musicService: musicService, activeService: activeService)
                }
            }
            .navigationDestination(for: RecentAlbum.self) { album in
                ResolvingAlbumView(name: album.albumName, artistName: album.artistName, artwork: album.artwork) {
                    // Routed through `MusicDetailCache.resolvedAlbum` (keyed
                    // by `album.id`, the stable grouping key) rather than
                    // calling `resolveAlbum` directly — lets `recentAlbumTile`'s
                    // own per-tile `.task(id:)` prefetch (`prefetchAlbumResolve`)
                    // warm this exact result before the tap, so a tile that's
                    // been on screen for a moment opens with tracks already
                    // loaded instead of resolving cold.
                    //
                    // `album.uri` — the representative track's REAL Apple
                    // Music id — not `album.catalogId`, which is Nodalong's
                    // own internal Firestore id and always fails a direct
                    // catalog lookup. See `RecentAlbum.uri`'s doc comment:
                    // without this, resolve fell through to a fuzzy text
                    // search treating the album's own name as a song title,
                    // which is why some albums (e.g. EPs) silently failed to
                    // resolve any tracks at all.
                    await MusicDetailCache.shared.resolvedAlbum(forKey: album.id) {
                        await musicService.resolveAlbum(
                            catalogTrackId: album.uri, isrc: album.isrc,
                            title: album.albumName, artist: album.artistName,
                            trackTitle: album.trackTitle
                        )
                    }
                }
            }
            // Both destinations a follow-list flow needs, registered together on
            // every stack that can host it.
            //
            // `FollowListTarget` is pushed with a plain `NavigationLink(value:)`,
            // NOT `.navigationDestination(item:)`. An item-based push re-presents
            // itself whenever something is pushed ON TOP of it (the bound item is
            // still non-nil), which is exactly the bug Round 9.9 hit with
            // `discographyGridTab` — and it's what made tapping a NAME inside a
            // follow list show a second copy of the follow list instead of that
            // person's profile.
            //
            // `UserProfile` has to be here too: `FollowListView`'s rows push one, so
            // without it a row tap has no destination on this stack. Every closure
            // below builds purely from the pushed value, so the duplicate
            // registrations across stacks are behaviourally identical — which is the
            // property that actually makes this safe, not uniqueness.
            .navigationDestination(for: FollowListTarget.self) { t in
                FollowListView(uid: t.uid, mode: t.mode, username: t.username)
            }
            .navigationDestination(for: UserProfile.self) { UserProfileView(user: $0) }
            .navigationDestination(for: SeeAllRecommendations.self) { _ in RecommendedForYouView(namespace: zoomNamespace) }
            .navigationDestination(for: AlbumGroup.self) { ShelfAlbumQuickView(group: $0) }
            .navigationDestination(for: FriendsListeningAlbum.self) { album in
                ResolvingAlbumView(name: album.albumName, artistName: album.artistName, artwork: album.artwork) {
                    // Same fix as Jump Back In's RecentAlbum destination
                    // above — routed through `MusicDetailCache.resolvedAlbum`
                    // so the background prefetch below can warm it, and
                    // `album.uri` (not `album.catalogId`).
                    await MusicDetailCache.shared.resolvedAlbum(forKey: album.id) {
                        await musicService.resolveAlbum(
                            catalogTrackId: album.uri, isrc: album.isrc,
                            title: album.albumName, artist: album.artistName,
                            trackTitle: album.trackTitle
                        )
                    }
                }
            }
            .profileEntryPoint()
            .refreshable { await load() }
            .task {
                guard !hasLoaded else { return }
                hasLoaded = true
                await load()
            }
            .onChange(of: musicService.canPlayFullTracks) { _, _ in
                Task { await homeVM.refreshPersonalizedContentIfNeeded(musicService: musicService) }
            }
            // Same browse-time prefetch as SearchView — warms
            // `MusicDetailCache` for Recommended for You's albums while
            // they're still just scrolling past, not yet tapped. Bounded to
            // the first 2 shelves × 6 albums (roughly what fits above the
            // fold) rather than every shelf, since Home can have several.
            .task(id: homeVM.recommendationShelves.map(\.id)) {
                guard playerVM.activeService == .appleMusic else { return }
                for album in homeVM.recommendationShelves.prefix(2).flatMap({ $0.albums.prefix(6) }) {
                    let (albumId, albumName, artwork) = (album.id, album.name, album.artwork)
                    // `.utility` + a short delay: this is convenience
                    // prefetch for content the user hasn't tapped yet, not
                    // load-bearing for anything on screen — it used to fire
                    // at default priority immediately alongside Home/Feed/
                    // Library's own launch loads and runSync's ingest,
                    // competing for the same connection during the exact
                    // window the first screen is trying to paint.
                    Task(priority: .utility) {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        guard !Task.isCancelled else { return }
                        _ = await MusicDetailCache.shared.tracks(albumId: albumId) {
                            (try? await musicService.getAlbumTracks(albumId: albumId, albumName: albumName, artwork: artwork)) ?? []
                        }
                    }
                }
            }
            // Jump Back In / Friends Listening prefetch is per-tile now
            // (`recentAlbumTile`/`friendsListeningTile`'s own `.task(id:)`,
            // via `prefetchAlbumResolve`) rather than a rail-level prefix —
            // a fixed prefix left every tile beyond it just as cold as
            // before any of this prefetch existed, which is exactly what
            // was reported back after the first version of this shipped.
            // Mirrors ProfileView's identical trigger — without this, Home's
            // Jump Back In only refreshed on first-open-this-session or an
            // explicit pull-to-refresh, so it could silently lag behind
            // Profile's Recent Tracks (which already re-fetches on every
            // completed sync) by however long since Home was last visited.
            .onChange(of: syncService.lastSyncedAt) { _, _ in
                guard let uid = authVM.currentUser?.uid else { return }
                Task { await homeVM.refreshOwnRecents(uid: uid) }
            }
        }
    }

    private func load() async {
        guard let uid = authVM.currentUser?.uid else { return }
        diagLog("HomeView.load: start")
        let t0 = Date()
        // `libraryVM` backs "Recently Added" (Shelf, not Apple Music);
        // `feedVM` backs "Friends are listening to" / "Most nodded this
        // week". Independent of `homeVM.load` — run concurrently. Both view
        // models already guard against a redundant fetch if Search/Feed
        // loaded them earlier this session, so calling them here too is
        // cheap and safe.
        async let home: Void = homeVM.load(uid: uid, musicService: musicService)
        async let library: Void = libraryVM.load(uid: uid)
        async let feed: Void = feedVM.load(myUid: uid)
        _ = await (home, library, feed)
        diagLog("HomeView.load: homeVM+libraryVM+feedVM ALL done in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
    }

    /// Album-level: people you follow, ranked by how many of them played
    /// something from this album, capped to 10. Pure client-side
    /// aggregation over `feedVM.posts` — no new Firestore query.
    private var friendsListeningAlbums: [FriendsListeningAlbum] {
        Array(NodalongKit.friendsListeningAlbums(from: feedVM.posts).prefix(10))
    }

    /// Track-level: the most-nodded tracks among people you follow in the
    /// last 7 days. Same data source as above, different aggregation.
    private var mostNoddedThisWeek: [Post] {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600).timeIntervalSince1970 * 1000
        return NodalongKit.mostNoddedPosts(from: feedVM.posts, since: cutoff, limit: 10)
    }

    private var greeting: some View {
        Text(greetingText)
            .font(Font.nodalong.title2Bold)
            .foregroundStyle(Color.nodalong.textPrimary)
            .padding(.horizontal, 16)
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let name = authVM.profile?.username ?? "there"
        switch hour {
        case 0..<12:  return "Good morning, \(name)"
        case 12..<17: return "Good afternoon, \(name)"
        default:      return "Good evening, \(name)"
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(Font.nodalong.headline)
                .foregroundStyle(Color.nodalong.textPrimary)
                .padding(.horizontal, 16)
            content()
        }
    }

    /// Apple Music's personalized recommendations, rendered as their real
    /// titled shelves (e.g. "New Music Mix") rather than one flattened rail.
    /// Tapping the header pushes `RecommendedForYouView`, which re-fetches
    /// with a higher group limit so there's genuinely more to see there.
    private var recommendedSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                router.homePath.append(SeeAllRecommendations())
            } label: {
                HStack {
                    Text("Recommended for You")
                        .font(Font.nodalong.headline)
                        .foregroundStyle(Color.nodalong.textPrimary)
                    Spacer()
                    Text("See All")
                        .font(Font.nodalong.subheadline)
                        .foregroundStyle(Color.nodalong.purpleAccent)
                    Image(systemName: "chevron.right")
                        .font(Font.nodalong.captionSemibold)
                        .foregroundStyle(Color.nodalong.purpleAccent)
                }
                .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)

            ForEach(homeVM.recommendationShelves) { shelf in
                VStack(alignment: .leading, spacing: 8) {
                    Text(shelf.title)
                        .font(Font.nodalong.subheadlineSemibold)
                        .foregroundStyle(Color.nodalong.textSecondary)
                        .padding(.horizontal, 16)
                    AlbumsCarousel(albums: shelf.albums, namespace: zoomNamespace)
                }
            }
        }
    }

    /// Friends' recent spotlight picks — reuses `TrackCard`'s existing
    /// attribution fields (`username`/`avatarColor`/`isSpotlit: true`), same
    /// visual language Feed already uses for "whose listen surfaced this."
    private var friendsSpotlightsRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(homeVM.friendsSpotlights) { pick in
                    TrackCard(
                        title:       pick.track.title,
                        artist:      pick.track.artist,
                        album:       pick.track.album,
                        artwork:     pick.track.artwork,
                        username:    pick.user.username,
                        avatarColor: pick.user.avatarColor,
                        isSpotlit:   true,
                        onPlay: {
                            guard activeService.isAuthenticated else { return }
                            Task { await playerVM.play(.from(spotlight: pick.track)) }
                        },
                        onToggleLike: {
                            guard let uid = authVM.currentUser?.uid else { return }
                            let doc = LibraryTrackDoc(
                                catalogId: pick.track.catalogId ?? "",
                                title: pick.track.title, artist: pick.track.artist,
                                album: pick.track.album, artwork: pick.track.artwork,
                                uri: pick.track.uri,
                                sourceService: pick.track.sourceService ?? .appleMusic,
                                savedAt: Date().timeIntervalSince1970 * 1000
                            )
                            Task { await libraryVM.toggleLibrary(uid: uid, track: doc) }
                        },
                        isLiked: libraryVM.isInLibrary(catalogId: pick.track.catalogId, uri: pick.track.uri),
                        onAddToQueue: { playerVM.addToQueue(.from(spotlight: pick.track)) },
                        addToPlaylistSong: .from(spotlight: pick.track),
                        onTapUser: { router.homePath.append(pick.user) }
                    )
                    .frame(width: 220)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Jump Back In (recently played albums)

    /// Recently played, deduped to album level (`homeVM.recentAlbums`) —
    /// resuming the context you were listening in, not just the last song.
    /// Tapping a tile pushes `RecentAlbum` immediately — `.navigationDestination`
    /// (above) shows a `ResolvingAlbumView` with the already-known
    /// name/artist/artwork right away, resolving the real catalog album in
    /// the background instead of blocking the tap on a network call first.
    private var jumpBackInRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(homeVM.recentAlbums) { album in
                    Button {
                        router.homePath.append(album)
                    } label: {
                        recentAlbumTile(album)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .gatesMarqueeToScrollSettle()
        .background(Color.nodalong.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        .padding(.horizontal, 16)
    }

    private func recentAlbumTile(_ album: RecentAlbum) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkThumbnail(url: album.artwork, size: 140, isAlbum: true)
                .clipShape(RoundedRectangle(cornerRadius: Corner.artwork, style: .continuous))
            MarqueeText(text: album.albumName, font: Font.nodalong.captionSemibold, color: Color.nodalong.textPrimary)
            Text(album.artistName)
                .font(Font.nodalong.caption2)
                .foregroundStyle(Color.nodalong.textSecondary)
                .lineLimit(1)
        }
        .frame(width: 140, alignment: .leading)
        // Per-tile prefetch, not a rail-level prefix(6) — this `LazyHStack`
        // only instantiates a tile once it's actually scrolled into view,
        // so `.task(id:)` here fires exactly when that happens, giving
        // every tile in the rail the same head start regardless of how far
        // in it sits (a fixed prefix bound left tiles beyond it just as
        // cold as before this whole prefetch existed). Auto-cancels if the
        // tile scrolls back out before the resolve finishes.
        .task(id: album.id) {
            await prefetchAlbumResolve(id: album.id, uri: album.uri, isrc: album.isrc, albumName: album.albumName, artistName: album.artistName, trackTitle: album.trackTitle)
        }
    }

    // MARK: - Friends are listening to

    /// Albums people you follow have recently played, ranked by how many of
    /// them played it — the "who," not just the "what." Same navigate-
    /// immediately-then-resolve pattern as Jump Back In.
    private var friendsListeningRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(friendsListeningAlbums) { album in
                    Button {
                        router.homePath.append(album)
                    } label: {
                        friendsListeningTile(album)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .gatesMarqueeToScrollSettle()
        .background(Color.nodalong.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        .padding(.horizontal, 16)
    }

    private func friendsListeningTile(_ album: FriendsListeningAlbum) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                ArtworkThumbnail(url: album.artwork, size: 140, isAlbum: true)
                    .clipShape(RoundedRectangle(cornerRadius: Corner.artwork, style: .continuous))
                HStack(spacing: -8) {
                    ForEach(album.listeners.prefix(3)) { listener in
                        AvatarView(emoji: listener.avatarEmoji, colorHex: listener.avatarColor, size: 22)
                            .overlay(Circle().stroke(Color.nodalong.bgCard, lineWidth: 2))
                    }
                }
                .padding(6)
            }
            MarqueeText(text: album.albumName, font: Font.nodalong.captionSemibold, color: Color.nodalong.textPrimary)
            Text(friendsListeningCaption(album.listeners))
                .font(Font.nodalong.caption2)
                .foregroundStyle(Color.nodalong.textSecondary)
                .lineLimit(1)
        }
        .frame(width: 140, alignment: .leading)
        // Same per-tile prefetch as Jump Back In — see that tile's comment.
        .task(id: album.id) {
            await prefetchAlbumResolve(id: album.id, uri: album.uri, isrc: album.isrc, albumName: album.albumName, artistName: album.artistName, trackTitle: album.trackTitle)
        }
    }

    private func friendsListeningCaption(_ listeners: [FriendListener]) -> String {
        guard let first = listeners.first else { return "" }
        return listeners.count == 1 ? first.username : "\(listeners.count) friends this week"
    }

    /// Shared by both `recentAlbumTile` and `friendsListeningTile`'s
    /// per-tile prefetch — warms `MusicDetailCache.resolvedAlbum` (the
    /// `resolveAlbum` OUTCOME, not just the eventual tracks) so a tile's
    /// real tap, once it arrives, hits a cache instead of resolving cold.
    /// `.utility` + a short delay for the same reason as the other
    /// browse-time prefetch on this screen: convenience prefetch for
    /// content that hasn't been tapped yet shouldn't compete with
    /// higher-priority work, particularly for the first visible batch of
    /// tiles rendered right as Home mounts.
    private func prefetchAlbumResolve(id: String, uri: String, isrc: String?, albumName: String, artistName: String, trackTitle: String) async {
        guard playerVM.activeService == .appleMusic else { return }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard !Task.isCancelled else { return }
        _ = await MusicDetailCache.shared.resolvedAlbum(forKey: id) {
            await musicService.resolveAlbum(catalogTrackId: uri, isrc: isrc, title: albumName, artist: artistName, trackTitle: trackTitle)
        }
    }

    // MARK: - Most nodded this week

    /// Track-level ranked list, mirrors the visual language of a search
    /// results list rather than another horizontal tile carousel — Home
    /// leaned heavily on one layout shape before this, so this is
    /// deliberately different. Tapping any row plays the whole list starting
    /// there, same "tap plays in context" convention as Top Charts.
    private var mostNoddedList: some View {
        VStack(spacing: 4) {
            ForEach(Array(mostNoddedThisWeek.enumerated()), id: \.element.id) { index, post in
                Button {
                    guard activeService.isAuthenticated else { return }
                    let songs = mostNoddedThisWeek.map { Song.from(post: $0) }
                    Task { await playerVM.play(songs, startingAt: index) }
                } label: {
                    mostNoddedRow(post, rank: index + 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color.nodalong.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        .padding(.horizontal, 16)
    }

    private func mostNoddedRow(_ post: Post, rank: Int) -> some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(Font.nodalong.subheadlineMedium)
                .foregroundStyle(Color.nodalong.textSecondary)
                .frame(width: 16, alignment: .trailing)
            ArtworkThumbnail(url: post.artwork, size: 40, isTrack: true)
                .clipShape(RoundedRectangle(cornerRadius: Corner.artwork, style: .continuous))
            // `.frame(maxWidth: .infinity)` — without it this VStack just
            // hugs its own natural (never-overflowing) width and the nod
            // count ends up wherever that leaves it, rather than pinned to
            // the trailing edge with MarqueeText given real room to detect
            // overflow against. Replaces the old `Spacer()`, which this now
            // makes redundant (the only other flexible sibling).
            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(text: post.title, font: Font.nodalong.subheadlineMedium, color: Color.nodalong.textPrimary)
                Text(post.artist)
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 3) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 12))
                Text("\(post.nods)")
                    .font(Font.nodalong.captionMedium)
            }
            .foregroundStyle(Color.nodalong.gold)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    // MARK: - Live Now

    /// Followed users currently live — hosting a party or just playing
    /// solo. Hidden entirely (via the `if !homeVM.liveNow.isEmpty` guard in
    /// `body`) when nobody's live, per the agreed design.
    private var liveNowRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(homeVM.liveNow) { entry in
                    Button {
                        Task { await openLiveNowEntry(entry) }
                    } label: {
                        liveNowTile(entry)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func liveNowTile(_ entry: LiveNowEntry) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(emoji: entry.avatarEmoji, colorHex: entry.avatarColor, size: 52)
                statusBadge(for: entry.kind)
            }
            Text(entry.username)
                .font(Font.nodalong.caption2)
                .foregroundStyle(Color.nodalong.textSecondary)
                .lineLimit(1)
                .frame(width: 60)
        }
    }

    @ViewBuilder
    private func statusBadge(for kind: LiveNowEntry.Kind) -> some View {
        switch kind {
        case .listening:
            Circle()
                .fill(.green)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color.nodalong.bgBase, lineWidth: 2))
        case .hostingParty:
            Circle()
                .fill(Color.nodalong.purpleAccent)
                .frame(width: 18, height: 18)
                .overlay(Circle().stroke(Color.nodalong.bgBase, lineWidth: 2))
                .overlay {
                    NodalongMark(size: 11)
                        .foregroundStyle(Color.nodalong.textOnAccent)
                }
        }
    }

    private func openLiveNowEntry(_ entry: LiveNowEntry) async {
        guard !isResolvingLiveNowUser else { return }
        isResolvingLiveNowUser = true
        defer { isResolvingLiveNowUser = false }
        if let profile = try? await getUserProfile(uid: entry.uid) {
            router.homePath.append(profile)
        }
    }

    // MARK: - Top Charts

    /// Global/storefront trending songs — the one section with zero
    /// personalization, distinct from every other "about you" section on
    /// this screen. Tapping a tile plays the whole chart in context, same
    /// pattern as an album's track list.
    private var topChartsRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(Array(homeVM.topChartSongs.enumerated()), id: \.element.id) { index, song in
                    Button {
                        guard activeService.isAuthenticated else { return }
                        Task { await playerVM.play(homeVM.topChartSongs, startingAt: index) }
                    } label: {
                        topChartTile(song, rank: index + 1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .gatesMarqueeToScrollSettle()
        .background(Color.nodalong.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        .padding(.horizontal, 16)
    }

    private func topChartTile(_ song: Song, rank: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                ArtworkThumbnail(url: song.artwork, size: 140)
                    .clipShape(RoundedRectangle(cornerRadius: Corner.artwork, style: .continuous))
                Text("#\(rank)")
                    .font(Font.nodalong.caption2Bold)
                    .foregroundStyle(Color.nodalong.textOnAccent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                    .padding(6)
            }
            MarqueeText(text: song.title, font: Font.nodalong.captionSemibold, color: Color.nodalong.textPrimary)
            Text(song.artist)
                .font(Font.nodalong.caption2)
                .foregroundStyle(Color.nodalong.textSecondary)
                .lineLimit(1)
        }
        .frame(width: 140, alignment: .leading)
    }

    // MARK: - Made For You (curated playlist mixes)

    /// Apple's own curated playlist mixes — a genuinely different content
    /// type from "Recommended for You" (playlists, not albums), even though
    /// both come from the same underlying request.
    /// Tapping a tile pushes `PlaylistDetailSearchView` to browse the
    /// playlist first (the tracks are fetched inside that screen's own
    /// `.task`, mirroring `AlbumDetailSearchView` — not resolved-and-played
    /// immediately here, which surprised users by starting playback with no
    /// chance to see what was actually in the playlist).
    private var madeForYouRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(homeVM.madeForYouPlaylists) { playlist in
                    Button {
                        router.homePath.append(playlist)
                    } label: {
                        madeForYouTile(playlist)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .gatesMarqueeToScrollSettle()
        .background(Color.nodalong.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        .padding(.horizontal, 16)
    }

    private func madeForYouTile(_ playlist: PlaylistResult) -> some View {
        // Root cause, found by comparing against `recentAlbumTile` (never
        // reported clipped): that tile ALWAYS renders its second line
        // unconditionally, so every tile in Jump Back In has identical
        // height. This one used to render the caption only `if
        // !playlist.curatorName.isEmpty` — a playlist with no curator name
        // produced a SHORTER tile than one with a name, in the SAME
        // `LazyHStack`. Since the rail's `bgCard` container sizes against a
        // lazily-instantiated stack, a short (no-caption) tile could
        // establish the container's height before a taller, 2-line tile
        // scrolled in — clipping that tile's second line at the container
        // edge (confirmed on device: blank caption on one tile, the next
        // tile's caption sliced mid-line). Fix is the same one
        // `recentAlbumTile` already relies on: always render the line, so
        // every tile is the same height — a single space (not an empty
        // string) when there's genuinely no curator name, so the line still
        // reserves its full height without showing visible text.
        VStack(alignment: .leading, spacing: 6) {
            ArtworkThumbnail(url: playlist.artwork, size: 140)
                .clipShape(RoundedRectangle(cornerRadius: Corner.artwork, style: .continuous))
            MarqueeText(text: playlist.name, font: Font.nodalong.captionSemibold, color: Color.nodalong.textPrimary)
            Text(playlist.curatorName.isEmpty ? " " : playlist.curatorName)
                .font(Font.nodalong.caption2)
                .foregroundStyle(Color.nodalong.textSecondary)
                .lineLimit(1)
        }
        .frame(width: 140, alignment: .leading)
    }

    // MARK: - Recently Added (Shelf)

    private var recentlyAddedFromShelfRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(recentShelfAlbums) { group in
                    NavigationLink(value: group) {
                        recentlyAddedShelfTile(group)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .gatesMarqueeToScrollSettle()
        .background(Color.nodalong.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        .padding(.horizontal, 16)
    }

    private func recentlyAddedShelfTile(_ group: AlbumGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkThumbnail(url: group.artwork, size: 140, isAlbum: true)
                .clipShape(RoundedRectangle(cornerRadius: Corner.artwork, style: .continuous))
            MarqueeText(text: group.albumName, font: Font.nodalong.captionSemibold, color: Color.nodalong.textPrimary)
            Text(group.artistName)
                .font(Font.nodalong.caption2)
                .foregroundStyle(Color.nodalong.textSecondary)
                .lineLimit(1)
        }
        .frame(width: 140, alignment: .leading)
    }
}

/// Lightweight, Home-owned album detail screen for the "Recently Added"
/// (Shelf) rail — takes the `AlbumGroup` directly by value rather than
/// reusing Shelf's own `AlbumDetailView` (which looks itself up from
/// `ShelfViewModel.albums` by key + pushes onto Shelf's own `NavigationPath`
/// for its artist/album catalog tap-through — both are tightly coupled to
/// Shelf's own screen and would require `ShelfViewModel` to already be
/// loaded, which isn't guaranteed if the user opens Home first). Deliberately
/// simpler: no catalog tap-through on the artist/album name, just the saved
/// track list + play-in-context + remove-from-shelf.
private struct ShelfAlbumQuickView: View {
    let group: AlbumGroup
    @EnvironmentObject private var playerVM:  PlayerViewModel
    @Environment(FirebaseAuthViewModel.self) private var authVM
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @EnvironmentObject private var musicService:   AppleMusicService
    @EnvironmentObject private var spotifyService: SpotifyMusicService
    @Environment(\.dismiss) private var dismiss

    private var activeService: any MusicService {
        activeMusicService(playerVM: playerVM, apple: musicService, spotify: spotifyService)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                VStack(spacing: 0) {
                    ForEach(Array(group.tracks.enumerated()), id: \.element.id) { idx, track in
                        trackRow(track, at: idx)
                        if idx < group.tracks.count - 1 {
                            Divider()
                                .background(Color.nodalong.bgCard.opacity(0.4))
                                .padding(.leading, 60)
                        }
                    }
                }
                .background(Color.nodalong.bgCard)
                .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                .padding(.horizontal, 16)

                if playerVM.nowPlaying != nil {
                    Color.clear.frame(height: 70)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.nodalong.bgBase)
        .navigationTitle(group.albumName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        guard let uid = authVM.currentUser?.uid else { return }
                        Task {
                            await libraryVM.removeAlbum(uid: uid, tracks: group.tracks)
                            dismiss()
                        }
                    } label: {
                        Label("Remove from Shelf", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Color.nodalong.purpleAccent)
                }
            }
        }
    }

    private var header: some View {
        let size = ScreenMetrics.bounds.width - 64
        return VStack(spacing: 12) {
            ArtworkThumbnail(url: group.artwork, size: size, isAlbum: true)
                .clipShape(RoundedRectangle(cornerRadius: Corner.artwork, style: .continuous))
            VStack(spacing: 4) {
                Text(group.albumName)
                    .font(Font.nodalong.title3Bold)
                    .foregroundStyle(Color.nodalong.textPrimary)
                    .multilineTextAlignment(.center)
                Text(group.artistName)
                    .font(Font.nodalong.subheadlineMedium)
                    .foregroundStyle(Color.nodalong.textSecondary)
                Text("\(group.trackCount) track\(group.trackCount == 1 ? "" : "s")")
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textSecondary)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 24)
    }

    private func trackRow(_ track: LibraryTrackDoc, at index: Int) -> some View {
        HStack(spacing: 12) {
            Text(track.trackNumber.map(String.init) ?? "")
                .font(Font.nodalong.caption)
                .foregroundStyle(Color.nodalong.textSecondary)
                .frame(width: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(Font.nodalong.subheadlineMedium)
                    .foregroundStyle(Color.nodalong.textPrimary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if let dur = track.duration, dur > 0 {
                Text(formatTrackDuration(dur))
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textSecondary)
            }
            TrackActionsMenuButton(
                song:         .from(libraryTrack: track),
                onAddToQueue: { playerVM.addToQueue(.from(libraryTrack: track)) },
                onToggleLike: {
                    guard let uid = authVM.currentUser?.uid else { return }
                    Task { await libraryVM.toggleLibrary(uid: uid, track: track) }
                },
                isLiked: true
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(.rect)
        .onTapGesture {
            guard activeService.isAuthenticated else { return }
            Task { await playerVM.play(group.tracks.map { Song.from(libraryTrack: $0) }, startingAt: index) }
        }
    }
}

/// Marker route pushed when tapping "See All" on the Recommended for You
/// section — see `HomeView.recommendedSection`.
struct SeeAllRecommendations: Hashable {}

#if DEBUG
#Preview {
    HomeView().withPreviewEnvironment()
}
#endif
