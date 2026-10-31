import SwiftUI
import NodalongKit

/// Search tab — find people on Nodalong, or music via Apple Music.
///
/// Layout: one shared `ScrollView` for every state, so `searchControls`
/// (the query field + filter row) is mounted exactly once — never inside
/// the `if/else if` below it — and simply scrolls away as you scroll into
/// whichever content is showing. See `body`'s doc comment for why that
/// matters (keyboard focus safety) and `ScreenControls.swift` for why this
/// app doesn't animate a header hiding on scroll at all.
///
/// 1. `searchFilterRow` — a single self-collapsing pill-tab row (see its doc
///    comment): `People | Music` in People mode, expanding in place to
///    `People | All | Artists | Albums | Songs` in Music mode.
/// 2. While `query` is empty, `browseContent` shows discovery content
///    instead of a bare prompt — recent searches, genre tiles + popular
///    albums (Music mode), or live-now + people-you-may-know (People mode).
/// 3. Once typing starts, results render per scope:
///     - Artists → horizontal carousel of circle cards
///     - Albums → horizontal carousel of album-art cards
///     - Songs → vertical list of rows
///     - **All** stacks all three sections with mini-carousels above the list
/// 4. People mode results are a vertical list of user rows with inline
///    follow toggles.
/// 5. A genre tile tap shows `genreChartContent` instead — a genuinely
///    genre-scoped songs chart, not a free-text search result.
struct SearchView: View {
    @EnvironmentObject private var musicService:   AppleMusicService
    @EnvironmentObject private var spotifyService: SpotifyMusicService
    @EnvironmentObject private var searchVM:       SearchViewModel
    @Environment(FirebaseAuthViewModel.self) private var authVM
    @EnvironmentObject private var playerVM:       PlayerViewModel
    @EnvironmentObject private var libraryVM:      LibraryViewModel
    /// Owns this tab's own `NavigationPath` (`router.searchPath`) — see
    /// `AppRouter`'s doc comment.
    @EnvironmentObject private var router:         AppRouter

    @State private var isResolvingLiveNowUser = false
    /// Set by a re-tap of the Search tab while already at the root.
    @FocusState private var queryFocused: Bool
    @EnvironmentObject private var tasteStore: TasteOverridesStore
    /// Whichever backend is actually connected — search must route here,
    /// not hardcode Apple Music, or a Spotify-only account gets zero
    /// results no matter what they type.
    private var activeService: any MusicService {
        activeMusicService(playerVM: playerVM, apple: musicService, spotify: spotifyService)
    }

    private var topHitIDs: (artist: ArtistResult?, albums: [AlbumResult]) {
        var artist: ArtistResult?
        var albums: [AlbumResult] = []
        for hit in searchVM.rankedHits.prefix(15) {
            switch hit {
            case .artist(let a) where artist == nil: artist = a
            case .album(let a) where albums.count < 2: albums.append(a)
            default: break
            }
        }
        return (artist, albums)
    }

    private var topHitKey: String {
        let t = topHitIDs
        return ([t.artist?.id ?? ""] + t.albums.map(\.id)).joined(separator: "|")
    }

    private func prefetchTopHits() async {
        guard playerVM.activeService == .appleMusic, searchVM.scope == .all else { return }
        let t = topHitIDs
        if let a = t.artist { await CatalogPrefetch.artist(a, service: musicService, settle: 0) }
        for a in t.albums {
            guard !Task.isCancelled else { return }
            await CatalogPrefetch.album(id: a.id, name: a.name, artwork: a.artwork, releaseDate: a.releaseDate,
                                        artist: a.artistName, service: musicService, settle: 0)
        }
    }

    /// The first MusicKit catalog call in a session pays token/connection
    /// setup. Spend it on a throwaway request while the user is still typing.
    private static var didWarmSearch = false
    private func warmSearchConnection() async {
        guard !Self.didWarmSearch, activeService.isAuthenticated else { return }
        Self.didWarmSearch = true
        _ = try? await activeService.searchAll("a", maxPerType: 1)
    }

    /// `true` when no section has anything to render. Drives the "No results"
    /// empty state.
    private var hasAnyResults: Bool {
        !searchVM.userResults.isEmpty
        || !searchVM.results.artists.isEmpty
        || !searchVM.results.albums.isEmpty
        || !searchVM.results.tracks.isEmpty
    }

    /// Discriminates which branch is showing, purely to know when to snap
    /// the shared scroll view back to the top. Each state used to be its
    /// own fresh `ScrollView` (so it naturally started scrolled to top);
    /// folding them into one persistent `ScrollView` — to keep the query
    /// field's identity stable across state changes, see `body`'s doc
    /// comment — means that has to be done explicitly instead.
    private var searchStateKey: String {
        if let genre = searchVM.genreChartName { return "genre:\(genre)" }
        if searchVM.isSearching && !hasAnyResults { return "loading" }
        if searchVM.query.count >= 2 && !hasAnyResults { return "noResults" }
        if searchVM.query.count < 2 { return "browse:\(searchVM.mode.rawValue)" }
        return "results:\(searchVM.mode.rawValue):\(searchVM.scope.rawValue)"
    }

    /// Avatar row + query field + filter row, bundled as ONE always-
    /// mounted, non-conditional view. It must never sit inside the
    /// `if/else if` below — if it did, the `TextField` would be torn down
    /// and recreated the instant typing crosses the 2-character threshold
    /// into results, risking a keyboard/focus glitch on exactly the
    /// transition this screen exists to make feel smooth. Keeping it
    /// outside the switch means its view identity never changes; scrolling
    /// the shared `ScrollView` is what makes it "float away" as you scroll
    /// into content — no animation, no hide-on-scroll logic, the same
    /// zero-cost pattern `ScreenTitle`/`ScreenControls` already use
    /// elsewhere.
    ///
    /// `ProfileAvatarRow()` is INLINE content here, its own row above the
    /// rest — not a `.screenControls(trailing:)` floating overlay, which
    /// was tried first and was a real bug: a fixed-position overlay
    /// doesn't know this content now scrolls, so at some scroll offsets it
    /// sat on top of the query field/filter pills instead of beside them.
    /// Matches Home/Feed/NearMe's own convention exactly for the same
    /// reason — reserving real space is the only version of this that
    /// structurally cannot overlap anything.
    private var searchControls: some View {
        VStack(spacing: 0) {
            ProfileAvatarRow()
            queryField
            searchFilterRow
        }
    }

    var body: some View {
        NavigationStack(path: $router.searchPath) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        searchControls
                            .id("top")

                        // The big blocking spinner is only for the genuinely
                        // empty case (a fresh search, or one that's cleared
                        // everything). Once there ARE results on screen, a
                        // refinement (typing further, switching scope) keeps
                        // them visible — `resultsContent` itself dims +
                        // overlays a small spinner while `isSearching` is
                        // true. Without this split, every pause in typing
                        // wiped the whole list to a full-screen spinner and
                        // repopulated it a few hundred ms later — visible
                        // flicker on every keystroke, which is most of what
                        // "search doesn't feel responsive" was actually
                        // describing.
                        Group {
                            if let genre = searchVM.genreChartName {
                                genreChartContent(genre: genre)
                            } else if searchVM.isSearching && !hasAnyResults {
                                loadingContent
                            } else if searchVM.query.count >= 2 && !hasAnyResults {
                                noResultsContent
                            } else if searchVM.query.count < 2 {
                                browseContent
                            } else {
                                resultsContent
                            }
                        }

                        // Breathing room between the last result and the
                        // mini player — one shared spacer now that every
                        // state lives in the same scroll content, instead
                        // of a copy per branch.
                        if playerVM.nowPlaying != nil {
                            Color.clear.frame(height: 70)
                        }
                    }
                }
                .screenBackground()
                .onChange(of: searchStateKey) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo("top", anchor: .top)
                    }
                }
                // Re-tap of the Search tab while already on its root: back to
                // the top AND into the field, so a second tap means "I want to
                // search" rather than just moving the page.
                .onChange(of: router.scrollToTopRequests[.search]) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo("top", anchor: .top)
                    }
                    queryFocused = true
                }
            }
            .toolbar(.hidden, for: .navigationBar)
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
            .navigationDestination(for: UserProfile.self) {
                UserProfileView(user: $0)
            }
            .navigationDestination(for: ArtistResult.self) { ArtistDetailSearchView(artist: $0) }
            .navigationDestination(for: AlbumResult.self) { AlbumDetailSearchView(album: $0) }
            .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
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
            .profileEntryPoint()
            // `.enablesInteractiveSwipeBack()` only — the avatar lives in
            // `searchControls` as inline content now, not a floating
            // overlay (see that property's doc comment for why the
            // overlay version was a real bug). `showsBack: false` — a tab
            // root has nothing to pop to.
            .screenControls(showsBack: false)
        }
        .onChange(of: searchVM.query) {
            KeyboardLatencyProbe.firstKey()
            searchVM.search(via: activeService)
        }
        .onChange(of: queryFocused) { _, focused in
            if focused { KeyboardLatencyProbe.focused() }
        }
        .onChange(of: searchVM.mode) {
            searchVM.search(via: activeService, debounce: false)
        }
        .onChange(of: searchVM.scope) {
            searchVM.search(via: activeService, debounce: false)
        }
        // Top hit: warm the first ranked artist and first two albums the moment
        // results land, with no settle delay — they're what gets tapped. Keyed
        // on the ids so a newer query cancels a stale warm.
        .task(id: topHitKey) { await prefetchTopHits() }
        // Feed what the user listens to into ranking (breaks ties only).
        .onAppear {
            searchVM.taste = libraryVM.tasteWeights.applying(tasteStore.overrides)
            searchVM.localArtistCandidates = libraryVM.artistEntries.map(\.name)
        }
        .onChange(of: libraryVM.artistEntries.count) {
            searchVM.localArtistCandidates = libraryVM.artistEntries.map(\.name)
        }
        .onChange(of: libraryVM.tasteWeights) { _, new in searchVM.taste = new.applying(tasteStore.overrides) }
        .onChange(of: tasteStore.overrides) { _, new in searchVM.taste = libraryVM.tasteWeights.applying(new) }
        .enablesInteractiveSwipeBack()
        .task {
            diagLog("SearchView: .task fired")
            KeyboardLatencyProbe.searchOpened()
            Task { await warmSearchConnection() }
            guard let uid = authVM.currentUser?.uid else { return }
            searchVM.loadRecentSearches(uid: uid)
            // Independent (follow graph vs. personal library) — no reason to
            // await one fully before starting the other.
            let t0 = Date()
            async let following: Void = searchVM.loadFollowing(myUid: uid)
            async let library:   Void = libraryVM.load(uid: uid)
            _ = await (following, library)
            diagLog("SearchView: .task loadFollowing+libraryVM.load done in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
            // Gated on followingUids being known — suggestedUsers must not
            // recommend someone already followed, so this genuinely can't
            // run any earlier than the line above.
            await searchVM.loadBrowseContent(uid: uid, followingUids: Array(searchVM.followingUids), musicService: musicService)
        }
        // NOTE: the music half of this screen's prefetch has moved INTO
        // `ArtistsCarousel`/`AlbumsCarousel` as a per-tile `.task` — it is
        // visibility-driven there, so it covers results past the sixth
        // (which this bounded version left cold) and skips ones never
        // scrolled to. Only the PEOPLE prefetch stays screen-level, because
        // its cap is doing real work: each bundle is ~5 billed Firestore
        // reads, where a MusicKit catalog request is free.
        //
        // Browse-time prefetch, for PEOPLE. Warms the exact
        // `SocialCache` bundle `UserProfileView` reads, so tapping a result
        // lands on a complete profile — spotlight carousel and recents
        // included — instead of watching five fetches arrive.
        //
        // Bounded to 6 like the music prefetch above, and that bound matters
        // more here: each bundle is ~5 billed Firestore reads, where the
        // music one hits Apple Music's API for free.
        .task(id: searchVM.userResults.map(\.uid) + searchVM.suggestedUsers.map(\.uid)) {
            guard let myUid = authVM.currentUser?.uid else { return }
            SocialCache.shared.prefetch(uids: searchVM.userResults.map(\.uid), viewerUid: myUid)
            SocialCache.shared.prefetch(uids: searchVM.suggestedUsers.map(\.uid), viewerUid: myUid)
        }
    }

    /// Search's query field, in-content rather than `.searchable`.
    ///
    /// `.searchable` renders inside the navigation bar, and the nav bar is
    /// gone app-wide — so unlike Shelf's filter (which was relocated to stop
    /// the bar changing height across a push) this one simply has nowhere
    /// else to live. Same binding and same `.onChange` search triggers.
    ///
    /// Frosted (`.ultraThinMaterial`) rather than a solid `bgCard` fill — it
    /// now sits directly on the animated mesh (see `body`) as part of the
    /// scrollable content, and the frosted look is what actually reads as
    /// "floating over" the mesh rather than an opaque bar sitting in front
    /// of it. Same material `HeaderGlyph` uses for the same reason.
    private var queryField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(Font.nodalong.subheadline)
                .foregroundStyle(Color.nodalong.textSecondary)
            TextField(searchVM.mode == .people ? "Find people" : "Artists, albums, songs",
                      text: $searchVM.query)
                .textFieldStyle(.plain)
                .font(Font.nodalong.subheadline)
                .foregroundStyle(Color.nodalong.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($queryFocused)
            if !searchVM.query.isEmpty {
                Button {
                    searchVM.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Font.nodalong.subheadline)
                        .foregroundStyle(Color.nodalong.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: - Filter row

    /// Single self-collapsing row of pill tabs, replacing the previous
    /// stacked People/Music + All/Artists/Albums/Songs segmented pickers.
    ///
    /// In People mode it's just two tabs: `People | Music`. Tapping `Music`
    /// expands the row in place to `People | All | Artists | Albums | Songs`
    /// — the single "Music" tab is replaced by its four scopes rather than
    /// living alongside them, so the row never shows more than one level of
    /// choice at a time. Tapping `People` from any music scope collapses it
    /// straight back to the two-tab state.
    private var searchFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterPill("People", icon: Icons.personOutline, isSelected: searchVM.mode == .people) {
                    withAnimation(.easeInOut(duration: 0.2)) { searchVM.mode = .people }
                }
                if searchVM.mode == .people {
                    filterPill("Music", icon: Icons.discOutline, isSelected: false) {
                        withAnimation(.easeInOut(duration: 0.2)) { searchVM.mode = .music }
                    }
                } else {
                    ForEach(SearchViewModel.MusicSearchScope.allCases) { scope in
                        filterPill(scope.rawValue, icon: nil, isSelected: searchVM.scope == scope) {
                            withAnimation(.easeInOut(duration: 0.2)) { searchVM.scope = scope }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private func filterPill(_ title: String, icon: String?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                }
                Text(title)
                    .font(Font.nodalong.subheadline(emphasized: isSelected))
            }
            .foregroundStyle(isSelected ? Color.nodalong.textOnAccent : Color.nodalong.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(isSelected ? Color.nodalong.purpleAccent : Color.nodalong.textPrimary.opacity(0.08))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .transition(.opacity)
    }

    // MARK: - Empty / prompt / loading states

    /// Bare fallback for when there's genuinely nothing to show yet — no
    /// recent searches, browse content still loading or empty, and (People
    /// mode) no live/suggested users. Rarely reached once browse content is
    /// populated, since Music mode's genre grid is always present.
    private var promptState: some View {
        VStack(spacing: 12) {
            Image(systemName: Icons.searchOutline)
                .font(Font.nodalong.largeTitle).foregroundStyle(Color.nodalong.textSecondary)
            Text(searchVM.mode == .people ? "Find people on Nodalong" : "Find music in Apple Music")
                .font(Font.nodalong.subheadline).foregroundStyle(Color.nodalong.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    /// Content, not its own scroll region — see `body`'s doc comment on why
    /// every state now shares one `ScrollView`. `maxHeight: .infinity` used
    /// to center this inside a dedicated full-screen sibling; inside shared
    /// scroll content that would just claim unbounded height, so it's fixed
    /// top padding instead.
    private var noResultsContent: some View {
        VStack(spacing: 12) {
            Image(systemName: Icons.searchOutline)
                .font(Font.nodalong.largeTitle).foregroundStyle(Color.nodalong.textSecondary)
            Text("No results for \"\(searchVM.query)\"")
                .font(Font.nodalong.subheadline).foregroundStyle(Color.nodalong.textSecondary)
            // Distinguishes "genuinely nothing matched" from "the search
            // never actually ran" (e.g. the catalog API rejected the
            // request) — otherwise both look identical to the user.
            if let detail = searchVM.lastSearchErrorDetail {
                Text(detail)
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.error)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    /// Shown while `isSearching` and nothing has landed yet. Same reasoning
    /// as `noResultsContent` on why this is top-padded rather than
    /// vertically centered now that it's shared scroll content.
    private var loadingContent: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
    }

    // MARK: - Browse state (shown while query is empty)

    @ViewBuilder
    private var browseContent: some View {
        VStack(spacing: 24) {
            switch searchVM.mode {
            case .people: peopleBrowseState
            case .music:  musicBrowseState
            }
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var musicBrowseState: some View {
        if !activeService.isAuthenticated {
            musicAccessNotice
        } else {
            if !searchVM.recentSearches.isEmpty {
                recentSearchChips(kindFilter: nil)
            }
            SearchSection(title: "Browse by mood and genre") {
                genreBrowseGrid
            }
            if !searchVM.popularAlbums.isEmpty {
                SearchSection(title: "Popular albums") {
                    AlbumsCarousel(albums: searchVM.popularAlbums)
                }
            }
        }
    }

    @ViewBuilder
    private var peopleBrowseState: some View {
        if !searchVM.recentSearches.isEmpty {
            recentSearchChips(kindFilter: .person)
        }
        if !searchVM.liveNow.isEmpty {
            SearchSection(title: "Live now") {
                liveNowRow
            }
        }
        if !searchVM.suggestedUsers.isEmpty {
            SearchSection(title: "People you may know") {
                suggestedUsersList
            }
        }
        if searchVM.recentSearches.isEmpty && searchVM.liveNow.isEmpty && searchVM.suggestedUsers.isEmpty {
            promptState
        }
    }

    // MARK: Recent searches

    private func recentSearchChips(kindFilter: SearchViewModel.RecentSearchEntry.Kind?) -> some View {
        let entries = kindFilter == nil
            ? searchVM.recentSearches
            : searchVM.recentSearches.filter { $0.kind == kindFilter }
        return Group {
            if !entries.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Recent")
                            .font(Font.nodalong.headline)
                            .foregroundStyle(Color.nodalong.textPrimary)
                        Spacer()
                        Button("Clear") {
                            guard let uid = authVM.currentUser?.uid else { return }
                            searchVM.clearRecentSearches(uid: uid)
                        }
                        .font(Font.nodalong.captionSemibold)
                        .foregroundStyle(Color.nodalong.purpleAccent)
                    }
                    .padding(.horizontal, 16)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(entries) { entry in
                                Button {
                                    searchVM.selectRecentSearch(entry, via: activeService)
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: recentSearchIcon(for: entry.kind))
                                            .font(.system(size: 11))
                                            .foregroundStyle(Color.nodalong.textSecondary)
                                        Text(entry.displayName)
                                            .font(Font.nodalong.caption)
                                            .foregroundStyle(Color.nodalong.textPrimary)
                                            .lineLimit(1)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(Color.nodalong.bgCard)
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
    }

    private func recentSearchIcon(for kind: SearchViewModel.RecentSearchEntry.Kind) -> String {
        switch kind {
        case .person: return Icons.personOutline
        case .artist: return "music.mic"
        case .album:  return Icons.discOutline
        case .track:  return Icons.musicalNote
        }
    }

    // MARK: Browse by mood/genre

    /// All six of these are real, resolvable Apple Music top-level genres —
    /// unlike the previous "Chill"/"Workout" pair, which were moods, not
    /// genres, and silently returned nothing from a genre-scoped request.
    /// Tapping a tile calls `SearchViewModel.showGenreChart`, a genuinely
    /// genre-filtered chart request — NOT a free-text search of the genre's
    /// name (that was the bug: searching the literal word "Rock" is a
    /// keyword match with no genre awareness at all, and could surface
    /// anything popular, e.g. a top-charting pop artist).
    private static let genreTiles: [(name: String, color: Color)] = [
        ("Pop",        Color.nodalong.purpleAccent),
        ("Hip-hop",    Color.nodalong.bgElevated),
        ("Electronic", Color.nodalong.gold),
        ("Country",    Color.nodalong.error),
        ("R&B",        Color.nodalong.bgElevated),
        ("Rock",       Color.nodalong.purpleAccent),
    ]

    private var genreBrowseGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(Self.genreTiles, id: \.name) { tile in
                Button {
                    searchVM.showGenreChart(tile.name, musicService: musicService)
                } label: {
                    Text(tile.name)
                        .font(Font.nodalong.subheadlineMedium)
                        .foregroundStyle(tile.color == Color.nodalong.gold ? Color.nodalong.bgDeep : Color.nodalong.textOnAccent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                        .background(tile.color)
                        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: Live now

    private var liveNowRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(searchVM.liveNow) { entry in
                    Button {
                        Task { await openLiveNowEntry(entry) }
                    } label: {
                        VStack(spacing: 4) {
                            ZStack(alignment: .bottomTrailing) {
                                AvatarView(emoji: entry.avatarEmoji, colorHex: entry.avatarColor, size: 52)
                                Circle()
                                    .fill(entry.kind.isHostingParty ? Color.nodalong.purpleAccent : .green)
                                    .frame(width: 14, height: 14)
                                    .overlay(Circle().stroke(Color.nodalong.bgBase, lineWidth: 2))
                            }
                            Text(entry.username)
                                .font(Font.nodalong.caption2)
                                .foregroundStyle(Color.nodalong.textSecondary)
                                .lineLimit(1)
                                .frame(width: 60)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func openLiveNowEntry(_ entry: LiveNowEntry) async {
        guard !isResolvingLiveNowUser else { return }
        isResolvingLiveNowUser = true
        defer { isResolvingLiveNowUser = false }
        if let profile = await profileForNavigation(uid: entry.uid, viewerUid: authVM.currentUser?.uid) {
            router.push(profile, onto: .search)
        }
    }

    // MARK: People you may know

    private var suggestedUsersList: some View {
        VStack(spacing: 0) {
            ForEach(searchVM.suggestedUsers) { user in
                Button {
                    router.push(user, onto: .search)
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(emoji: user.avatarEmoji, colorHex: user.avatarColor, size: 36)
                        Text(user.username)
                            .font(Font.nodalong.subheadlineMedium)
                            .foregroundStyle(Color.nodalong.textPrimary)
                        Spacer()
                        Text("Follow")
                            .font(Font.nodalong.captionSemibold)
                            .foregroundStyle(Color.nodalong.purpleAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .overlay(
                                RoundedRectangle(cornerRadius: Corner.container, style: .continuous)
                                    .stroke(Color.nodalong.purpleAccent, lineWidth: 1)
                            )
                            .onTapGesture {
                                guard let uid = authVM.currentUser?.uid,
                                      let username = authVM.profile?.username else { return }
                                Task { await searchVM.toggleFollow(myUid: uid, myUsername: username, targetUser: user) }
                            }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.nodalong.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        .padding(.horizontal, 16)
    }

    // MARK: - Results

    /// Content, not its own scroll region — `.screenBackground()` is now
    /// applied once, at the shared `ScrollView` in `body`; applying it here
    /// too would run a second independent animated mesh, pure waste.
    @ViewBuilder
    private var resultsContent: some View {
        VStack(spacing: 16) {
            switch searchVM.mode {
            case .people: peopleResults
            case .music:  musicResults
            }

            // Music access notice — only shown if relevant.
            if searchVM.mode == .music && !activeService.isAuthenticated {
                musicAccessNotice
            }
        }
        .padding(.vertical, 12)
        // Dim + a small spinner while a refinement is in flight, instead of
        // the caller replacing this whole view with a blocking spinner —
        // keeps the last-known-good results on screen (they may briefly be
        // for the previous query/scope until the new ones land, which reads
        // far better than a blank flash) while still showing something IS
        // happening.
        .opacity(searchVM.isSearching ? 0.4 : 1)
        .animation(.easeInOut(duration: 0.15), value: searchVM.isSearching)
        .overlay(alignment: .top) {
            if searchVM.isSearching {
                ProgressView()
                    .padding(.top, 16)
            }
        }
    }

    // MARK: People results

    /// Records a recent search entry from a tapped result. `queryText` for a
    /// track/album includes the artist name (raises re-search match quality
    /// for common titles); artist/person entries just use the name itself.
    private func recordRecent(kind: SearchViewModel.RecentSearchEntry.Kind, displayName: String, queryText: String) {
        guard let uid = authVM.currentUser?.uid else { return }
        searchVM.recordRecentSearch(kind: kind, displayName: displayName, queryText: queryText, uid: uid)
    }

    @ViewBuilder
    private var peopleResults: some View {
        if searchVM.userResults.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                ForEach(searchVM.userResults) { user in
                    NavigationLink(value: user) {
                        UserSearchRow(
                            user:        user,
                            isFollowing: searchVM.followingUids.contains(user.uid),
                            isOwnProfile: authVM.currentUser?.uid == user.uid,
                            onFollow: {
                                guard let uid      = authVM.currentUser?.uid,
                                      let username = authVM.profile?.username else { return }
                                Task { await searchVM.toggleFollow(myUid: uid, myUsername: username, targetUser: user) }
                            }
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded {
                        recordRecent(kind: .person, displayName: user.username, queryText: user.username)
                    })
                }
            }
            .background(Color.nodalong.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
            .padding(.horizontal, 16)
        }
    }

    // MARK: Music results

    @ViewBuilder
    private var musicResults: some View {
        if searchVM.scope == .all {
            rankedList
        } else {
            scopedResults
        }
    }

    @ViewBuilder
    private var scopedResults: some View {
        VStack(spacing: 24) {
            if !searchVM.results.artists.isEmpty {
                SearchSection(title: "Artists") {
                    ArtistsCarousel(artists: searchVM.results.artists, onSelect: { artist in
                        recordRecent(kind: .artist, displayName: artist.name, queryText: artist.name)
                    })
                }
            }
            if !searchVM.results.albums.isEmpty {
                SearchSection(title: "Albums") {
                    AlbumsCarousel(albums: searchVM.results.albums, onSelect: { album in
                        recordRecent(kind: .album, displayName: album.name, queryText: "\(album.name) \(album.artistName)")
                    })
                }
            }
            if !searchVM.results.tracks.isEmpty {
                SearchSection(title: "Songs") {
                    songsSection(searchVM.results.tracks)
                }
            }
        }
    }

    /// Shared `SongsList` configuration — used by `musicResults`'s Songs
    /// section and by `genreChartContent`, so there's one copy of the
    /// like/queue/play wiring instead of two. `recordsHistory` is `false`
    /// for a genre chart tap: it isn't something the user typed, so it
    /// shouldn't be recorded as a recent search.
    private func songsSection(_ tracks: [SearchItem], recordsHistory: Bool = true) -> some View {
        SongsList(
            tracks: tracks,
            isInLibrary: { libraryVM.isInLibrary(catalogId: $0.catalogId, uri: $0.uri) },
            onPlay:       { playTrack($0, recordsHistory: recordsHistory) },
            onLike:       { likeTrack($0) },
            onAddToQueue: { queueTrack($0) }
        )
    }

    private func playTrack(_ track: SearchItem, recordsHistory: Bool = true) {
        guard activeService.isAuthenticated else { return }
        if recordsHistory {
            recordRecent(kind: .track, displayName: track.title, queryText: "\(track.title) \(track.artist)")
        }
        Task { await playerVM.play(.from(searchItem: track)) }
    }

    private func likeTrack(_ track: SearchItem) {
        guard let uid = authVM.currentUser?.uid else { return }
        let doc = LibraryTrackDoc(
            catalogId:        track.catalogId ?? "",
            title:            track.title,
            artist:           track.artist,
            album:            track.album,
            artwork:          track.artwork,
            uri:              track.uri,
            sourceService:    track.sourceService,
            isrc:             track.isrc,
            duration:         track.duration,
            trackNumber:      track.trackNumber,
            albumReleaseDate: track.albumReleaseDate,
            savedAt:          Date().timeIntervalSince1970 * 1000
        )
        Task { await libraryVM.toggleLibrary(uid: uid, track: doc) }
    }

    private func queueTrack(_ track: SearchItem) {
        guard activeService.isAuthenticated else { return }
        playerVM.addToQueue(.from(searchItem: track))
    }

    /// One list for All: songs, artists and albums ranked together by word
    /// match (see `rankSearchHits`), so the thing you typed is on top
    /// whichever kind it is.
    private var rankedList: some View {
        VStack(spacing: 0) {
            ForEach(Array(searchVM.rankedHits.prefix(30))) { hit in
                Group {
                    switch hit {
                    case .track(let track):
                        TrackSearchRow(
                            track:        track,
                            isLiked:      libraryVM.isInLibrary(catalogId: track.catalogId, uri: track.uri),
                            onPlay:       { playTrack(track) },
                            onLike:       { likeTrack(track) },
                            onAddToQueue: { queueTrack(track) }
                        )
                    case .artist(let artist):
                        NavigationLink(value: artist) {
                            HitRow(artwork: artist.imageUrl, circular: true, isAlbum: false,
                                   title: artist.name, subtitle: "Artist", explicit: false)
                        }
                        .buttonStyle(.plain)
                        // Per-row warm, same as the old carousel tiles: a row that
                        // lingers on screen gets its page prefetched (0.4s settle),
                        // one flicked past costs nothing.
                        .task(id: artist.id, priority: .utility) {
                            guard playerVM.activeService == .appleMusic else { return }
                            await CatalogPrefetch.artist(artist, service: musicService)
                        }
                        .simultaneousGesture(TapGesture().onEnded {
                            recordRecent(kind: .artist, displayName: artist.name, queryText: artist.name)
                        })
                    case .album(let album):
                        NavigationLink(value: album) {
                            HitRow(artwork: album.artwork, circular: false, isAlbum: true,
                                   title: album.name, subtitle: "Album · \(album.artistName)", explicit: album.isExplicit)
                        }
                        .buttonStyle(.plain)
                        .task(id: album.id, priority: .utility) {
                            guard playerVM.activeService == .appleMusic else { return }
                            await CatalogPrefetch.album(id: album.id, name: album.name, artwork: album.artwork,
                                                        releaseDate: album.releaseDate, artist: album.artistName,
                                                        service: musicService)
                        }
                        .simultaneousGesture(TapGesture().onEnded {
                            recordRecent(kind: .album, displayName: album.name, queryText: "\(album.name) \(album.artistName)")
                        })
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .background(Color.nodalong.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        .padding(.horizontal, 16)
    }

    // MARK: Genre chart (genre-tile tap)

    /// Shown instead of the normal browse/results states while
    /// `searchVM.genreChartName` is set — a genuinely genre-scoped songs
    /// chart, not a free-text search result.
    @ViewBuilder
    private func genreChartContent(genre: String) -> some View {
        VStack(spacing: 16) {
            HStack {
                Text(genre)
                    .font(Font.nodalong.headline)
                    .foregroundStyle(Color.nodalong.textPrimary)
                Spacer()
                Button("Done") { searchVM.exitGenreChart() }
                    .font(Font.nodalong.captionSemibold)
                    .foregroundStyle(Color.nodalong.purpleAccent)
            }
            .padding(.horizontal, 16)

            if searchVM.genreChartTracks.isEmpty {
                Text("No \(genre) chart available right now")
                    .font(Font.nodalong.subheadline)
                    .foregroundStyle(Color.nodalong.textSecondary)
                    .padding(.top, 40)
            } else {
                songsSection(searchVM.genreChartTracks, recordsHistory: false)
            }
        }
        .padding(.vertical, 12)
    }

    // MARK: Music-not-connected notice (footer)

    /// Apple Music has a distinct "denied" state (a system permission prompt
    /// the user can dismiss).
    private var isAppleDenied: Bool {
        playerVM.activeService == .appleMusic && musicService.isDenied
    }

    @ViewBuilder
    private var musicAccessNotice: some View {
        HStack(spacing: 12) {
            Image(systemName: isAppleDenied
                  ? "exclamationmark.triangle.fill"
                  : Icons.musicalNote)
                .foregroundStyle(isAppleDenied
                                 ? Color.nodalong.error
                                 : Color.nodalong.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(isAppleDenied
                     ? "Apple Music access denied"
                     : "Apple Music not connected")
                    .font(Font.nodalong.subheadlineMedium)
                    .foregroundStyle(Color.nodalong.textPrimary)
                Text(isAppleDenied
                     ? "Enable it in Settings to search music."
                     : "Connect to search artists, albums, and songs.")
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textSecondary)
            }
            Spacer()
            Button(isAppleDenied ? "Settings" : "Connect") {
                if isAppleDenied {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } else {
                    Task { try? await musicService.authorize() }
                }
            }
            .font(Font.nodalong.captionSemibold)
            .foregroundStyle(Color.nodalong.purpleAccent)
        }
        .padding(14)
        .background(Color.nodalong.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        .padding(.horizontal, 16)
    }
}

private extension LiveNowEntry.Kind {
    var isHostingParty: Bool {
        if case .hostingParty = self { return true }
        return false
    }
}

// MARK: - Section container

private struct SearchSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Font.nodalong.headline)
                .foregroundStyle(Color.nodalong.textPrimary)
                .padding(.horizontal, 16)
            content()
        }
    }
}

// MARK: - Artists carousel (horizontal circle cards)

private struct ArtistsCarousel: View {
    let artists: [ArtistResult]
    var onSelect: ((ArtistResult) -> Void)? = nil
    @EnvironmentObject private var musicService: AppleMusicService
    @EnvironmentObject private var playerVM:     PlayerViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(artists) { artist in
                    NavigationLink(value: artist) {
                        ArtistCard(artist: artist)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded { onSelect?(artist) })
                    // Per-TILE prefetch, not a screen-level `prefix(6)`.
                    // Inside a `LazyHStack` this only runs for cells the
                    // stack actually builds and is cancelled on scroll-away,
                    // so it covers every artist the user can see — including
                    // the ones past the sixth, which the old bounded version
                    // left cold — while costing nothing for tiles flicked past.
                    .task(id: artist.id, priority: .utility) {
                        guard playerVM.activeService == .appleMusic else { return }
                        await CatalogPrefetch.artist(artist, service: musicService)
                    }
                }
            }
            .padding(12)
        }
        .background(Color.nodalong.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        .padding(.horizontal, 16)
    }
}

private struct ArtistCard: View {
    let artist: ArtistResult

    var body: some View {
        VStack(spacing: 8) {
            ArtworkThumbnail(url: artist.imageUrl, size: 110, circular: true)
            Text(artist.name)
                .font(Font.nodalong.captionMedium)
                .foregroundStyle(Color.nodalong.textPrimary)
                .lineLimit(1)
                .frame(width: 110)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Albums carousel (horizontal art cards)
//
// Not `private` — reused by `HomeView`'s "Recommended for You" rail and
// Search's own "Popular albums" browse rail, so a second near-identical
// album-tile component doesn't need to exist.

struct AlbumsCarousel: View {
    let albums: [AlbumResult]
    var onSelect: ((AlbumResult) -> Void)? = nil
    @EnvironmentObject private var musicService: AppleMusicService
    @EnvironmentObject private var playerVM:     PlayerViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(albums) { album in
                    NavigationLink(value: album) {
                        AlbumCard(album: album)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded { onSelect?(album) })
                    // Per-tile prefetch — see `ArtistsCarousel`'s equivalent.
                    // This one component is used by Search results, Search's
                    // Popular Albums browse rail, Home's Recommended for You,
                    // and the "See All" screen, so warming here covers four
                    // surfaces at once (two of which had no prefetch at all).
                    .task(id: album.id, priority: .utility) {
                        guard playerVM.activeService == .appleMusic else { return }
                        await CatalogPrefetch.album(id: album.id, name: album.name,
                                                    artwork: album.artwork, releaseDate: album.releaseDate,
                                                    artist: album.artistName, service: musicService)
                    }
                }
            }
            .padding(12)
        }
        .gatesMarqueeToScrollSettle()
        .background(Color.nodalong.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        .padding(.horizontal, 16)
    }
}

struct AlbumCard: View {
    let album: AlbumResult

    var body: some View {
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
        }
        .frame(width: 140, alignment: .leading)
    }
}

// MARK: - Songs list (vertical)

private struct SongsList: View {
    let tracks:       [SearchItem]
    let isInLibrary:  (SearchItem) -> Bool
    let onPlay:       (SearchItem) -> Void
    let onLike:       (SearchItem) -> Void
    let onAddToQueue: (SearchItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(tracks) { track in
                TrackSearchRow(
                    track:        track,
                    isLiked:      isInLibrary(track),
                    onPlay:       { onPlay(track) },
                    onLike:       { onLike(track) },
                    onAddToQueue: { onAddToQueue(track) }
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .background(Color.nodalong.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        .padding(.horizontal, 16)
    }
}

// MARK: - Row components

private struct UserSearchRow: View {
    let user:         UserProfile
    var isFollowing:  Bool         = false
    var isOwnProfile: Bool         = false
    var onFollow:     (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(
                emoji:    user.avatarEmoji,
                colorHex: user.avatarColor,
                size:     36
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(user.username)
                    .font(Font.nodalong.subheadlineMedium).foregroundStyle(Color.nodalong.textPrimary)
                if !user.bio.isEmpty {
                    Text(user.bio).font(Font.nodalong.caption)
                        .foregroundStyle(Color.nodalong.textSecondary).lineLimit(1)
                }
            }
            Spacer()
            if !isOwnProfile, let onFollow {
                Button(action: onFollow) {
                    Text(isFollowing ? "Following" : "Follow")
                        .font(Font.nodalong.captionSemibold)
                        .foregroundStyle(isFollowing ? Color.nodalong.textSecondary : Color.nodalong.purpleAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .overlay(
                            RoundedRectangle(cornerRadius: Corner.container, style: .continuous)
                                .stroke(isFollowing ? Color.nodalong.textSecondary : Color.nodalong.purpleAccent, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Artist / album row in the unified list — same shape as a song row, with a
/// circular thumbnail for artists and the vinyl treatment for albums.
private struct HitRow: View {
    let artwork: String
    let circular: Bool
    let isAlbum: Bool
    let title: String
    let subtitle: String
    let explicit: Bool

    var body: some View {
        HStack(spacing: 12) {
            ArtworkThumbnail(url: artwork, circular: circular, isAlbum: isAlbum)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Font.nodalong.subheadlineMedium).foregroundStyle(Color.nodalong.textPrimary).lineLimit(1)
                HStack(spacing: 4) {
                    Text(subtitle).font(Font.nodalong.caption)
                        .foregroundStyle(Color.nodalong.textSecondary).lineLimit(1)
                    if explicit {
                        Text("E")
                            .font(Font.nodalong.custom(9, .bold))
                            .foregroundStyle(Color.nodalong.textSecondary)
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(Color.nodalong.textPrimary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(Font.nodalong.captionBold)
                .foregroundStyle(Color.nodalong.textSecondary)
        }
        .contentShape(.rect)
    }
}

private struct TrackSearchRow: View {
    let track:        SearchItem
    var isLiked:      Bool           = false
    var onPlay:       (() -> Void)?  = nil
    var onLike:       (() -> Void)?  = nil
    var onAddToQueue: (() -> Void)?  = nil

    private var subtitle: String {
        var parts = [track.artist]
        if let ms = track.duration, ms > 0 { parts.append(formatTrackDuration(ms)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkThumbnail(url: track.artwork, isTrack: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(Font.nodalong.subheadlineMedium).foregroundStyle(Color.nodalong.textPrimary).lineLimit(1)
                HStack(spacing: 4) {
                    Text(subtitle).font(Font.nodalong.caption)
                        .foregroundStyle(Color.nodalong.textSecondary).lineLimit(1)
                    if track.isExplicit {
                        Text("E")
                            .font(Font.nodalong.custom(9, .bold))
                            .foregroundStyle(Color.nodalong.textSecondary)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Color.nodalong.textPrimary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                    }
                }
            }
            Spacer()
            TrackActionsMenuButton(
                song:         .from(searchItem: track),
                onAddToQueue: onAddToQueue
            )
        }
        .contentShape(.rect)
        .onTapGesture { onPlay?() }
    }
}

#if DEBUG
#Preview {
    NavigationStack { SearchView() }.withPreviewEnvironment()
}
#endif
