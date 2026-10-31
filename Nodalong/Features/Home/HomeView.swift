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
    @EnvironmentObject private var playlistsVM: PlaylistsViewModel
    @EnvironmentObject private var generator:   PlaylistGenerator
    @EnvironmentObject private var locationService: LocationService
    /// The user's own pin/hide choices. Device-local (`UserDefaults`) — see
    /// the type's own doc comment for why this isn't Firestore.
    @EnvironmentObject private var homeLayout: HomeLayoutPreferences

    @State private var hasLoaded = false
    /// Driven by a re-tap of the Home tab while already at the root.
    @State private var scrollPosition = ScrollPosition(edge: .top)
    /// When Home last finished a full load. Used to refresh on foreground-
    /// return after a long absence — `hasLoaded` alone meant Home loaded
    /// ONCE per process, and iOS keeps a suspended app alive for days, so
    /// rails like New Releases could sit stale for weeks.
    @State private var lastLoadedAt: Date?
    @Environment(\.scenePhase) private var scenePhase
    private static let staleAfter: TimeInterval = 6 * 3600
    /// Whether the tab-root header is currently scrolled away.
    /// Which section's long-press menu is open, if any.
    @State private var sectionMenuTarget: HomeSectionID?
    @State private var showLayoutSheet = false

    /// Guards a Live Now avatar tap while that user's profile is resolving.
    @State private var isResolvingLiveNowUser = false
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
        (homeVM.isLoading || homeVM.isBatchOpen || libraryVM.isLoading) && !homeVM.restoredFromSnapshot
            // `cityChartSongs` replaces the retired Top Charts here for the
            // same reason it was used: it's fetched unconditionally, so it
            // isn't gated behind an Apple Music subscription like the
            // recommendation shelves are.
            && homeVM.recentAlbums.isEmpty && homeVM.cityChartSongs.isEmpty
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
            VStack(spacing: 0) {
            ScrollView {
                // Lazy: Home is one long scroll with no section cap, so
                // sections below the fold must not build their bodies (and
                // fire their per-tile prefetch tasks) at open. The cap used
                // to be what kept that cost down; this is what replaces it.
                LazyVStack(alignment: .leading, spacing: 24) {
                    greeting

                    if showFirstLaunchSkeletons {
                        section(title: "Jump Back In") { SkeletonRail() }
                        section(title: "Top Charts") { SkeletonRail() }
                        section(title: "Recently Added") { SkeletonRail() }
                    }

                    // Eleven hardcoded `if !x.isEmpty` blocks used to live
                    // here in fixed source order. They're now values
                    // (`HomeSectionID`) so ordering, pinning and hiding
                    // are decisions about an array — see
                    // `orderHomeSections`.
                    ForEach(orderedSections, id: \.self) { id in
                        sectionBody(id)
                    }

                    if playerVM.nowPlaying != nil {
                        Color.clear.frame(height: 70)
                    }
                }
            }
            .scrollPosition($scrollPosition)
            .onChange(of: router.scrollToTopRequests[.home]) {
                withAnimation(.easeInOut(duration: 0.3)) { scrollPosition.scrollTo(edge: .top) }
            }
            .gatesMarqueeToScrollSettle()
            }
            // Hoisted off `ScreenHeader` so the pop-gesture install survives
            // the header being collapsed away. `PlaylistDetailView` draws its
            // own header and depends on the tab root's install to get
            // edge-swipe at all — see `SwipeBackGesture.swift`.
            .enablesInteractiveSwipeBack()
            .screenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
            .navigationDestination(for: AlbumResult.self) { AlbumDetailSearchView(album: $0) }
            .navigationDestination(for: ArtistResult.self) { ArtistDetailSearchView(artist: $0) }
            .navigationDestination(for: PlaylistResult.self) { PlaylistDetailSearchView(playlist: $0) }
            // Landed here from `router.dismissThenPush` — NowPlayingView's
            // artist/album tap, or PartyView's — since a push always targets
            // whichever tab happens to be selected, not necessarily this one.
            .navigationDestination(for: PendingArtistResolve.self) { pending in
                ResolvingArtistsView(name: pending.artist, cached: cachedPendingArtists(pending, playerVM: playerVM)) {
                    await resolvePendingArtists(for: pending, playerVM: playerVM, musicService: musicService, activeService: activeService)
                }
            }
            .navigationDestination(for: PendingAlbumResolve.self) { pending in
                ResolvingAlbumView(name: pending.albumName, artistName: pending.artist, artwork: pending.artwork,
                                   cached: cachedPendingAlbum(pending, playerVM: playerVM)) {
                    await resolvePendingAlbum(for: pending, playerVM: playerVM, musicService: musicService, activeService: activeService)
                }
            }
            .navigationDestination(for: RecentAlbum.self) { album in
                ResolvingAlbumView(name: album.albumName, artistName: album.artistName, artwork: album.artwork,
                                   cached: MusicDetailCache.peekResolvedAlbum(key: album.id)) {
                    // Routed through `MusicDetailCache.resolvedAlbum` (keyed
                    // by `album.id`, the stable grouping key) rather than
                    // calling `resolveAlbum` directly — lets `recentAlbumTile`'s
                    // own per-tile `.task(id:)` prefetch (`CatalogPrefetch.albumResolve`)
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
            .navigationDestination(for: SeeAllRecommendations.self) { _ in RecommendedForYouView(prefetched: homeVM.allRecommendationShelves) }
            // Every other capped rail's "see all". `SeeAllRecommendations`
            // is kept separate rather than folded in here: it re-fetches at
            // a different `maxGroups` and already has its own screen.
            .navigationDestination(for: HomeSeeAll.self) { HomeSeeAllView(section: $0.section) }
            .navigationDestination(for: AlbumGroup.self) { ShelfAlbumQuickView(group: $0) }
            .navigationDestination(for: FriendsListeningAlbum.self) { album in
                ResolvingAlbumView(name: album.albumName, artistName: album.artistName, artwork: album.artwork,
                                   cached: MusicDetailCache.peekResolvedAlbum(key: album.id)) {
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
            // `.enablesInteractiveSwipeBack()` only — the profile avatar
            // lives in `greeting` as its own `ProfileAvatarRow()`, inline
            // content rather than a floating overlay. `showsBack: false` — a
            // tab root has nothing to pop to.
            .screenControls(showsBack: false)
            .refreshable { await load() }
            .task {
                if let uid = authVM.currentUser?.uid { homeLayout.load(uid: uid) }
                guard !hasLoaded else { return }
                hasLoaded = true
                await load()
            }
            // 🔴 Lives here, not on `madeByPeopleSection` as it used to.
            // That section can now sit far below the fold in a lazy stack and never
            // render at all, which would mean nothing on Home ever loads
            // `playlistsVM` — the exact bug this trigger was added to fix
            // in the first place, silently reintroduced by making sections
            // conditional.
            .task { await loadAndRefreshGenerated() }
            // The tile set can grow after launch (genres appear once the library
            // finishes enriching, "Around You" once there's a location fix). The
            // pass is idempotent, so re-running it is harmless.
            .onChange(of: libraryVM.discoverableGenreEntries.map(\.name)) { _, _ in
                Task { await loadAndRefreshGenerated() }
            }
            .onChange(of: libraryVM.artistEntries.count) { _, _ in
                Task { await loadAndRefreshGenerated() }
            }
            .onChange(of: locationService.geohash) { _, _ in
                Task { await loadAndRefreshGenerated() }
            }
            .sheet(isPresented: $showLayoutSheet) {
                HomeLayoutSheet()
            }
            // A long-press menu, deliberately NOT `.contextMenu`: this repo
            // already migrated off it once because its UIKit lift effect
            // floods the console with `_UIGravityWellEffectAnchorView` /
            // `_UIReparentingView` warnings as rows recycle.
            .confirmationDialog(
                sectionMenuTarget?.title ?? "",
                isPresented: Binding(
                    get: { sectionMenuTarget != nil },
                    set: { if !$0 { sectionMenuTarget = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let id = sectionMenuTarget {
                    Button(homeLayout.isPinned(id) ? "Unpin" : "Pin to top") {
                        homeLayout.togglePin(id)
                    }
                    if id.hasSeeAll {
                        Button("See all") { router.push(HomeSeeAll(section: id), onto: .home) }
                    }
                    if id.isHideable {
                        Button("Hide this section", role: .destructive) {
                            homeLayout.setHidden(id, true)
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
            // Coming back to the app after hours: refresh. The commit window
            // keeps this to a single quiet update rather than a reshuffle.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, hasLoaded,
                      let last = lastLoadedAt,
                      Date().timeIntervalSince(last) > Self.staleAfter else { return }
                Task { await load() }
            }
            .onChange(of: musicService.canPlayFullTracks) { _, _ in
                Task { await homeVM.refreshPersonalizedContentIfNeeded(musicService: musicService) }
            }
            // Recommended for You's prefetch now lives per-tile inside
            // `AlbumsCarousel` (the shared component this section renders
            // through), so it follows what's actually scrolled into view
            // instead of warming a fixed first-2-shelves × 6 — and the
            // "See All" screen, which uses the same carousel and previously
            // had no prefetch at all, is covered for free.
            // Jump Back In / Friends Listening prefetch is per-tile now
            // (`recentAlbumTile`/`friendsListeningTile`'s own `.task(id:)`,
            // via `CatalogPrefetch.albumResolve`) rather than a rail-level prefix —
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
        // One commit window across EVERYTHING Home loads — see
        // `HomeViewModel.beginBatch`. The saved snapshot stays on screen and
        // the page updates once, together, instead of rearranging itself as
        // each source lands.
        homeVM.beginBatch(uid: uid)
        async let home: Void = homeVM.load(uid: uid, musicService: musicService)
        async let library: Void = libraryVM.load(uid: uid)
        async let feed: Void = feedVM.load(myUid: uid)
        _ = await (home, library, feed)
        diagLog("HomeView.load: homeVM+libraryVM+feedVM ALL done in \(Int(Date().timeIntervalSince(t0) * 1000))ms")

        // Sequenced after, not concurrent with, the three above: it reads
        // the Shelf's artist list, which only exists once `libraryVM` has
        // landed. Cheap on every launch after the first — the name→id
        // resolves it depends on are disk-persisted in `MusicDetailCache`,
        // and the section itself is restored instantly from the snapshot.
        async let releases: Void = homeVM.loadNewReleases(
            shelfArtists: topShelfArtistNames,
            savedAlbumKeys: Set(libraryVM.albumGroups.map(\.key)),
            musicService: musicService
        )
        async let genreChart: Void = homeVM.loadGenreChart(
            genreName: topShelfGenreName, musicService: musicService
        )
        _ = await (releases, genreChart)
        homeVM.commitBatch()
        lastLoadedAt = Date()
    }

    /// The genre the user actually listens to most, for Apple's per-genre
    /// chart. `genreEntries` is already computed once per library change by
    /// `LibraryViewModel` — never in a view body.
    private var topShelfGenreName: String {
        libraryVM.discoverableGenreEntries.max { $0.trackCount < $1.trackCount }?.name ?? ""
    }

    /// The Shelf's most-listened artists, which is what "New Releases" asks
    /// Apple about.
    ///
    /// 30, not the 12 this shipped with. Measured on a real Shelf: 12 artists
    /// yielded 4 in-window releases, of which 3 were already saved — one
    /// tile. Most artists in a real library are catalogue acts who haven't
    /// released anything recently, so the pool has to be wide enough for the
    /// few who have. Each name is one `MusicDetailCache` lookup, disk-cached
    /// after the first run, and they all fold into a single batched request.
    private var topShelfArtistNames: [String] {
        let top = libraryVM.artistEntries
            .sorted { $0.trackCount > $1.trackCount }
            .prefix(30)
            .map(\.name)
        // Plus the artists you've been saving and playing LATELY. The top-30
        // by track count is nearly static, so asking only about them meant
        // the same artists every time; recency is what changes as you
        // listen, and it's where a brand-new release is most likely to land.
        let recentSaves = libraryVM.albumGroupsByRecency.prefix(30).map(\.artistName)
        let recentPlays = homeVM.recentAlbums.prefix(20).map(\.artistName)
        var seen = Set<String>()
        return (top + recentSaves + recentPlays)
            .map { primaryArtist($0) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(60)
            .map { $0 }
    }

    /// Both rails are aggregations over the whole feed, so they are derived
    /// once per change in `FeedViewModel` rather than recomputed here — these
    /// are read twice per render each (availability check, then section body)
    /// and this view observes nine app-wide objects.
    private var friendsListeningAlbums: [FriendsListeningAlbum] {
        Array(feedVM.friendsListeningAlbums.prefix(10))
    }

    private var mostNoddedThisWeek: [Post] { feedVM.mostNoddedThisWeek }

    /// Last Monday→Sunday, from data already in memory. Cheap (≤ ~300 rows),
    /// but read twice per render, so it is kept to one pass.
    private var weeklyRecap: WeeklyRecap {
        let end = PlaylistGenerator.lastMondayStartMs()
        let start = end - 7 * 86_400_000
        return buildWeeklyRecap(
            myPosts: homeVM.recentPosts, myLibrary: libraryVM.tracks,
            mySpotlights: authVM.profile?.spotlightTracks ?? [], friendPosts: feedVM.posts,
            weekStartMs: start, weekEndMs: end)
    }

    // MARK: - Section ordering

    /// Sections that currently have something to show. Order here doesn't
    /// matter — `orderHomeSections` decides that from `baseRank`.
    ///
    /// The two generated-playlist sections are unconditional: their tiles
    /// render a "generate this" state when no playlist exists yet, so an
    /// empty `playlistsVM` is a valid thing to show rather than nothing.
    private var availableSections: [HomeSectionID] {
        var ids: [HomeSectionID] = [.madeByPeople, .foundForYou]
        if !homeVM.liveNow.isEmpty            { ids.append(.liveNow) }
        // "Your week" is switched off for now (judged not useful / out of place on
        // Home). Everything behind it is intact; restore by re-adding the line:
        // if !weeklyRecap.isEmpty               { ids.append(.weeklyRecap) }
        // Jump Back In now also carries Apple's own recently-played
        // containers, so it must appear when only those have content.
        if !homeVM.recentAlbums.isEmpty || !recentlyPlayedUnseen.isEmpty
            || !homeVM.recentlyPlayedPlaylists.isEmpty { ids.append(.jumpBackIn) }
        if !homeVM.friendsSpotlights.isEmpty  { ids.append(.friendsSpotlights) }
        if !homeVM.newReleases.isEmpty        { ids.append(.newReleases) }
        if !homeVM.newMusicDaily.isEmpty      { ids.append(.newMusicDaily) }
        if !homeVM.cityChartSongs.isEmpty     { ids.append(.cityCharts) }
        if !homeVM.genreChartSongs.isEmpty    { ids.append(.genreCharts) }
        if !friendsListeningAlbums.isEmpty    { ids.append(.friendsListening) }
        // "Most nodded this week" is switched off for now (it didn't behave as
        // expected — one nod, including your own plays, was enough to rank).
        // Everything behind it is intact; restore by re-adding the line:
        // if !mostNoddedThisWeek.isEmpty { ids.append(.mostNodded) }
        // Apple's playlists render inside this section now, so it has to
        // appear when EITHER half has content — otherwise the playlists are
        // lost whenever Apple returns no album shelves.
        if !homeVM.recommendationShelves.isEmpty || !homeVM.madeForYouPlaylists.isEmpty {
            ids.append(.recommended)
        }
        if !recentShelfAlbums.isEmpty         { ids.append(.recentlyAdded) }
        return ids
    }

    /// Which sections hold something genuinely new today. Everything here is
    /// derived from data already in hand — no extra fetch.
    ///
    /// Only content that can actually change day to day qualifies.
    /// Recommended for You and Recently Added are deliberately never fresh:
    /// they look the same on every launch, which is exactly why they
    /// shouldn't outrank a friend's spotlight for the top of the screen.
    ///
    /// 🔴 Every test here must be a REAL test. The chart rails used to
    /// qualify on `!isEmpty`, which is always true, so they were permanently
    /// fresh and sat above Live Now and Jump Back In whenever the user's
    /// follows were quiet — precisely what this comment says must not happen.
    /// They now come from `homeVM.freshCharts`, which compares against what
    /// the previous launch showed.
    private var freshSections: Set<HomeSectionID> {
        var fresh: Set<HomeSectionID> = []
        let now = Date().timeIntervalSince1970 * 1000
        let dayAgo = now - 24 * 3600 * 1000
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)

        // Live Now is a right-now signal by definition — if it has anything
        // in it at all, that thing is happening this second.
        if !homeVM.liveNow.isEmpty { fresh.insert(.liveNow) }
        // The recap is news on Monday and Tuesday, then settles to its base rank.
        let weekday = Calendar.current.component(.weekday, from: Date())
        if weekday == 2 || weekday == 3 { fresh.insert(.weeklyRecap) }

        let today = dateKey(epochMs: now)
        if homeVM.friendsSpotlights.contains(where: { dateKey(epochMs: $0.track.spotlitAt) == today }) {
            fresh.insert(.friendsSpotlights)
        }
        // `releaseDate` is "yyyy-MM-dd", so comparing formatted strings is
        // correct and avoids parsing every row back into a Date.
        let weekAgoKey = Self.releaseDateFormatter.string(from: weekAgo)
        if homeVM.newReleases.contains(where: { $0.releaseDate >= weekAgoKey }) {
            fresh.insert(.newReleases)
        }
        // `.dailyGlobalTop` / city / genre charts genuinely turn over each
        // day, unlike the `.mostPlayed` list this used to show — so they've
        // earned the fresh bucket where the old sticky chart hadn't.
        // Only when the chart actually turned over. A non-empty chart is not
        // news — treating it as such made both chart rails permanently fresh,
        // which floated them above every people-driven section on any quiet
        // day. See `HomeViewModel.freshCharts`.
        fresh.formUnion(homeVM.freshCharts)
        if feedVM.posts.contains(where: { $0.createdAt > dayAgo }) {
            fresh.insert(.friendsListening)
        }
        return fresh
    }

    private static let releaseDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var orderedSections: [HomeSectionID] {
        orderHomeSections(
            available: availableSections,
            fresh: freshSections,
            pinned: homeLayout.pinned,
            hidden: homeLayout.hidden
        )
    }

    @ViewBuilder
    private func sectionBody(_ id: HomeSectionID) -> some View {
        switch id {
        case .liveNow:           section(id) { liveNowRail }
        case .jumpBackIn:        section(id) { jumpBackInRail }
        case .weeklyRecap:       section(id) { WeeklyRecapCard(recap: weeklyRecap) }
        case .friendsSpotlights: section(id) { friendsSpotlightsRail }
        case .madeByPeople:      madeByPeopleSection
        case .foundForYou:       tasteSection
        case .newReleases:       section(id) { releaseRail(homeVM.newReleases) }
        case .newMusicDaily:     section(id) { releaseRail(homeVM.newMusicDaily) }
        case .cityCharts:        section(id, titleOverride: "Top in Your City") { chartRail(homeVM.cityChartSongs) }
        case .genreCharts:       section(id, titleOverride: "Top in \(homeVM.genreChartName)") { chartRail(homeVM.genreChartSongs) }
        case .friendsListening:  section(id) { friendsListeningRail }
        case .mostNodded:        section(id) { mostNoddedList }
        case .recommended:       recommendedSection
        case .recentlyAdded:     section(id) { recentlyAddedFromShelfRail }
        }
    }

    /// The avatar gets its own `ProfileAvatarRow()` above the greeting
    /// rather than sitting inside the greeting row. Inside that row it was
    /// vertically centred against the two-line title, which put it ~30pt
    /// lower than on every other tab. As its own first row it lands at
    /// exactly the same spot as on Feed, Search, Shelf and NearMe — all
    /// five tabs now share one mechanism and one position. Still inline
    /// content, so it scrolls away with everything else and can never
    /// overlap anything.
    private var greeting: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProfileAvatarRow()
            HStack {
                Text(greetingText)
                    .font(Font.nodalong.title2Bold)
                    .foregroundStyle(Color.nodalong.textPrimary)
                Spacer(minLength: 8)
                Button { showLayoutSheet = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.nodalong.textSecondary)
                        .frame(width: 44, height: 44, alignment: .trailing)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Manage Home sections")
            }
            .padding(.horizontal, 16)
        }
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

    /// Plain titled section — used only by the first-launch skeletons, which
    /// aren't real sections and have nothing to pin, hide or see all of.
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

    /// A real section: its header taps through to "see all" (where there is
    /// one), long-presses to the pin/hide menu, and shows a pin glyph when
    /// the user has pinned it so the reason it's at the top is visible
    /// rather than mysterious.
    @ViewBuilder
    private func section<Content: View>(
        _ id: HomeSectionID,
        titleOverride: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                if id.hasSeeAll { router.push(HomeSeeAll(section: id), onto: .home) }
            } label: {
                HStack(spacing: 6) {
                    // `titleOverride` is for the two sections whose heading
                    // names something only the running app knows — the
                    // user's city, the user's own top genre.
                    Text(titleOverride ?? id.title)
                        .font(Font.nodalong.headline)
                        .foregroundStyle(Color.nodalong.textPrimary)
                    if homeLayout.isPinned(id) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.nodalong.textTertiary)
                    }
                    Spacer(minLength: 8)
                    if id.hasSeeAll {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.nodalong.textSecondary)
                    }
                }
                .padding(.horizontal, 16)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onLongPressGesture { sectionMenuTarget = id }

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
                router.push(SeeAllRecommendations(), onto: .home)
            } label: {
                HStack {
                    Text(HomeSectionID.recommended.title)
                        .font(Font.nodalong.headline)
                        .foregroundStyle(Color.nodalong.textPrimary)
                    if homeLayout.isPinned(.recommended) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.nodalong.textTertiary)
                    }
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
            // This section builds its own header (it had a "See All" long
            // before the generic one existed), so it has to opt into the
            // pin/hide menu by hand. Worth doing rather than skipping: five
            // Apple shelves make this the tallest thing on Home and the
            // section a user is most likely to want gone.
            .onLongPressGesture { sectionMenuTarget = .recommended }

            ForEach(homeVM.recommendationShelves) { shelf in
                VStack(alignment: .leading, spacing: 8) {
                    Text(shelf.title)
                        .font(Font.nodalong.subheadlineSemibold)
                        .foregroundStyle(Color.nodalong.textSecondary)
                        .padding(.horizontal, 16)
                    AlbumsCarousel(albums: shelf.albums)
                }
            }

            // 🔴 Apple's playlists, from the SAME payload as the shelves
            // above: `getPersonalRecommendations` and
            // `getMadeForYouPlaylists` both read one
            // `MusicPersonalRecommendationsRequest` response and share the
            // in-flight request via `recommendationsMemo`. They were two
            // top-level sections presenting one Apple response as two — and
            // the second was titled "Made For You", four words from "Made for
            // you, by real people", which is the section that actually
            // matters on this screen.
            //
            // Rendering them as one more sub-shelf also retires a dead end:
            // `.madeForYou` fell through `hasSeeAll`'s `default: true` and so
            // offered a "See All ›", while `HomeSeeAllView` grouped it with
            // the unreachable cases and answered "Nothing more to show here."
            if !homeVM.madeForYouPlaylists.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Playlists for You")
                        .font(Font.nodalong.subheadlineSemibold)
                        .foregroundStyle(Color.nodalong.textSecondary)
                        .padding(.horizontal, 16)
                    madeForYouRail
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
                        onTapUser: { router.push(pick.user, onto: .home) }
                    )
                    .frame(width: 220)
                }
            }
            .padding(.horizontal, 16)
        }
        // Each card's username opens that person's profile — warm them while
        // the rail is visible, same as Live Now (capped at 6 inside).
        .task(id: homeVM.friendsSpotlights.map(\.user.uid)) {
            guard let me = authVM.currentUser?.uid else { return }
            SocialCache.shared.prefetch(uids: homeVM.friendsSpotlights.map(\.user.uid), viewerUid: me)
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
                        router.push(album, onto: .home)
                    } label: {
                        recentAlbumTile(album)
                    }
                    .buttonStyle(.plain)
                }
                // Apple's own recently-played containers, already deduped
                // against the rows above by `recentlyPlayedUnseen` — so what
                // lands here is exactly the listening that never went through
                // Nodalong, which is the only part worth showing twice. This
                // was its own "Recently Played" section carrying about six
                // items, one of three separate rails covering your own
                // history.
                ForEach(recentlyPlayedUnseen) { album in
                    NavigationLink(value: album) {
                        AlbumCard(album: album)
                    }
                    .buttonStyle(.plain)
                    // `AlbumsCarousel` owns the per-tile prefetch, not
                    // `AlbumCard`, so a bare card had none — these tiles
                    // opened cold while the rest of this rail was warm.
                    .task(id: album.id, priority: .utility) { await prefetchAlbum(album) }
                }
                // Playlists can only come from Apple's side: Jump Back In
                // infers albums from track metadata, and a playlist has no
                // album to infer.
                ForEach(homeVM.recentlyPlayedPlaylists) { playlist in
                    NavigationLink(value: playlist) {
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

    private func recentAlbumTile(_ album: RecentAlbum) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkThumbnail(url: album.artwork, size: 140, isAlbum: true)
            HStack(spacing: 4) {
                MarqueeText(text: album.albumName, font: Font.nodalong.captionSemibold, color: Color.nodalong.textPrimary)
                if album.isExplicit { ExplicitBadge() }
            }
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
            guard playerVM.activeService == .appleMusic else { return }
            await CatalogPrefetch.albumResolve(key: album.id, uri: album.uri, isrc: album.isrc,
                                               albumName: album.albumName, artistName: album.artistName,
                                               trackTitle: album.trackTitle, artwork: album.artwork,
                                               service: musicService)
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
                        router.push(album, onto: .home)
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
                HStack(spacing: -8) {
                    ForEach(album.listeners.prefix(3)) { listener in
                        AvatarView(emoji: listener.avatarEmoji, colorHex: listener.avatarColor, size: 22)
                            .overlay(Circle().stroke(Color.nodalong.bgCard, lineWidth: 2))
                    }
                }
                .padding(6)
            }
            HStack(spacing: 4) {
                MarqueeText(text: album.albumName, font: Font.nodalong.captionSemibold, color: Color.nodalong.textPrimary)
                if album.isExplicit { ExplicitBadge() }
            }
            Text(friendsListeningCaption(album.listeners))
                .font(Font.nodalong.caption2)
                .foregroundStyle(Color.nodalong.textSecondary)
                .lineLimit(1)
        }
        .frame(width: 140, alignment: .leading)
        // Same per-tile prefetch as Jump Back In — see that tile's comment.
        .task(id: album.id) {
            guard playerVM.activeService == .appleMusic else { return }
            await CatalogPrefetch.albumResolve(key: album.id, uri: album.uri, isrc: album.isrc,
                                               albumName: album.albumName, artistName: album.artistName,
                                               trackTitle: album.trackTitle, artwork: album.artwork,
                                               service: musicService)
        }
    }

    private func friendsListeningCaption(_ listeners: [FriendListener]) -> String {
        guard let first = listeners.first else { return "" }
        return listeners.count == 1 ? first.username : "\(listeners.count) friends this week"
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
        liveNowScroll
            // Each tile opens that person's profile — warm them while visible.
            .task(id: homeVM.liveNow.map(\.uid)) {
                guard let me = authVM.currentUser?.uid else { return }
                SocialCache.shared.prefetch(uids: homeVM.liveNow.map(\.uid), viewerUid: me)
            }
    }

    private var liveNowScroll: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(homeVM.liveNow) { entry in
                    VStack(spacing: 6) {
                        Button {
                            Task { await openLiveNowEntry(entry) }
                        } label: {
                            liveNowTile(entry)
                        }
                        .buttonStyle(.plain)
                        if case .listening(_, let isPreview) = entry.kind {
                            TuneInButton(uid: entry.uid, username: entry.username,
                                         isPreviewPlayback: isPreview, compact: true)
                        }
                    }
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
        if let profile = await profileForNavigation(uid: entry.uid, viewerUid: authVM.currentUser?.uid) {
            router.push(profile, onto: .home)
        }
    }

    // MARK: - Top Charts


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
                        router.push(playlist, onto: .home)
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
                .clipShape(RoundedRectangle(cornerRadius: Corner.playlistCover, style: .continuous))
            MarqueeText(text: playlist.name, font: Font.nodalong.captionSemibold, color: Color.nodalong.textPrimary)
            Text(playlist.curatorName.isEmpty ? " " : playlist.curatorName)
                .font(Font.nodalong.caption2)
                .foregroundStyle(Color.nodalong.textSecondary)
                .lineLimit(1)
        }
        .frame(width: 140, alignment: .leading)
        // Warm the playlist's tracks while the tile is on screen, so tapping it
        // opens a populated list. Per-tile: only tiles that linger cost anything.
        .task(id: playlist.id, priority: .utility) {
            guard playerVM.activeService == .appleMusic else { return }
            await CatalogPrefetch.playlist(id: playlist.id, service: musicService)
        }
    }

    // MARK: - New Releases (from Shelf artists)

    /// Wraps each tile in `NavigationLink(value: album)` — `AlbumResult` is a
    /// destination this stack registers, so no navigation wiring of its own.
    /// It does NOT render through `AlbumsCarousel` (whose per-tile prefetch
    /// this comment used to claim), so it carries its own — New Releases and
    /// New Music Daily both render here and were opening cold.
    /// Shows each release's date rather than just the artist. `latestRelease`
    /// cannot distinguish a new record from a reissue (see `getNewReleases`),
    /// so surfacing the date is what keeps a survivor of that guard legible
    /// instead of mysterious — a 2016 album dated three days ago at least
    /// explains itself.
    private func releaseRail(_ albums: [AlbumResult]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(albums) { album in
                    NavigationLink(value: album) {
                        VStack(alignment: .leading, spacing: 6) {
                            ArtworkThumbnail(url: album.artwork, size: 140, isAlbum: true)
                            HStack(spacing: 4) {
                                MarqueeText(text: album.name, font: Font.nodalong.captionSemibold, color: Color.nodalong.textPrimary)
                                if album.isExplicit { ExplicitBadge() }
                            }
                            Text(album.artistName)
                                .font(Font.nodalong.caption2)
                                .foregroundStyle(Color.nodalong.textSecondary)
                                .lineLimit(1)
                            Text(relativeReleaseLabel(album.releaseDate))
                                .font(Font.nodalong.caption2)
                                .foregroundStyle(Color.nodalong.textTertiary)
                                .lineLimit(1)
                        }
                        .frame(width: 140, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .task(id: album.id, priority: .utility) { await prefetchAlbum(album) }
                }
            }
            .padding(12)
        }
        .background(Color.nodalong.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        .padding(.horizontal, 16)
        .gatesMarqueeToScrollSettle()
    }

    /// Per-tile catalog prefetch for a known `AlbumResult` — the same call
    /// `AlbumsCarousel` makes for each of its tiles.
    private func prefetchAlbum(_ album: AlbumResult) async {
        guard playerVM.activeService == .appleMusic else { return }
        await CatalogPrefetch.album(id: album.id, name: album.name, artwork: album.artwork,
                                    releaseDate: album.releaseDate, artist: album.artistName,
                                    service: musicService)
    }

    private func relativeReleaseLabel(_ releaseDate: String) -> String {
        guard let date = Self.releaseDateFormatter.date(from: releaseDate) else { return "" }
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        switch days {
        case ..<1:  return "Out today"
        case 1:     return "Yesterday"
        case ..<7:  return "\(days) days ago"
        case ..<14: return "Last week"
        default:    return "\(days / 7) weeks ago"
        }
    }

    // MARK: - Recently Played (Apple's own containers)

    /// Apple's recently-played albums, minus anything Jump Back In is already
    /// showing.
    ///
    /// The two rails answer the same question from different sources and
    /// would otherwise sit next to each other showing the same covers. Jump
    /// Back In is Nodalong's own (Firestore posts grouped into albums, so it
    /// works across devices and feeds the social graph); this is Apple's,
    /// which additionally knows about listening that never went through
    /// Nodalong. Deduping leaves exactly the difference — the off-app
    /// listening — which is the only part worth a second rail. If there is
    /// no difference the section has nothing in it and hides itself.
    private var recentlyPlayedUnseen: [AlbumResult] {
        let known = Set(homeVM.recentAlbums.map { albumMatchKey($0.albumName) })
        return homeVM.recentlyPlayedAlbums.filter { !known.contains(albumMatchKey($0.name)) }
    }


    // MARK: - City / genre charts

    /// Shared by the city and genre charts. No rank badge: a narrower chart
    /// is about what's playing near you or in what you listen to, not about
    /// the ranking itself. (The global Daily Top rail that did carry ranks was
    /// retired — it overlapped the city chart almost entirely.)
    private func chartRail(_ songs: [Song]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                    Button {
                        Task { await playerVM.play(songs, startingAt: index) }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ArtworkThumbnail(url: song.artwork, size: 140, isTrack: true)
                            MarqueeText(text: song.title, font: Font.nodalong.captionSemibold, color: Color.nodalong.textPrimary)
                            Text(song.artist)
                                .font(Font.nodalong.caption2)
                                .foregroundStyle(Color.nodalong.textSecondary)
                                .lineLimit(1)
                        }
                        .frame(width: 140, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .background(Color.nodalong.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        .padding(.horizontal, 16)
        .gatesMarqueeToScrollSettle()
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
            HStack(spacing: 4) {
                MarqueeText(text: group.albumName, font: Font.nodalong.captionSemibold, color: Color.nodalong.textPrimary)
                if group.isExplicit { ExplicitBadge() }
            }
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
    @EnvironmentObject private var router:    AppRouter
    @EnvironmentObject private var playerVM:  PlayerViewModel
    @Environment(FirebaseAuthViewModel.self) private var authVM
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @EnvironmentObject private var musicService:   AppleMusicService
    @EnvironmentObject private var spotifyService: SpotifyMusicService
    @Environment(\.dismiss) private var dismiss
    /// Real catalog artist behind the tappable artist name, once the
    /// speculative resolve lands — pushed directly so the tap skips
    /// `ResolvingArtistsView` entirely. See `CatalogPrefetch.artistByName`.
    @State private var resolvedArtist: ArtistResult?
    /// Other editions of this release. Like Shelf's own album screen, this is
    /// a library grouping (`AlbumGroup`) with no catalog identity, so it
    /// depends on resolving the catalog album first.
    @State private var alternates: [AlbumResult] = []

    private var activeService: any MusicService {
        activeMusicService(playerVM: playerVM, apple: musicService, spotify: spotifyService)
    }

    var body: some View {
        VStack(spacing: 0) {
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

                if !alternates.isEmpty {
                    AlternateVersionsSection(alternates: alternates)
                }

                if playerVM.nowPlaying != nil {
                    Color.clear.frame(height: 70)
                }
            }
        }
        .scrollContentBackground(.hidden)
        }
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
        // No title — `header` below already shows the album name.
        .screenControls {
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
        // The artist name below the artwork is tappable (added with this
        // screen's artist tap-through) — warm the artist it pushes to.
        .task(id: group.key, priority: .utility) {
            guard playerVM.activeService == .appleMusic else { return }
            async let artist = CatalogPrefetch.artistByName(group.artistName, service: musicService)
            async let catalogAlbum = CatalogPrefetch.albumByName(
                name: group.albumName, artist: group.artistName, service: musicService)
            let (a, al) = await (artist, catalogAlbum)
            resolvedArtist = a
            if let al {
                alternates = await CatalogPrefetch.alternates(for: al, service: musicService)
            }
        }
    }

    private var header: some View {
        let size = ScreenMetrics.bounds.width - 64
        return VStack(spacing: 12) {
            // Same album-detail hero role as Shelf's own `AlbumDetailView`
            // and `AlbumDetailSearchView` — so it gets the same idle rock +
            // tap-to-flip disc. See `VinylArtworkView.flipsOnTap`.
            ArtworkThumbnail(url: group.artwork, size: size, isAlbum: true, flipsOnTap: true)
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Text(group.albumName)
                        .font(Font.nodalong.title3Bold)
                        .foregroundStyle(Color.nodalong.textPrimary)
                        .multilineTextAlignment(.center)
                    if group.isExplicit { ExplicitBadge() }
                }
                // Artist tap-through, matching Shelf's own album screen.
                // Pushes the app-wide `PendingArtistResolve` marker (already
                // registered on Home's stack for the player/party artist tap)
                // rather than a Home-local one, so this goes through the
                // precise MusicKit `Song.artists` relationship lookup instead
                // of a fuzzy name search.
                Text(group.artistName)
                    .font(Font.nodalong.subheadlineMedium)
                    .foregroundStyle(Color.nodalong.purpleAccent)
                    .contentShape(.rect)
                    .onTapGesture { pushArtist() }
                Text("\(group.trackCount) track\(group.trackCount == 1 ? "" : "s")")
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textSecondary)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 24)
    }

    /// Resolves the album's credited artist from a representative saved
    /// track. `catalogId:` is deliberately fed `track.uri` — the track's REAL
    /// Apple Music catalog id — not `track.catalogId`, which is Nodalong's
    /// own Firestore id and always misses a direct catalog lookup (the same
    /// distinction Home's `RecentAlbum` destination already documents).
    private func pushArtist() {
        // Straight to the artist when the speculative resolve has landed —
        // no `ResolvingArtistsView` in between.
        // Identity-carrying like every other artist push, so this
        // participates in the router's dedup and its artist→artist
        // replacement rather than being a blind spot.
        let identity = NavIdentity.artist(name: group.artistName)
        if let resolvedArtist {
            router.push(resolvedArtist, identity: identity, onto: .home)
            return
        }
        guard let track = group.tracks.first else { return }
        router.push(
            PendingArtistResolve(
                trackTitle: track.title,
                artist:     group.artistName,
                catalogId:  track.uri,
                isrc:       track.isrc,
                uri:        track.uri
            ),
            identity: identity,
            onto: .home
        )
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
                onAddToQueue: { playerVM.addToQueue(.from(libraryTrack: track)) }
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

/// One destination for every capped rail on Home.
///
/// Before this, only "Recommended for You" had a see-all
/// (`SeeAllRecommendations`); Jump Back In, Top Charts, Friends are
/// listening, Most nodded and Recently Added all truncated at 10 with no way
/// to reach the rest.
struct HomeSeeAll: Hashable {
    let section: HomeSectionID
}

// MARK: - Manage sections

/// Restores hidden sections and unpins pinned ones.
///
/// Hiding a section from its own header is a one-way door without this — the
/// header you'd long-press to get it back is exactly the thing that's gone.
struct HomeLayoutSheet: View {
    @EnvironmentObject private var homeLayout: HomeLayoutPreferences
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(HomeSectionID.allCases.sorted { $0.baseRank < $1.baseRank }, id: \.self) { id in
                        row(id)
                    }
                } footer: {
                    Text("Sections with something new today move to the top on their own. Pinning one keeps it there regardless.")
                        .font(Font.nodalong.caption)
                }

                if !homeLayout.pinned.isEmpty || !homeLayout.hidden.isEmpty {
                    Section {
                        Button("Reset to default", role: .destructive) { homeLayout.resetAll() }
                    }
                }
            }
            .navigationTitle("Home sections")
            .navigationBarTitleDisplayMode(.inline)
            // Let the mesh show through the bar instead of the opaque app-wide nav fill.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ id: HomeSectionID) -> some View {
        HStack {
            Text(id.title)
            Spacer()
            if id.isHideable {
                Button {
                    homeLayout.togglePin(id)
                } label: {
                    Image(systemName: homeLayout.isPinned(id) ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                Toggle("", isOn: Binding(
                    get: { !homeLayout.isHidden(id) },
                    set: { homeLayout.setHidden(id, !$0) }
                ))
                .labelsHidden()
            } else {
                // Jump Back In: the one section that keeps Home usable with
                // an empty follow graph and no subscription.
                Text("Always shown")
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textTertiary)
            }
        }
    }
}

#if DEBUG
#Preview {
    HomeView().withPreviewEnvironment()
}
#endif


// MARK: - Generated playlists ("made for you, by real people")

extension HomeView {

    /// Which lenses to offer. `nearby` is hidden outright without a location fix
    /// rather than shown as a dead tile or a permission nag — the other lenses
    /// still work, and the blend just draws from the remaining pools.
    var availableLenses: [PlaylistLens] {
        PlaylistLens.allCases.filter { lens in
            // `.taste` is catalog-sourced, so it cannot sit under a heading
            // that promises real people. It has its own section.
            guard !lens.isCatalogSourced else { return false }
            return lens != .nearby || (locationService.geohash?.isEmpty == false)
        }
    }

    /// `availableLenses` minus any whose built playlist is (nearly) a copy of an
    /// earlier tile's. With one follow, "From Your Circle" and "They Liked Yours"
    /// were the identical 25 tracks under two names. Display only: the hidden
    /// lens is still rebuilt, so it comes back once it has something of its own.
    var displayedLenses: [PlaylistLens] {
        var seen: [Set<String>] = []
        return availableLenses.filter { lens in
            guard let p = generatedPlaylist(for: lens),
                  let tracks = PlaylistTracksCache.freshTracks(for: p), !tracks.isEmpty else { return true }
            let ids = Set(tracks.map(\.catalogId))
            let isCopy = seen.contains { Double(ids.intersection($0).count) / Double(ids.count) >= 0.8 }
            if !isCopy { seen.append(ids) }
            return !isCopy
        }
    }

    func generatedPlaylist(for lens: PlaylistLens, genre: String? = nil, variant: String? = nil) -> Playlist? {
        playlistsVM.playlists.first {
            $0.source == .generated && $0.lens == lens && $0.genre == genre && $0.variant == variant
        }
    }

    /// Every tile Home is showing, in on-screen order — what the background pass
    /// should make sure has a playlist behind it. One source of truth shared with
    /// the tiles themselves.
    var wantedPlaylists: [PlaylistGenerator.Wanted] {
        var out: [PlaylistGenerator.Wanted] = availableLenses.map { .people($0) }
        out.append(.catalog(.discovery(genre: nil)))
        out.append(contentsOf: discoveryGenres.map { .catalog(.discovery(genre: $0)) })
        out.append(.catalog(.deepCuts))
        out.append(.catalog(.newFromSimilar))
        out.append(contentsOf: becauseArtists.map {
            .catalog(.becauseArtist(key: primaryArtist($0).lowercased(), name: $0))
        })
        return out
    }

    /// The artists offered a "Because you listen to X" tile — your three most
    /// saved, by Shelf tracks.
    var becauseArtists: [String] {
        libraryVM.artistEntries
            // An empty-artist bucket is named "Unknown Artist"; it isn't an artist.
            .filter { !$0.name.isEmpty && $0.name != "Unknown Artist" }
            .sorted { $0.trackCount > $1.trackCount }
            .prefix(3)
            .map(\.name)
    }

    /// The genres worth offering a discovery playlist for — the user's own
    /// top few by track count.
    ///
    /// Capped at 3. Each one is a full taste run (a similarity expansion plus
    /// album fetches across a dozen artists), so this is a real cost per tile
    /// — and past three the rail stops being "your genres" and turns into a
    /// genre directory, which Search already isn't doing well enough to be
    /// worth duplicating here.
    var discoveryGenres: [String] {
        libraryVM.discoverableGenreEntries
            .prefix(3)
            .map(\.name)
    }

    @ViewBuilder
    var madeByPeopleSection: some View {
        section(.madeByPeople) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(displayedLenses, id: \.self) { lens in
                        lensTile(lens)
                    }
                }
                .padding(12)
            }
            .overlay(alignment: .bottom) { generationNotice }
            .background(Color.nodalong.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
            .padding(.horizontal, 16)
            .gatesMarqueeToScrollSettle()
        }
        // The `.task { await loadAndRefreshGenerated() }` that used to live
        // here moved to `HomeView.body`. This section can now sit below the
        // fold in a lazy stack and never render, which would leave `playlistsVM`
        // permanently unloaded on Home — the exact bug that trigger exists
        // to prevent.
    }

    /// Populates the tiles, then rebuilds anything gone stale.
    ///
    /// The load matters on its own: nothing else on Home touches
    /// `playlistsVM`, so without this the tiles would render as
    /// "not generated yet" on a fresh launch even when the playlists exist.
    /// `load` is guarded by `loadedForUid`, so calling it here is cheap.
    func loadAndRefreshGenerated() async {
        guard let me = authVM.profile else { return }
        await playlistsVM.load(uid: me.uid)
        // Generation needs your library; make sure it's in before starting (a
        // guarded no-op if it already is).
        await libraryVM.load(uid: me.uid)
        // Pre-saved albums whose release date has passed fill in by themselves.
        await ReleaseWatch.checkDue(musicService: musicService, libraryVM: libraryVM)
        let rebuilt = await generator.refreshAndBuildIfNeeded(
            existing: playlistsVM.playlists,
            wanted: wantedPlaylists,
            me: me,
            myLibrary: libraryVM.tracks,
            myGeohash: locationService.geohash,
            musicService: musicService
        )
        // Pick up whatever the pass built. No navigation — an automatic
        // build must never yank the user into a playlist they didn't open.
        if rebuilt { await playlistsVM.reload(uid: me.uid) }
        // Fetch the track list of any generated playlist whose cached version is
        // out of date, so opening it later shows tracks immediately. Costs
        // nothing on a launch where nothing was rebuilt.
        await PlaylistTracksCache.warm(playlistsVM.playlists)
    }

    /// Why the last generation produced nothing, or what went wrong.
    ///
    /// Without this the generator's carefully-worded reasons ("Nobody has
    /// nodded your tracks yet") were written and never read — a tap on an empty
    /// lens just spun and silently reverted, with no way to tell whether it
    /// failed or there was genuinely nothing to build.
    @ViewBuilder
    var generationNotice: some View {
        if let notice = generator.emptyReason ?? generator.errorMessage {
            Text(notice)
                .font(Font.nodalong.caption)
                .foregroundStyle(Color.nodalong.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
                .transition(.opacity)
        }
    }

    /// Deliberately its own section rather than a fifth tile in
    /// `madeByPeopleSection`: that rail is titled "Made for you, by real
    /// people", and this one is built from the catalog. One tile, because
    /// there is only ever one of it.
    @ViewBuilder
    var tasteSection: some View {
        section(.foundForYou) {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        tasteTile(.discovery(genre: nil))
                        // One per top genre. The general tile stays: a
                        // cross-genre suggestion is a different thing from
                        // "more of the hip-hop you already play", and losing
                        // it would narrow discovery to what you listen to
                        // most — the opposite of the point.
                        // A genre playlist that came out tiny isn't worth a tile.
                        ForEach(discoveryGenres.filter { g in
                            (generatedPlaylist(for: .taste, genre: g)?.trackCount ?? Int.max) >= PlaylistGenerator.minGenrePlaylistSize
                        }, id: \.self) { tasteTile(.discovery(genre: $0)) }
                        // Different jobs from the discovery tiles above: your own
                        // artists' unheard songs, what's new from artists like
                        // yours, and discovery from one artist at a time.
                        tasteTile(.deepCuts)
                        tasteTile(.newFromSimilar)
                        ForEach(becauseArtists, id: \.self) { name in
                            tasteTile(.becauseArtist(key: primaryArtist(name).lowercased(), name: name))
                        }
                    }
                    .padding(12)
                }
                if let reason = generator.emptyReason, generator.tasteBusyKey == nil {
                    Text(reason)
                        .font(Font.nodalong.caption)
                        .foregroundStyle(Color.nodalong.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.nodalong.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
            .padding(.horizontal, 16)
            .gatesMarqueeToScrollSettle()
        }
    }

    /// A taste tile — the general one when `genre` is nil, otherwise that
    /// genre's. Deliberately its own builder rather than an overload of
    /// `lensTile`: the people-lenses are one-per-lens and keyed on the enum,
    /// while these are many-per-lens and keyed on `(lens, genre)`.
    @ViewBuilder
    func tasteTile(_ mode: PlaylistGenerator.CatalogMode) -> some View {
        let existing = generatedPlaylist(for: mode.lens, genre: mode.genre, variant: mode.variant)
        let busy = generator.isGeneratingCatalog(mode)

        Button {
            if let existing, !busy {
                router.push(existing, onto: .home)
            } else if !busy {
                Task { await runTasteGeneration(mode) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    ArtworkThumbnail(url: existing?.coverArtwork ?? "", size: 140)
                        .clipShape(RoundedRectangle(cornerRadius: Corner.playlistCover, style: .continuous))
                    if busy {
                        RoundedRectangle(cornerRadius: Corner.playlistCover, style: .continuous)
                            .fill(Color.black.opacity(0.45))
                        ProgressView().tint(Color.nodalong.textOnAccent)
                    } else if existing == nil {
                        RoundedRectangle(cornerRadius: Corner.playlistCover, style: .continuous)
                            .fill(Color.nodalong.bgElevated)
                        Image(systemName: "sparkles")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(Color.nodalong.purpleAccent)
                    }
                }
                .frame(width: 140, height: 140)

                Text(tasteTileTitle(mode))
                    .font(Font.nodalong.custom(13, .bold))
                    .foregroundStyle(Color.nodalong.textPrimary)
                    .lineLimit(1)

                Text(tasteTileSubtitle(mode, existing: existing, busy: busy))
                    .font(Font.nodalong.custom(11))
                    .foregroundStyle(Color.nodalong.textTertiary)
                    .lineLimit(2)
                    .frame(height: 28, alignment: .top)
            }
            .frame(width: 140, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    func tasteTileTitle(_ mode: PlaylistGenerator.CatalogMode) -> String {
        switch mode {
        case .discovery(let genre):      return genre.map { "\($0) Discoveries" } ?? PlaylistLens.taste.title
        case .deepCuts:                  return PlaylistLens.deepCuts.title
        case .newFromSimilar:            return PlaylistLens.newFromSimilar.title
        case .becauseArtist(_, let name): return "Because you listen to \(name)"
        }
    }

    func tasteTileSubtitle(_ mode: PlaylistGenerator.CatalogMode, existing: Playlist?, busy: Bool) -> String {
        if busy { return "Building…" }
        guard let existing else {
            switch mode {
            case .discovery(let genre):
                return genre.map { "Deep cuts next to the \($0) you play" } ?? PlaylistLens.taste.tagline
            case .deepCuts:                  return PlaylistLens.deepCuts.tagline
            case .newFromSimilar:            return PlaylistLens.newFromSimilar.tagline
            case .becauseArtist(_, let name): return "More like \(name)"
            }
        }
        if let description = existing.description, !description.isEmpty { return description }
        return "\(existing.trackCount) tracks"
    }

    @ViewBuilder
    func lensTile(_ lens: PlaylistLens) -> some View {
        let existing = generatedPlaylist(for: lens)
        let busy = generator.isGenerating(lens)

        Button {
            if let existing, !busy {
                router.push(existing, onto: .home)
            } else {
                Task { await runGeneration(lens) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    ArtworkThumbnail(url: existing?.coverArtwork ?? "", size: 140)
                        .clipShape(RoundedRectangle(cornerRadius: Corner.playlistCover, style: .continuous))
                    if busy {
                        RoundedRectangle(cornerRadius: Corner.playlistCover, style: .continuous)
                            .fill(Color.black.opacity(0.45))
                        ProgressView().tint(Color.nodalong.textOnAccent)
                    } else if existing == nil {
                        RoundedRectangle(cornerRadius: Corner.playlistCover, style: .continuous)
                            .fill(Color.nodalong.bgElevated)
                        Image(systemName: "sparkles")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(Color.nodalong.purpleAccent)
                    }
                }
                .frame(width: 140, height: 140)

                Text(lens.title)
                    .font(Font.nodalong.custom(13, .bold))
                    .foregroundStyle(Color.nodalong.textPrimary)
                    .lineLimit(1)

                Text(tileSubtitle(lens: lens, existing: existing, busy: busy))
                    .font(Font.nodalong.custom(11))
                    .foregroundStyle(Color.nodalong.textTertiary)
                    .lineLimit(2)
                    .frame(height: 28, alignment: .top)
            }
            .frame(width: 140, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    /// Prefer naming the people over counting the tracks. "25 tracks" is what an
    /// algorithm's shelf says; "From Aidooo, who you follow" is the whole point
    /// of this section. Falls back to the count for playlists generated before
    /// descriptions named anyone.
    func tileSubtitle(lens: PlaylistLens, existing: Playlist?, busy: Bool) -> String {
        if busy { return "Building…" }
        guard let existing else { return lens.tagline }
        if let description = existing.description, !description.isEmpty { return description }
        return "\(existing.trackCount) tracks"
    }

    /// The taste lens's own entry point. Mirrors `runGeneration` — generate,
    /// reload so the tile updates, then open it — but calls `generateTaste`,
    /// which takes a music service instead of a geohash.
    func runTasteGeneration(_ mode: PlaylistGenerator.CatalogMode) async {
        guard let me = authVM.profile else { return }
        let id = await generator.generateCatalog(
            mode: mode,
            me: me,
            myLibrary: libraryVM.tracks,
            musicService: musicService
        )
        await playlistsVM.reload(uid: me.uid)
        if id != nil, let fresh = generatedPlaylist(for: mode.lens, genre: mode.genre, variant: mode.variant) {
            router.push(fresh, onto: .home)
        }
    }

    func runGeneration(_ lens: PlaylistLens) async {
        guard let me = authVM.profile else { return }
        let id = await generator.generate(
            lens: lens,
            me: me,
            myLibrary: libraryVM.tracks,
            myGeohash: locationService.geohash
        )
        // Refresh so the tile picks up the new playlist without a manual pull.
        await playlistsVM.reload(uid: me.uid)
        if id != nil, let fresh = generatedPlaylist(for: lens) {
            router.push(fresh, onto: .home)
        }
    }
}
