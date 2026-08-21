import SwiftUI
import NodalongKit

/// Search tab — find people on Nodalong, or music via Apple Music.
///
/// Layout:
/// 1. `searchFilterRow` — a single self-collapsing pill-tab row (see its doc
///    comment): `People | Music` in People mode, expanding in place to
///    `People | All | Artists | Albums | Songs` in Music mode.
/// 2. While `query` is empty, `browseState` shows discovery content instead
///    of a bare prompt — recent searches, genre tiles + popular albums
///    (Music mode), or live-now + people-you-may-know (People mode).
/// 3. Once typing starts, results render per scope:
///     - Artists → horizontal carousel of circle cards
///     - Albums → horizontal carousel of album-art cards
///     - Songs → vertical list of rows
///     - **All** stacks all three sections with mini-carousels above the list
/// 4. People mode results are a vertical list of user rows with inline
///    follow toggles.
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
    /// Backs the tap→open "zoom" transition on album tiles — the tapped
    /// tile's artwork visually expands into the destination's header instead
    /// of a plain slide, so the ~500ms track fetch (already near the network
    /// floor — nothing left to shave there) happens behind motion instead of
    /// a bare wait. Must live here: `.navigationTransition(.zoom(...))` and
    /// `.matchedTransitionSource(...)` only work across a shared namespace
    /// whose ancestor owns the `NavigationStack` both ends sit in.
    @Namespace private var zoomNamespace

    /// Whichever backend is actually connected — search must route here,
    /// not hardcode Apple Music, or a Spotify-only account gets zero
    /// results no matter what they type.
    private var activeService: any MusicService {
        activeMusicService(playerVM: playerVM, apple: musicService, spotify: spotifyService)
    }

    /// `true` when no section has anything to render. Drives the "No results"
    /// empty state.
    private var hasAnyResults: Bool {
        !searchVM.userResults.isEmpty
        || !searchVM.results.artists.isEmpty
        || !searchVM.results.albums.isEmpty
        || !searchVM.results.tracks.isEmpty
    }

    var body: some View {
        NavigationStack(path: $router.searchPath) {
            ZStack {
                Color.nodalong.bgBase
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    searchFilterRow

                    // The big blocking spinner is only for the genuinely
                    // empty case (a fresh search, or one that's cleared
                    // everything). Once there ARE results on screen, a
                    // refinement (typing further, switching scope) keeps
                    // them visible — `resultsScroll` itself dims + overlays
                    // a small spinner while `isSearching` is true. Without
                    // this split, every pause in typing wiped the whole
                    // list to a full-screen spinner and repopulated it a
                    // few hundred ms later — visible flicker on every
                    // keystroke, which is most of what "search doesn't feel
                    // responsive" was actually describing.
                    Group {
                        if searchVM.isSearching && !hasAnyResults {
                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if searchVM.query.count >= 2 && !hasAnyResults {
                            noResultsState
                        } else if searchVM.query.count < 2 {
                            browseState
                        } else {
                            resultsScroll
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
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
            .navigationDestination(for: ArtistResult.self) { artist in
                ArtistDetailSearchView(artist: artist)
                    .navigationTransition(.zoom(sourceID: artist.key, in: zoomNamespace))
            }
            .navigationDestination(for: AlbumResult.self) { album in
                AlbumDetailSearchView(album: album)
                    .navigationTransition(.zoom(sourceID: album.key, in: zoomNamespace))
            }
            .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
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
        }
        .searchable(
            text: $searchVM.query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: searchVM.mode == .people
                ? "Find people"
                : "Artists, albums, songs"
        )
        .onChange(of: searchVM.query) {
            searchVM.search(via: activeService)
        }
        .onChange(of: searchVM.mode) {
            searchVM.search(via: activeService, debounce: false)
        }
        .onChange(of: searchVM.scope) {
            searchVM.search(via: activeService, debounce: false)
        }
        .task {
            diagLog("SearchView: .task fired")
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
        // Prefetch — while the user is browsing results (not yet tapped),
        // warm `MusicDetailCache` for what's currently on screen. Reuses the
        // EXACT closures `ArtistDetailSearchView`/`AlbumDetailSearchView`
        // already call on their own `.task`, so a real tap either lands on a
        // completed cache hit or joins an already-in-flight fetch instead of
        // starting cold — this is the standard "prefetch on browse, not on
        // tap" trick (the same one table/collection view prefetching APIs
        // exist for). Bounded to the first 6 of each — what's actually
        // visible without scrolling, not the full result set.
        .task(id: searchVM.results.artists.map(\.id) + searchVM.results.albums.map(\.id)) {
            guard playerVM.activeService == .appleMusic else { return }
            for artist in searchVM.results.artists.prefix(6) {
                let artistId = artist.id
                Task {
                    _ = await MusicDetailCache.shared.core(artistId: artistId) {
                        guard let c = try? await musicService.getArtistCore(artistId: artistId) else { return nil }
                        return ArtistCoreDetails(albums: c.albums, topTracks: c.topTracks)
                    }
                }
            }
            for album in searchVM.results.albums.prefix(6) {
                let (albumId, albumName, artwork) = (album.id, album.name, album.artwork)
                Task {
                    _ = await MusicDetailCache.shared.tracks(albumId: albumId) {
                        (try? await musicService.getAlbumTracks(albumId: albumId, albumName: albumName, artwork: artwork)) ?? []
                    }
                }
            }
        }

        // Same browse-time prefetch, for PEOPLE. Warms the exact
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

    // MARK: - Empty / prompt states

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsState: some View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Browse state (shown while query is empty)

    @ViewBuilder
    private var browseState: some View {
        ScrollView {
            VStack(spacing: 24) {
                switch searchVM.mode {
                case .people: peopleBrowseState
                case .music:  musicBrowseState
                }
                if playerVM.nowPlaying != nil {
                    Color.clear.frame(height: 70)
                }
            }
            .padding(.vertical, 12)
        }
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
                    AlbumsCarousel(albums: searchVM.popularAlbums, namespace: zoomNamespace)
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

    /// Static shortcuts into the existing search pipeline — tapping a tile
    /// sets `query`/`mode`/`scope` and runs a normal search, exactly as if
    /// the user had typed the genre name. Deliberately not backed by a
    /// dedicated genre-chart MusicKit request; this is a convenience
    /// front-end onto search, not a second search mechanism.
    private static let genreTiles: [(name: String, color: Color)] = [
        ("Pop",     Color.nodalong.purpleAccent),
        ("Hip-hop", Color.nodalong.bgElevated),
        ("Chill",   Color.nodalong.gold),
        ("Workout", Color.nodalong.error),
        ("R&B",     Color.nodalong.bgElevated),
        ("Rock",    Color.nodalong.purpleAccent),
    ]

    private var genreBrowseGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(Self.genreTiles, id: \.name) { tile in
                Button {
                    searchVM.mode = .music
                    searchVM.scope = .all
                    searchVM.query = tile.name
                    searchVM.search(via: activeService, debounce: false)
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
        if let profile = try? await getUserProfile(uid: entry.uid) {
            router.searchPath.append(profile)
        }
    }

    // MARK: People you may know

    private var suggestedUsersList: some View {
        VStack(spacing: 0) {
            ForEach(searchVM.suggestedUsers) { user in
                Button {
                    router.searchPath.append(user)
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

    @ViewBuilder
    private var resultsScroll: some View {
        ScrollView {
            VStack(spacing: 16) {
                switch searchVM.mode {
                case .people: peopleResults
                case .music:  musicResults
                }

                // Music access notice — only shown if relevant.
                if searchVM.mode == .music && !activeService.isAuthenticated {
                    musicAccessNotice
                }

                // Breathing room between the last result and the mini player.
                // Matches the FeedView pattern — only injected when playing.
                if playerVM.nowPlaying != nil {
                    Color.clear.frame(height: 70)
                }
            }
            .padding(.vertical, 12)
        }
        .background(Color.nodalong.bgBase)
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
        VStack(spacing: 24) {
            if !searchVM.results.artists.isEmpty {
                SearchSection(title: "Artists") {
                    ArtistsCarousel(artists: searchVM.results.artists, namespace: zoomNamespace, onSelect: { artist in
                        recordRecent(kind: .artist, displayName: artist.name, queryText: artist.name)
                    })
                }
            }
            if !searchVM.results.albums.isEmpty {
                SearchSection(title: "Albums") {
                    AlbumsCarousel(albums: searchVM.results.albums, namespace: zoomNamespace, onSelect: { album in
                        recordRecent(kind: .album, displayName: album.name, queryText: "\(album.name) \(album.artistName)")
                    })
                }
            }
            if !searchVM.results.tracks.isEmpty {
                SearchSection(title: "Songs") {
                    SongsList(
                        tracks: searchVM.results.tracks,
                        isInLibrary: { libraryVM.isInLibrary(catalogId: $0.catalogId, uri: $0.uri) },
                        onPlay: { track in
                            guard activeService.isAuthenticated else { return }
                            recordRecent(kind: .track, displayName: track.title, queryText: "\(track.title) \(track.artist)")
                            Task { await playerVM.play(.from(searchItem: track)) }
                        },
                        onLike: { track in
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
                        },
                        onAddToQueue: { track in
                            guard activeService.isAuthenticated else { return }
                            playerVM.addToQueue(.from(searchItem: track))
                        }
                    )
                }
            }
        }
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
    var namespace: Namespace.ID? = nil
    var onSelect: ((ArtistResult) -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(artists) { artist in
                    Group {
                        if let namespace {
                            NavigationLink(value: artist) {
                                ArtistCard(artist: artist)
                            }
                            .matchedTransitionSource(id: artist.key, in: namespace)
                        } else {
                            NavigationLink(value: artist) {
                                ArtistCard(artist: artist)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded { onSelect?(artist) })
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
    /// The tap→open zoom transition's shared namespace — must come from
    /// whichever screen owns the `NavigationStack` this carousel is pushed
    /// within (see `SearchView.zoomNamespace`'s doc comment). Optional so
    /// call sites that haven't opted in yet (none currently) still compile;
    /// every carousel that pushes into an `AlbumResult` destination should
    /// pass one.
    var namespace: Namespace.ID? = nil
    var onSelect: ((AlbumResult) -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(albums) { album in
                    Group {
                        if let namespace {
                            NavigationLink(value: album) {
                                AlbumCard(album: album)
                            }
                            .matchedTransitionSource(id: album.key, in: namespace)
                        } else {
                            NavigationLink(value: album) {
                                AlbumCard(album: album)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded { onSelect?(album) })
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
                .clipShape(RoundedRectangle(cornerRadius: Corner.artwork, style: .continuous))
            MarqueeText(text: album.name, font: Font.nodalong.captionSemibold, color: Color.nodalong.textPrimary)
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
                onAddToQueue: onAddToQueue,
                onToggleLike: onLike,
                isLiked:      isLiked
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
