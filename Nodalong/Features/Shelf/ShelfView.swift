import SwiftUI
import NodalongKit

// MARK: - Navigation

private enum ShelfRoute: Hashable {
    case artist(String)
    case album(String)
    case catalogArtist(ArtistResult)
    case genre(String)
}

/// Lightweight markers pushed immediately from a Shelf album's header taps,
/// before the real catalog album/artist has been resolved — avoids blocking
/// navigation on the `searchAll` call the way resolve-before-push used to.
/// `.navigationDestination` (below) shows a `ResolvingAlbumView`/
/// `ResolvingArtistView` with the already-known name/artist/artwork right
/// away, resolving in the background.
private struct PendingCatalogAlbumLookup: Hashable {
    let name: String
    let artistName: String
    let artwork: String
}

private struct PendingCatalogArtistLookup: Hashable {
    let name: String
}

// MARK: - Shelf root

/// Shelf tab — browse the user's saved Nodalong library.
///
/// Two segments: Albums (3-column grid, sortable by artist or release date)
/// and Artists (flat list with photos fetched from Spotify). Searchable. Tap
/// an album → AlbumDetail; tap an artist → ArtistAlbums; tap a track → play
/// via `PlayerViewModel`.
struct ShelfView: View {
    @Environment(FirebaseAuthViewModel.self) private var authVM
    @EnvironmentObject private var syncService: LibrarySyncService
    @EnvironmentObject private var shelfVM:     ShelfViewModel
    @EnvironmentObject private var libraryVM:   LibraryViewModel
    @EnvironmentObject private var playlistsVM: PlaylistsViewModel
    @EnvironmentObject private var musicService:   AppleMusicService
    @EnvironmentObject private var spotifyService: SpotifyMusicService
    @EnvironmentObject private var playerVM:       PlayerViewModel
    /// Owns this tab's own `NavigationPath` (`router.shelfPath`) — see
    /// `AppRouter`'s doc comment.
    @EnvironmentObject private var router:         AppRouter

    /// Whichever backend is actually connected — catalog lookups from Shelf
    /// (album/artist name taps) must route here, not hardcode Apple Music.
    private var activeService: any MusicService {
        activeMusicService(playerVM: playerVM, apple: musicService, spotify: spotifyService)
    }

    /// Avatar row + sync banner + segmented Picker + filter field, bundled
    /// as ONE always-mounted, non-conditional view. It must never sit
    /// inside the `switch` below — the Picker is a UIKit
    /// `UISegmentedControl`, and this file's own history already measured
    /// what happens when a control like that gets torn down and rebuilt on
    /// every collapse (`CollapsingHeader`, killed app-wide for a 50-100ms
    /// scroll stutter). That risk is about INSERT/REMOVE, not "exists
    /// inside something scrollable" — keeping this outside the switch
    /// means its identity never changes when `shelfVM.segment` does, so
    /// nothing here is ever torn down. Scrolling the shared `ScrollView` in
    /// `body` is what makes it float away, the same zero-cost pattern
    /// `SearchView` uses for its own header.
    ///
    /// `ProfileAvatarRow()` is INLINE content here, its own row above the
    /// rest — not a `.screenControls(trailing:)` floating overlay, which
    /// was tried first and was a real bug: a fixed-position overlay
    /// doesn't know this content now scrolls, so at some scroll offsets it
    /// sat on top of the segmented Picker instead of beside it (visibly
    /// clipping the "Liked" tab). Matches Home/Feed/NearMe's own
    /// convention exactly for the same reason — reserving real space is
    /// the only version of this that structurally cannot overlap anything.
    private var shelfControls: some View {
        VStack(spacing: 0) {
            ProfileAvatarRow()

            if syncService.isSyncing {
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("Syncing library…")
                        .font(Font.nodalong.footnote)
                        .foregroundStyle(Color.nodalong.textOnAccent.opacity(0.85))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.nodalong.purpleDark)
            }

            Picker("Segment", selection: $shelfVM.segment) {
                ForEach(ShelfViewModel.Segment.allCases, id: \.self) {
                    Text($0.rawValue).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)

            filterField
        }
    }

    var body: some View {
        // `@Bindable` is required to derive a `$` binding from an
        // `@Observable` object held in the environment.
        @Bindable var authVM = authVM

        NavigationStack(path: $router.shelfPath) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        shelfControls
                            .id("top")

                        Group {
                            switch shelfVM.segment {
                            case .playlists:     PlaylistsShelfView()
                            case .albums:        AlbumsListView()
                            case .artists:       ArtistsListView()
                            case .genres:        GenresListView()
                            case .recentlyLiked: RecentlyLikedListView()
                            }
                        }

                        // Breathing room between the last row and the mini
                        // player — one shared spacer now that every segment
                        // lives in the same scroll content, instead of a
                        // copy per segment.
                        if playerVM.nowPlaying != nil {
                            Color.clear.frame(height: 70)
                        }
                    }
                }
                .screenBackground()
                .onChange(of: shelfVM.segment) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo("top", anchor: .top)
                    }
                }
                // Re-tap of the Shelf tab while already at its root.
                .onChange(of: router.scrollToTopRequests[.shelf]) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo("top", anchor: .top)
                    }
                }
                .navigationDestination(for: ShelfRoute.self) { route in
                    switch route {
                    case .artist(let name):     ArtistDetailView(artistName: name)
                    case .album(let key):       AlbumDetailView(albumKey: key, path: $router.shelfPath)
                    case .catalogArtist(let a): ArtistDetailSearchView(artist: a)
                    case .genre(let name):      GenreDetailView(genre: name)
                    }
                }
                .navigationDestination(for: Playlist.self) { playlist in
                    PlaylistDetailView(playlist: playlist)
                }
                .navigationDestination(for: AlbumResult.self) { album in
                    AlbumDetailSearchView(album: album)
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
                .navigationDestination(for: ArtistResult.self) { artist in
                    ArtistDetailSearchView(artist: artist)
                }
                .navigationDestination(for: PendingCatalogAlbumLookup.self) { pending in
                    ResolvingAlbumView(
                        name: pending.name, artistName: pending.artistName, artwork: pending.artwork,
                        cached: MusicDetailCache.peekResolvedAlbum(
                            key: CatalogPrefetch.nameAlbumKey(name: pending.name, artist: pending.artistName))
                    ) {
                        // Apple path routes through the app-wide album
                        // resolver (name-gated relationship + album search —
                        // see `AppleMusicService.resolveAlbum`) so a Shelf
                        // tap resolves identically to the player's album tap
                        // and Home's Jump Back In. The fuzzy `searchAll`
                        // fallback stays only for the non-Apple (suspended
                        // Spotify) path, which has no resolver equivalent.
                        if playerVM.activeService == .appleMusic {
                            // Through `MusicDetailCache` on the SAME key
                            // `CatalogPrefetch.albumByName` writes, so the
                            // album screen's own browse-time prefetch is
                            // actually visible to this tap (resolving
                            // directly here bypassed it entirely).
                            return await MusicDetailCache.shared.resolvedAlbum(
                                forKey: CatalogPrefetch.nameAlbumKey(name: pending.name, artist: pending.artistName)
                            ) {
                                await musicService.resolveAlbum(
                                    catalogTrackId: nil, isrc: nil,
                                    title: pending.name, artist: pending.artistName
                                )
                            }
                        }
                        let results = try? await activeService.searchAll("\(pending.name) \(pending.artistName)", maxPerType: 1)
                        return results?.albums.first
                    }
                }
                .navigationDestination(for: PendingCatalogArtistLookup.self) { pending in
                    ResolvingArtistView(name: pending.name, cached: MusicDetailCache.peekArtistByName(pending.name)) {
                        // Through `MusicDetailCache.resolveArtistByName` —
                        // the same key `CatalogPrefetch.artistByName` warms,
                        // which also chains the artist's own detail fetch.
                        if playerVM.activeService == .appleMusic {
                            return await MusicDetailCache.shared.resolveArtistByName(pending.name) {
                                (try? await musicService.searchAll(pending.name, maxPerType: 1))?.artists.first
                            }
                        }
                        let results = try? await activeService.searchAll(pending.name, maxPerType: 1)
                        return results?.artists.first
                    }
                }
                // Landed here from `router.dismissThenPush` — NowPlayingView's
                // artist/album tap, or PartyView's — since a push always
                // targets whichever tab happens to be selected.
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
            }
            // Hoisted off `ScreenHeader` so the pop-gesture install survives
            // the header being collapsed away — see `SwipeBackGesture.swift`.
            .enablesInteractiveSwipeBack()
            .toolbar(.hidden, for: .navigationBar)
            .profileEntryPoint()
            // `.enablesInteractiveSwipeBack()` only — the avatar lives in
            // `shelfControls` as inline content now, not a floating
            // overlay (see that property's doc comment for why the
            // overlay version was a real bug). `showsBack: false` — a tab
            // root has nothing to pop to.
            .screenControls(showsBack: false)
        }
        .alert("Daily Limit Reached", isPresented: $authVM.spotlightLimitReached) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You can only spotlight \(maxSpotlights) tracks per day. Remove one to swap it out.")
        }
        .task {
            guard let uid = authVM.currentUser?.uid else { return }
            await libraryVM.load(uid: uid)
            shelfVM.setTracks(libraryVM.tracks, albums: libraryVM.albumGroups, artists: libraryVM.artistEntries, genres: libraryVM.genreEntries, recentlyLiked: libraryVM.recentlyLiked)
            await playlistsVM.load(uid: uid)
        }
        .onChange(of: syncService.lastSyncedAt) {
            guard let uid = authVM.currentUser?.uid else { return }
            Task {
                await libraryVM.load(uid: uid)
                shelfVM.setTracks(libraryVM.tracks, albums: libraryVM.albumGroups, artists: libraryVM.artistEntries, genres: libraryVM.genreEntries, recentlyLiked: libraryVM.recentlyLiked)
            }
        }
        .onChange(of: libraryVM.tracks) { _, newTracks in
            shelfVM.setTracks(newTracks, albums: libraryVM.albumGroups,
                              artists: libraryVM.artistEntries, genres: libraryVM.genreEntries,
                              recentlyLiked: libraryVM.recentlyLiked)
        }
    }
}

// MARK: - Library filter

private extension ShelfView {
    /// Shelf's library filter, rendered IN THE CONTENT rather than as
    /// `.searchable` in the navigation bar.
    ///
    /// This is a relocation, not a removal — same binding, same behaviour,
    /// same reach across every segment.
    ///
    /// `.searchable` puts the field inside the nav bar, which makes Shelf's
    /// bar taller than every screen pushed from it. UIKit then has to
    /// animate that height away on each push, and the pushed screen's top
    /// safe-area inset settles AFTER the transition rather than during it —
    /// the album artwork sitting under an over-tall header for a beat before
    /// snapping up. Moving `.searchable` from the `NavigationStack` onto the
    /// root view (an earlier attempt) fixed which screen OWNS the field, but
    /// not the height change, so the settle remained.
    ///
    /// The tell is that album → artist has never done this: neither screen
    /// has a search bar, so their nav bars are the same height and there is
    /// nothing to animate. Matching that here — one constant nav-bar height
    /// across Shelf and everything it pushes — removes the cause outright
    /// rather than trying to make the resize fast enough not to notice.
    ///
    /// Side benefits of being in-content: the filter sits directly above the
    /// segment it filters, and it doesn't compete with the nav title.
    ///
    /// Frosted (`.ultraThinMaterial`) rather than a solid `bgCard` fill — it
    /// now scrolls with the rest of `shelfControls` over the animated mesh
    /// (see `ShelfView.body`), and the frosted look is what actually reads
    /// as "floating over" the mesh rather than an opaque bar sitting in
    /// front of it. Matches `SearchView`'s own query field for the same
    /// reason.
    var filterField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(Font.nodalong.subheadline)
                .foregroundStyle(Color.nodalong.textSecondary)
            TextField("Filter…", text: $shelfVM.searchQuery)
                .textFieldStyle(.plain)
                .font(Font.nodalong.subheadline)
                .foregroundStyle(Color.nodalong.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !shelfVM.searchQuery.isEmpty {
                Button {
                    shelfVM.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Font.nodalong.subheadline)
                        .foregroundStyle(Color.nodalong.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}

// MARK: - Albums grid

private struct AlbumsListView: View {
    @EnvironmentObject private var shelfVM:   ShelfViewModel
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @EnvironmentObject private var playerVM:  PlayerViewModel

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        // Only when there is nothing to show — a restored library renders at once.
        if libraryVM.isLoading && libraryVM.tracks.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
        } else if shelfVM.filteredAlbums.isEmpty {
            emptyState(icon: Icons.discOutline, message: shelfVM.searchQuery.isEmpty ? "No albums yet" : "No results")
        } else {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(shelfVM.filteredAlbums, id: \.key) { album in
                    NavigationLink(value: ShelfRoute.album(album.key)) {
                        AlbumTileView(album: album)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
    }
}

// MARK: - Artists list

private struct ArtistsListView: View {
    @EnvironmentObject private var shelfVM:        ShelfViewModel
    @EnvironmentObject private var libraryVM:      LibraryViewModel
    @EnvironmentObject private var musicService:   AppleMusicService
    @EnvironmentObject private var spotifyService: SpotifyMusicService
    @EnvironmentObject private var playerVM:       PlayerViewModel

    private var activeService: any MusicService {
        activeMusicService(playerVM: playerVM, apple: musicService, spotify: spotifyService)
    }

    var body: some View {
        // Only when there is nothing to show — a restored library renders at once.
        if libraryVM.isLoading && libraryVM.tracks.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
        } else if shelfVM.filteredArtists.isEmpty {
            emptyState(icon: Icons.person, message: shelfVM.searchQuery.isEmpty ? "No artists yet" : "No results")
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(shelfVM.filteredArtists.enumerated()), id: \.element.name) { index, artist in
                    NavigationLink(value: ShelfRoute.artist(artist.name)) {
                        ArtistRow(artist: artist, imageUrl: shelfVM.artistImages[artist.name])
                    }
                    .buttonStyle(.plain)
                    // Rows hug their content, and a `LazyVStack` centres
                    // anything narrower than itself — which is what put the
                    // artist/genre rows in the middle of their container
                    // after these lists moved off `List` (which leading-
                    // aligns for free). `contentShape` keeps the whole row
                    // tappable now that it spans the full width.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    if index < shelfVM.filteredArtists.count - 1 {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .shelfBoxedList()
            .task {
                guard activeService.isAuthenticated else { return }
                await shelfVM.fetchArtistImages(via: activeService)
            }
        }
    }
}

// MARK: - Playlists segment

private struct PlaylistsShelfView: View {
    @Environment(FirebaseAuthViewModel.self) private var authVM
    @EnvironmentObject private var playlistsVM: PlaylistsViewModel
    @EnvironmentObject private var playerVM:    PlayerViewModel
    @EnvironmentObject private var shelfVM:     ShelfViewModel

    @State private var showCreate = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var filtered: [Playlist] {
        let q = shelfVM.searchQuery
        guard !q.isEmpty else { return playlistsVM.playlists }
        return playlistsVM.playlists.filter { $0.title.lowercased().contains(q.lowercased()) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button { showCreate = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                    Text("New Playlist")
                }
                .font(Font.nodalong.subheadlineSemibold)
                .foregroundStyle(Color.nodalong.purpleAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.nodalong.bgCard)
                .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 12)

            if filtered.isEmpty {
                emptyState(icon: Icons.musicalNotesOutline,
                           message: shelfVM.searchQuery.isEmpty ? "No playlists yet" : "No results")
                    .padding(.top, 40)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(filtered) { playlist in
                        NavigationLink(value: playlist) {
                            PlaylistTile(playlist: playlist)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                // Warm the top of the grid — see `PlaylistTracksCache.prefetch`.
                .task(id: filtered.map(\.id)) {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard !Task.isCancelled else { return }
                    await PlaylistTracksCache.prefetch(filtered, viewerUid: authVM.currentUser?.uid)
                }
                .padding(.top, 12)
            }
        }
        .sheet(isPresented: $showCreate) { CreatePlaylistSheet() }
    }
}

// MARK: - Recently Liked segment

private struct RecentlyLikedListView: View {
    @EnvironmentObject private var shelfVM:        ShelfViewModel
    @EnvironmentObject private var libraryVM:      LibraryViewModel
    @EnvironmentObject private var playerVM:       PlayerViewModel
    @EnvironmentObject private var musicService:   AppleMusicService
    @EnvironmentObject private var spotifyService: SpotifyMusicService
    @Environment(FirebaseAuthViewModel.self) private var authVM

    private var activeService: any MusicService {
        activeMusicService(playerVM: playerVM, apple: musicService, spotify: spotifyService)
    }

    var body: some View {
        let tracks = shelfVM.filteredRecentlyLiked
        // Only when there is nothing to show — a restored library renders at once.
        if libraryVM.isLoading && libraryVM.tracks.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
        } else if tracks.isEmpty {
            emptyState(icon: Icons.heart,
                       message: shelfVM.searchQuery.isEmpty ? "No liked songs yet" : "No results")
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    likedRow(track, at: index, in: tracks)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                    if index < tracks.count - 1 {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .shelfBoxedList()
        }
    }

    private func likedRow(_ track: LibraryTrackDoc, at index: Int, in tracks: [LibraryTrackDoc]) -> some View {
        libraryTrackRow(
            track,
            playerVM: playerVM,
            libraryVM: libraryVM,
            authVM: authVM,
            onPlay: {
                guard activeService.isAuthenticated else { return }
                Task { await playerVM.play(tracks.map { Song.from(libraryTrack: $0) }, startingAt: index) }
            }
        )
    }
}

/// One saved-library track: artwork, title/artist, duration, and the shared
/// actions menu (queue / add to playlist / unlike).
///
/// Shared by Shelf's Liked and Genres lists so a track offers the same actions
/// wherever it appears — the genre list originally hand-rolled its own row and
/// silently lacked duration and the whole actions menu.
@ViewBuilder
func libraryTrackRow(
    _ track: LibraryTrackDoc,
    playerVM: PlayerViewModel,
    libraryVM: LibraryViewModel,
    authVM: FirebaseAuthViewModel,
    onPlay: @escaping () -> Void
) -> some View {
    HStack(spacing: 12) {
        ArtworkThumbnail(url: track.artwork, size: 48, isTrack: true)
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
    .contentShape(.rect)
    .onTapGesture(perform: onPlay)
}

// MARK: - Detail views

private struct ArtistDetailView: View {
    let artistName: String
    @EnvironmentObject private var shelfVM:        ShelfViewModel
    @EnvironmentObject private var musicService:   AppleMusicService
    @EnvironmentObject private var spotifyService: SpotifyMusicService
    @EnvironmentObject private var playerVM:       PlayerViewModel

    private var activeService: any MusicService {
        activeMusicService(playerVM: playerVM, apple: musicService, spotify: spotifyService)
    }

    @State private var isSearching   = false
    @State private var catalogArtist: ArtistResult? = nil

    private var artistAlbums: [AlbumGroup] {
        shelfVM.albums.filter { $0.artistName.lowercased() == artistName.lowercased() }
    }

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
        ScrollView {
            VStack(spacing: 0) {
                heroSection

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(artistAlbums, id: \.key) { album in
                        NavigationLink(value: ShelfRoute.album(album.key)) {
                            AlbumTileView(album: album)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        // Extends the SCROLL VIEW into the top safe area so the hero (its
        // first child) starts at the very top — no measurement, no offset,
        // so it behaves the same in every presentation context. See
        // `ArtistDetailSearchView`'s equivalent for the full reasoning.
        .scrollContentBackground(.hidden)
        }
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .screenControls()
        .task { await lookupCatalogArtist() }
    }

    /// Deliberately plain — no status-bar bleed. See
    /// `ArtistDetailSearchView.heroSection`'s doc comment: four attempts at
    /// making this bleed under the status bar each broke a different way,
    /// including one specific to sheet presentation — per direct product
    /// decision, this trades that effect for a design with no bleed math
    /// to get wrong in any context.
    @ViewBuilder
    private var heroSection: some View {
        let heroURL = ArtworkURL.sized(shelfVM.artistImages[artistName] ?? "",
                                       points: ScreenMetrics.bounds.width)
        ZStack(alignment: .bottom) {
            Color.nodalong.bgCard
                .frame(maxWidth: .infinity)
                .overlay {
                    if heroURL.isEmpty {
                        Color.nodalong.bgCard
                    } else {
                        CachedArtworkImage(
                            urlString: heroURL,
                            placeholder: { ShimmerView() },
                            failure: { Color.nodalong.bgCard }
                        )
                    }
                }

            LinearGradient(
                colors: [.clear, Color.nodalong.bgBase],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 110)
        }
        // Taller than the old 220: the hero now starts at the very top of
        // the screen, so ~100pt sits behind the status bar / nav bar.
        .frame(height: 300)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(alignment: .bottomLeading) {
            Group {
                if isSearching {
                    ProgressView().tint(.white).scaleEffect(0.8)
                } else if let artist = catalogArtist {
                    NavigationLink(value: ShelfRoute.catalogArtist(artist)) {
                        HStack(spacing: 4) {
                            Text("Full discography")
                                .font(Font.nodalong.captionSemibold)
                                .foregroundStyle(Color.nodalong.textOnAccent)
                            Image(systemName: "arrow.up.right")
                                .font(Font.nodalong.caption2Semibold)
                                .foregroundStyle(Color.nodalong.textOnAccent)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.50))
                        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
    }

    private func lookupCatalogArtist() async {
        guard activeService.isAuthenticated, catalogArtist == nil else { return }
        isSearching = true
        let results = try? await activeService.searchAll(artistName, maxPerType: 1)
        catalogArtist = results?.artists.first
        isSearching = false
        // Chain into the artist's own detail. The "Full discography" button
        // sits right on this screen, so by the time anyone reaches for it
        // `ArtistDetailSearchView` should already have its albums + top
        // songs rather than starting a second cold fetch after the resolve.
        if let a = catalogArtist, playerVM.activeService == .appleMusic {
            Task { await CatalogPrefetch.artist(a, service: musicService) }
        }
    }
}

private struct AlbumDetailView: View {
    let albumKey: String
    /// Kept alongside `router` because this view also *pops* itself
    /// (`path.removeLast()` after removing the album from the shelf), which the
    /// router has no equivalent for — only pushes route through `router.push`.
    @Binding var path: NavigationPath
    @EnvironmentObject private var router:         AppRouter
    @EnvironmentObject private var shelfVM:        ShelfViewModel
    @EnvironmentObject private var playerVM:       PlayerViewModel
    @EnvironmentObject private var musicService:   AppleMusicService
    @EnvironmentObject private var spotifyService: SpotifyMusicService
    @Environment(FirebaseAuthViewModel.self) private var authVM
    @EnvironmentObject private var libraryVM:      LibraryViewModel

    private var activeService: any MusicService {
        activeMusicService(playerVM: playerVM, apple: musicService, spotify: spotifyService)
    }

    private var album: AlbumGroup? { shelfVM.albums.first(where: { $0.key == albumKey }) }

    /// Real catalog counterparts of the two tappable names in
    /// `headerSection`, once the speculative resolves land. Held so each tap
    /// can push the RESULT rather than a pending marker — see
    /// `CatalogPrefetch.artistByName`'s doc comment for why a warm cache
    /// alone still shows a resolving screen.
    @State private var resolvedArtist: ArtistResult?
    @State private var resolvedCatalogAlbum: AlbumResult?
    /// Other editions of this release, looked up from the catalog album
    /// `resolvedCatalogAlbum` resolves to. A Shelf album is a library
    /// grouping (`AlbumGroup`) with no catalog identity of its own, so this
    /// depends on that resolve landing first.
    @State private var alternates: [AlbumResult] = []

    var body: some View {
        VStack(spacing: 0) {
        // UNCONDITIONAL — deliberately NOT inside the `if let album` below.
        //
        // That branch is exactly where this screen's nav configuration used
        // to live, and `album` is a computed lookup into `shelfVM.albums`,
        // which `ShelfView` reassigns wholesale from three places. Frames
        // rendering with it nil therefore got no configuration at all: the
        // bar fell back to large-title sizing and snapped to inline the
        // moment the lookup resolved, dragging the scroll view's top inset
        // with it. A header declared inside a conditional would reintroduce
        // the same bug in a new form.
        Group {
            if let album {
                ScrollView {
                    VStack(spacing: 0) {
                        headerSection(album)

                        VStack(spacing: 0) {
                            ForEach(Array(album.tracks.enumerated()), id: \.element.id) { idx, track in
                                albumTrackRow(track, at: idx, in: album.tracks)
                                if idx < album.tracks.count - 1 {
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

                        // Clear the floating mini-player pill when playing — the
                        // TabView's safeAreaInset doesn't reliably push pushed-
                        // screen scroll content above the iOS 26 floating tab bar
                        // + pill, so reserve the space explicitly (like FeedView).
                        if playerVM.nowPlaying != nil {
                            Color.clear.frame(height: 70)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        }
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
        // Always applied, never inside a conditional: a header declared
        // inside an `if` reintroduced the nav-bar sizing bug this
        // replaced (see the note above `heroSection`).
        .screenControls {
            if let album {
                Menu {
                    Button(role: .destructive) {
                        removeAlbum(album)
                    } label: {
                        Label("Remove from Shelf", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Color.nodalong.purpleAccent)
                }
            }
        }
        // Both names in `headerSection` are tappable and, until now, neither
        // had anything behind it — Shelf was the only screen with tappable
        // artist/album names and no catalog prefetch at all, which is a poor
        // fit for the one place those names are most prominent.
        //
        // `resolveAlbum` already chains into the album's track list itself
        // (see its doc comment), so warming the resolve warms both halves.
        .task(id: album?.key, priority: .utility) {
            guard let album, playerVM.activeService == .appleMusic else { return }
            async let artist = CatalogPrefetch.artistByName(album.artistName, service: musicService)
            async let catalogAlbum = CatalogPrefetch.albumByName(
                name: album.albumName, artist: album.artistName, service: musicService)
            let (a, al) = await (artist, catalogAlbum)
            resolvedArtist = a
            resolvedCatalogAlbum = al
            // Chained off the album resolve above — the catalog album is what
            // carries the identity the alternates lookup needs.
            if let al {
                alternates = await CatalogPrefetch.alternates(for: al, service: musicService)
                // Saved before release? Apple listed these as "Track N". Only
                // fetch the real list when a saved track actually needs it.
                if album.tracks.contains(where: { isPlaceholderTrackTitle($0.title) || ($0.duration ?? 0) == 0 }) {
                    let service = musicService
                    let (id, name, art) = (al.id, al.name, al.artwork)
                    let real = await MusicDetailCache.shared.tracks(
                        albumId: id, releaseDate: al.releaseDate, name: name, artist: al.artistName, artwork: art
                    ) {
                        (try? await service.getAlbumTracks(albumId: id, albumName: name, artwork: art)) ?? []
                    }
                    await libraryVM.healStaleTracks(from: real)
                }
            }
        }
    }

    /// Removes every track in this album from the Shelf at once (mirrors
    /// `AlbumDetailSearchView.toggleAlbumSave()`'s remove branch), then pops
    /// back to the Albums grid since this album no longer exists to show.
    private func removeAlbum(_ album: AlbumGroup) {
        guard let uid = authVM.currentUser?.uid else { return }
        Task {
            await libraryVM.removeAlbum(uid: uid, tracks: album.tracks)
            path.removeLast()
        }
    }

    @ViewBuilder
    private func headerSection(_ album: AlbumGroup) -> some View {
        let size = ScreenMetrics.bounds.width - 64
        VStack(spacing: 12) {
            // `flipsOnTap: true` — this is an album-detail HERO, the same
            // role `AlbumDetailSearchView`'s hero plays, so it gets the same
            // idle rock + tap-to-flip. The flag is deliberately per-call-site
            // (see `VinylArtworkView.flipsOnTap`): a disc inside a
            // NavigationLink tile must NOT take the tap, so grids/rails stay
            // opted out.
            ArtworkThumbnail(url: album.artwork, size: size, isAlbum: true, flipsOnTap: true)

            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Text(album.albumName)
                        .font(Font.nodalong.title3Bold)
                        .foregroundStyle(Color.nodalong.textPrimary)
                        .multilineTextAlignment(.center)
                    if album.isExplicit { ExplicitBadge() }
                }
                    .contentShape(.rect)
                    .onTapGesture {
                        if let resolvedCatalogAlbum {
                            router.push(resolvedCatalogAlbum,
                                        identity: .album(name: album.albumName, artist: album.artistName),
                                        onto: .shelf)
                        } else {
                            router.push(PendingCatalogAlbumLookup(
                                name: album.albumName, artistName: album.artistName, artwork: album.artwork
                            ),
                            identity: .album(name: album.albumName, artist: album.artistName),
                            onto: .shelf)
                        }
                    }

                Text(album.artistName)
                    .font(Font.nodalong.subheadlineMedium)
                    .foregroundStyle(Color.nodalong.purpleAccent)
                    .contentShape(.rect)
                    .onTapGesture {
                        if let resolvedArtist {
                            router.push(resolvedArtist,
                                        identity: .artist(name: album.artistName),
                                        onto: .shelf)
                        } else {
                            router.push(PendingCatalogArtistLookup(name: album.artistName),
                                        identity: .artist(name: album.artistName),
                                        onto: .shelf)
                        }
                    }

                Text("\(album.trackCount) track\(album.trackCount == 1 ? "" : "s")")
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textSecondary)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 24)
    }

    /// Whether a SAVED track isn't out yet.
    ///
    /// 🔴 Derived from `albumReleaseDate` rather than carrying Apple's
    /// `playParameters` signal (which is what `AlbumDetailSearchView` uses),
    /// and that difference is deliberate. `LibraryTrackDoc` is a Firestore
    /// document: a stored `isPlayable` would be frozen at save time, so an
    /// album pre-saved before release would stay marked unplayable forever
    /// unless something rewrote every row. A date comparison is
    /// self-correcting — the moment the date passes, the track plays — and it
    /// can never be stale in the direction that blocks real playback.
    private static func isUnreleased(_ track: LibraryTrackDoc) -> Bool {
        guard let raw = track.albumReleaseDate,
              let date = releaseDateParser.date(from: raw)
        else { return false }
        return date > Date()
    }

    private static func releaseLabel(for track: LibraryTrackDoc) -> String {
        guard let raw = track.albumReleaseDate,
              let date = releaseDateParser.date(from: raw)
        else { return "Unreleased" }
        return upcomingFormatter.string(from: date)
    }

    /// `en_US_POSIX`: the stored format is a fixed `"yyyy-MM-dd"` and must not
    /// be reinterpreted by the device locale. `static` so no `DateFormatter`
    /// is ever built inside a view body.
    private static let releaseDateParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let upcomingFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f
    }()

    @ViewBuilder
    private func albumTrackRow(_ track: LibraryTrackDoc, at index: Int, in tracks: [LibraryTrackDoc]) -> some View {
        HStack(spacing: 12) {
            Text(track.trackNumber.map(String.init) ?? "")
                .font(Font.nodalong.caption)
                .foregroundStyle(Color.nodalong.textSecondary)
                .frame(width: 24, alignment: .trailing)

            // No artist subtitle — see AlbumDetailSearchView.albumTrackRow's
            // matching comment; these two album screens are deliberately
            // kept visually unified.
            Text(track.title)
                .font(Font.nodalong.subheadlineMedium)
                .foregroundStyle(Self.isUnreleased(track) ? Color.nodalong.textTertiary
                                                          : Color.nodalong.textPrimary)
                .lineLimit(1)
            Spacer()
            if Self.isUnreleased(track) {
                Text(Self.releaseLabel(for: track))
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textTertiary)
            } else if let dur = track.duration, dur > 0 {
                Text(formatTrackDuration(dur))
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textSecondary)
            }
            if !Self.isUnreleased(track) {
                TrackActionsMenuButton(
                    song:         .from(libraryTrack: track),
                    onAddToQueue: { playerVM.addToQueue(.from(libraryTrack: track)) }
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(.rect)
        .onTapGesture {
            guard activeService.isAuthenticated else { return }
            guard !Self.isUnreleased(track) else { return }
            // Play within the album: load the whole list, start at this track,
            // so the rest of the album auto-plays after it.
            // Same reasoning as `AlbumDetailSearchView`: a pre-saved album's
            // unreleased tracks must not enter the queue behind the one
            // released single.
            let playable = tracks.filter { !Self.isUnreleased($0) }
            guard let start = playable.firstIndex(where: { $0.catalogId == track.catalogId }) else { return }
            Task { await playerVM.play(playable.map { Song.from(libraryTrack: $0) }, startingAt: start) }
        }
    }

}

// MARK: - Shared rows

private struct AlbumTileView: View {
    let album: AlbumGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geo in
                ArtworkThumbnail(url: album.artwork, size: geo.size.width, isAlbum: true, onStand: true)
            }
            .aspectRatio(1, contentMode: .fit)
            .padding(.bottom, 6)
            HStack(spacing: 4) {
                Text(album.albumName)
                    .font(Font.nodalong.custom(13, .bold))
                    .foregroundStyle(Color.nodalong.textPrimary)
                    .lineLimit(1)
                if album.isExplicit { ExplicitBadge() }
            }
            Text(album.artistName)
                .font(Font.nodalong.custom(12))
                .foregroundStyle(Color.nodalong.textSecondary)
                .lineLimit(1)
            Text("\(album.trackCount) \(album.trackCount == 1 ? "track" : "tracks")")
                .font(Font.nodalong.custom(11))
                .foregroundStyle(Color.nodalong.textTertiary)
                .padding(.top, 1)
        }
        .padding(.bottom, 4)
    }
}

private struct ArtistRow: View {
    let artist: ArtistEntry
    var imageUrl: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            // Album art is the stable base — always available from the shelf
            // data already loaded. Artist photo fades in on top once the async
            // MusicKit search resolves, preventing the jarring URL-swap flash
            // that occurred when using `imageUrl ?? artist.artwork`.
            ZStack {
                ArtworkThumbnail(url: artist.artwork, size: 48, circular: true)
                if let url = imageUrl {
                    ArtworkThumbnail(url: url, size: 48, circular: true)
                        .transition(.opacity)
                }
            }
            .animation(.easeIn(duration: 0.2), value: imageUrl)

            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name)
                    .font(Font.nodalong.subheadline).fontWeight(.medium)
                    .foregroundStyle(Color.nodalong.textPrimary)
                    .lineLimit(1)
                Text("\(artist.trackCount) tracks · \(artist.albumCount) album\(artist.albumCount == 1 ? "" : "s")")
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textSecondary)
            }
        }
    }
}

// MARK: - Shared helpers

struct ArtworkThumbnail: View {
    let url: String
    var size: CGFloat  = 48
    var circular: Bool = false
    /// Opt-in blur-up placeholder for large renditions (e.g. an album/artist
    /// hero) — checks whether a SMALLER bucket of this same artwork is
    /// already decoded and cached (very likely true right after tapping a
    /// carousel tile of this exact album/artist) and shows it scaled up +
    /// blurred instead of a blank shimmer while the full size loads. See
    /// `CachedArtworkImage.lowResURLString`'s doc comment for why this is a
    /// distinct cache key from the target size in the first place.
    var showsLowResPlaceholder: Bool = false
    /// Opt-in flag for genuinely album-shaped artwork (not tracks, artists,
    /// or playlists) — when `true` AND the user's `AlbumArtworkStyle`
    /// setting is `.vinyl`, renders via `VinylArtworkView` (grooves shown)
    /// instead of the plain square/circular thumbnail below. Defaults
    /// `false`, so every pre-existing call site is completely unaffected
    /// unless explicitly opted in. Left `false` on `VinylArtworkView`'s own
    /// inner artwork call — that's what prevents infinite recursion.
    var isAlbum: Bool = false
    /// Opt-in flag for a single TRACK's own artwork shown in a mixed-artist
    /// list (a playlist, Top Songs, Liked, Feed, Search results, Queue,
    /// Party, NearMe) — same gating as `isAlbum`, but renders with
    /// `showsGrooves: false` (a calmer "small vinyl," distinct from an
    /// album disc even at the same pixel size — confirmed via a live
    /// preview before implementing). Mutually exclusive with `isAlbum` in
    /// practice (no call site sets both); `isAlbum` wins if it somehow were.
    var isTrack: Bool = false
    /// Passed straight through to `VinylArtworkView.flipsOnTap` on the
    /// `isAlbum` branch only — a plain square thumbnail (or a groove-less
    /// track disc) never rocks or flips, regardless of this flag. See
    /// `VinylArtworkView`'s own doc comment for why this is scoped to one
    /// opted-in surface rather than every album disc app-wide.
    var flipsOnTap: Bool = false
    /// Passed straight through to `VinylArtworkView.onStand` on the
    /// `isAlbum` branch only — see that type's doc comment. No effect
    /// under Square style (there's no disc to wedge into anything) or on
    /// `isTrack`.
    var onStand: Bool = false

    @AppStorage(albumArtworkStyleKey) private var albumArtworkStyleRaw = AlbumArtworkStyle.vinyl.rawValue

    var body: some View {
        let isVinylStyle = AlbumArtworkStyle(rawValue: albumArtworkStyleRaw) == .vinyl
        if isAlbum, isVinylStyle {
            VinylArtworkView(url: url, size: size, flipsOnTap: flipsOnTap, onStand: onStand)
        } else if isTrack, isVinylStyle {
            VinylArtworkView(url: url, size: size, showsGrooves: false)
        } else {
            plainBody
        }
    }

    @ViewBuilder
    private var plainBody: some View {
        // Request a CDN rendition sized to the actual thumbnail rather than
        // decoding the stored 600×600 bitmap into a 48 pt frame (memory win).
        let sizedURL = ArtworkURL.sized(url, points: size)
        // Deliberately forces the smallest bucket (44pt input → 160px) rather
        // than deriving from `size` — the smallest bucket is the one most
        // likely to already be resident from ANY small tile shown anywhere
        // else in the app, not just the specific tile that led here.
        let lowResURL = showsLowResPlaceholder ? ArtworkURL.sized(url, points: 44) : nil
        Group {
            if sizedURL.isEmpty {
                // No artwork exists (or the source was an on-device-only
                // `musicKit://` reference `ArtworkURL` already filtered to
                // "") — show the empty-state fill immediately. Passing `nil`
                // to AsyncImage here used to leave it parked in `.empty`
                // forever (Apple's documented behavior: a nil URL never
                // transitions to `.success` or `.failure`), which mapped to
                // `ShimmerView()` below and rendered as a PERMANENT loading
                // shimmer — most visible on Home's "Recently Added" rail,
                // whose library-sourced albums hit this artwork scheme often.
                // Same fix already shipped for `TrackCard`'s artwork, never
                // ported to this second, separate artwork component.
                Color.nodalong.bgCard
            } else {
                CachedArtworkImage(
                    urlString: sizedURL,
                    lowResURLString: lowResURL,
                    placeholder: { ShimmerView() },
                    failure: { Color.nodalong.bgCard }
                )
            }
        }
        .frame(width: size, height: size)
        .clipped()
        // `Corner.artwork` (square), not `Corner.container` — this is the
        // shared artwork primitive behind ~39 call sites, and it's the INNER
        // clip, so it wins over whatever a call site applies on top.
        .clipShape(circular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: Corner.artwork, style: .continuous)))
    }
}

/// `.frame(maxWidth: .infinity)` only — this used to sit inside a dedicated
/// full-height sibling (where `maxHeight: .infinity` centered it), but every
/// segment now shares one `ScrollView` (see `ShelfView.body`), where
/// `maxHeight: .infinity` would just claim unbounded height instead of
/// centering. Top-padded instead, so it reads just below the header.
private func emptyState(icon: String, message: String) -> some View {
    VStack(spacing: 12) {
        Image(systemName: icon)
            .font(Font.nodalong.largeTitle)
            .foregroundStyle(Color.nodalong.textSecondary)
        Text(message)
            .font(Font.nodalong.subheadline)
            .foregroundStyle(Color.nodalong.textSecondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 60)
}

private extension View {
    /// Replicates `.insetGrouped`'s rounded-card look for a plain
    /// `LazyVStack` of rows — `Corner.container` is tuned to the same
    /// radius (see its own doc comment) specifically so a hand-built list
    /// can match `List`'s chrome. Used by the three segments
    /// (`ArtistsListView`, `RecentlyLikedListView`, `GenresListView`) that
    /// moved off `List` so they could share `ShelfView`'s single scroll
    /// region — none of the three used swipe/reorder, so nothing is lost
    /// in the move, only `List`'s automatic chrome needed replicating.
    func shelfBoxedList() -> some View {
        self
            .background(Color.nodalong.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
            .padding(.horizontal, 16)
    }
}

#if DEBUG
#Preview {
    NavigationStack { ShelfView() }.withPreviewEnvironment()
}
#endif


// MARK: - Genres

/// Shelf's Genres segment. Genre is overlaid onto library tracks from the
/// shared catalog, so this fills in as rows go through genre ingest rather than
/// appearing complete on day one — the empty state says so explicitly instead
/// of implying the user's music has no genres.
private struct GenresListView: View {
    @EnvironmentObject private var shelfVM:   ShelfViewModel
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @EnvironmentObject private var playerVM:  PlayerViewModel

    var body: some View {
        // Only when there is nothing to show — a restored library renders at once.
        if libraryVM.isLoading && libraryVM.tracks.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
        } else if shelfVM.filteredGenres.isEmpty {
            emptyState(
                icon: "guitars",
                message: shelfVM.searchQuery.isEmpty
                    ? "Genres appear as your library syncs"
                    : "No results"
            )
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(shelfVM.filteredGenres.enumerated()), id: \.element.id) { index, genre in
                    NavigationLink(value: ShelfRoute.genre(genre.name)) {
                        HStack(spacing: 12) {
                            ArtworkThumbnail(url: genre.artwork, size: 52)
                                .clipShape(RoundedRectangle(cornerRadius: Corner.artwork, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(genre.name)
                                    .font(Font.nodalong.subheadlineMedium)
                                    .foregroundStyle(Color.nodalong.textPrimary)
                                    .lineLimit(1)
                                Text("\(genre.trackCount) track\(genre.trackCount == 1 ? "" : "s") · \(genre.artistCount) artist\(genre.artistCount == 1 ? "" : "s")")
                                    .font(Font.nodalong.caption)
                                    .foregroundStyle(Color.nodalong.textSecondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    if index < shelfVM.filteredGenres.count - 1 {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .shelfBoxedList()
        }
    }
}

/// Every library track in one genre, newest save first.
private struct GenreDetailView: View {
    let genre: String

    @EnvironmentObject private var libraryVM: LibraryViewModel
    @EnvironmentObject private var playerVM:  PlayerViewModel
    @EnvironmentObject private var shelfVM:   ShelfViewModel
    @EnvironmentObject private var musicService:   AppleMusicService
    @EnvironmentObject private var spotifyService: SpotifyMusicService
    @Environment(FirebaseAuthViewModel.self) private var authVM

    /// Derived ONCE per library change, not per render. `tracksInGenre` scans
    /// the whole library, and as a computed property read from `body` it re-ran
    /// on every re-render — the same shape as the documented scroll stutter.
    @State private var tracks: [LibraryTrackDoc] = []

    var body: some View {
        VStack(spacing: 0) {
        List {
            // A native section header rather than a pinned band: the genre
            // name is this screen's only identity, and a list of tracks says
            // nothing about which genre bucket it is.
            Section(genre) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                libraryTrackRow(
                    track,
                    playerVM: playerVM,
                    libraryVM: libraryVM,
                    authVM: authVM,
                    onPlay: {
                        let songs = tracks.map { Song.from(libraryTrack: $0) }
                        Task { await playerVM.play(songs, startingAt: index) }
                    }
                )
                .listRowBackground(Color.nodalong.bgCard)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        }
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .screenControls()
        .safeAreaInset(edge: .bottom) {
            if playerVM.nowPlaying != nil { Color.clear.frame(height: 70) }
        }
        .task(id: genre) { tracks = tracksInGenre(genre, from: libraryVM.tracks) }
        .onChange(of: libraryVM.tracks) { _, newTracks in
            tracks = tracksInGenre(genre, from: newTracks)
        }
    }
}
