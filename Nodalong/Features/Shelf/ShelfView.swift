import SwiftUI
import NodalongKit

// MARK: - Navigation

private enum ShelfRoute: Hashable {
    case artist(String)
    case album(String)
    case catalogArtist(ArtistResult)
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

    var body: some View {
        // `@Bindable` is required to derive a `$` binding from an
        // `@Observable` object held in the environment.
        @Bindable var authVM = authVM

        NavigationStack(path: $router.shelfPath) {
            VStack(spacing: 0) {
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
                .padding(.vertical, 10)

                Group {
                    switch shelfVM.segment {
                    case .playlists:     PlaylistsShelfView()
                    case .albums:        AlbumsListView()
                    case .artists:       ArtistsListView()
                    case .recentlyLiked: RecentlyLikedListView()
                    }
                }
                .navigationDestination(for: ShelfRoute.self) { route in
                    switch route {
                    case .artist(let name):     ArtistDetailView(artistName: name)
                    case .album(let key):       AlbumDetailView(albumKey: key, path: $router.shelfPath)
                    case .catalogArtist(let a): ArtistDetailSearchView(artist: a)
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
                    ResolvingAlbumView(name: pending.name, artistName: pending.artistName, artwork: pending.artwork) {
                        // Apple path routes through the app-wide album
                        // resolver (name-gated relationship + album search —
                        // see `AppleMusicService.resolveAlbum`) so a Shelf
                        // tap resolves identically to the player's album tap
                        // and Home's Jump Back In. The fuzzy `searchAll`
                        // fallback stays only for the non-Apple (suspended
                        // Spotify) path, which has no resolver equivalent.
                        if playerVM.activeService == .appleMusic {
                            return await musicService.resolveAlbum(
                                catalogTrackId: nil, isrc: nil,
                                title: pending.name, artist: pending.artistName
                            )
                        }
                        let results = try? await activeService.searchAll("\(pending.name) \(pending.artistName)", maxPerType: 1)
                        return results?.albums.first
                    }
                }
                .navigationDestination(for: PendingCatalogArtistLookup.self) { pending in
                    ResolvingArtistView(name: pending.name) {
                        let results = try? await activeService.searchAll(pending.name, maxPerType: 1)
                        return results?.artists.first
                    }
                }
                // Landed here from `router.dismissThenPush` — NowPlayingView's
                // artist/album tap, or PartyView's — since a push always
                // targets whichever tab happens to be selected.
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
            .background(Color.nodalong.bgBase)
            .navigationTitle("Shelf")
            .navigationBarTitleDisplayMode(.inline)
            .profileEntryPoint()
        }
        .searchable(text: $shelfVM.searchQuery, prompt: "Filter…")
        .alert("Daily Limit Reached", isPresented: $authVM.spotlightLimitReached) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You can only spotlight \(maxSpotlights) tracks per day. Remove one to swap it out.")
        }
        .task {
            guard let uid = authVM.currentUser?.uid else { return }
            await libraryVM.load(uid: uid)
            shelfVM.setTracks(libraryVM.tracks, albums: libraryVM.albumGroups, artists: libraryVM.artistEntries, recentlyLiked: libraryVM.recentlyLiked)
            await playlistsVM.load(uid: uid)
        }
        .onChange(of: syncService.lastSyncedAt) {
            guard let uid = authVM.currentUser?.uid else { return }
            Task {
                await libraryVM.load(uid: uid)
                shelfVM.setTracks(libraryVM.tracks, albums: libraryVM.albumGroups, artists: libraryVM.artistEntries, recentlyLiked: libraryVM.recentlyLiked)
            }
        }
        .onChange(of: libraryVM.tracks) { _, newTracks in
            shelfVM.setTracks(newTracks, albums: libraryVM.albumGroups,
                              artists: libraryVM.artistEntries,
                              recentlyLiked: libraryVM.recentlyLiked)
        }
    }
}

// MARK: - Albums grid

private struct AlbumsListView: View {
    @EnvironmentObject private var shelfVM:   ShelfViewModel
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @EnvironmentObject private var playerVM:  PlayerViewModel

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        if libraryVM.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if shelfVM.filteredAlbums.isEmpty {
            emptyState(icon: Icons.discOutline, message: shelfVM.searchQuery.isEmpty ? "No albums yet" : "No results")
        } else {
            ScrollView {
                // Featured hero — first album full-width
                if let hero = shelfVM.filteredAlbums.first {
                    NavigationLink(value: ShelfRoute.album(hero.key)) {
                        AlbumHero(album: hero)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                }

                // Rest of albums in 2-column grid
                let rest = shelfVM.filteredAlbums.dropFirst()
                if !rest.isEmpty {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(rest, id: \.key) { album in
                            NavigationLink(value: ShelfRoute.album(album.key)) {
                                AlbumTileView(album: album)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }

                // Breathing room between the last album and the mini player.
                if playerVM.nowPlaying != nil {
                    Color.clear.frame(height: 70)
                }
            }
            .scrollContentBackground(.hidden)
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
        if libraryVM.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if shelfVM.filteredArtists.isEmpty {
            emptyState(icon: Icons.person, message: shelfVM.searchQuery.isEmpty ? "No artists yet" : "No results")
        } else {
            List {
                ForEach(shelfVM.filteredArtists, id: \.name) { artist in
                    NavigationLink(value: ShelfRoute.artist(artist.name)) {
                        ArtistRow(artist: artist, imageUrl: shelfVM.artistImages[artist.name])
                    }
                    .listRowBackground(Color.nodalong.bgCard)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            // A `.safeAreaInset`, not a trailing transparent list row — a
            // conditional spacer row would become the list's true last row
            // whenever something is playing, and `.insetGrouped` rounds the
            // real last row, not "the last row with a color."
            .safeAreaInset(edge: .bottom) {
                if playerVM.nowPlaying != nil { Color.clear.frame(height: 70) }
            }
            .task {
                guard activeService.isAuthenticated else { return }
                await shelfVM.fetchArtistImages(via: activeService)
            }
        }
    }
}

// MARK: - Playlists segment

private struct PlaylistsShelfView: View {
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
        ScrollView {
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
                .padding(.top, 12)
            }

            if playerVM.nowPlaying != nil {
                Color.clear.frame(height: 70)
            }
        }
        .scrollContentBackground(.hidden)
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
        if libraryVM.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tracks.isEmpty {
            emptyState(icon: Icons.heart,
                       message: shelfVM.searchQuery.isEmpty ? "No liked songs yet" : "No results")
        } else {
            List {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    likedRow(track, at: index, in: tracks)
                        .listRowBackground(Color.nodalong.bgCard)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .bottom) {
                if playerVM.nowPlaying != nil { Color.clear.frame(height: 70) }
            }
        }
    }

    private func likedRow(_ track: LibraryTrackDoc, at index: Int, in tracks: [LibraryTrackDoc]) -> some View {
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
                onAddToQueue: { playerVM.addToQueue(.from(libraryTrack: track)) },
                onToggleLike: {
                    guard let uid = authVM.currentUser?.uid else { return }
                    Task { await libraryVM.toggleLibrary(uid: uid, track: track) }
                },
                isLiked: true
            )
        }
        .contentShape(.rect)
        .onTapGesture {
            guard activeService.isAuthenticated else { return }
            Task { await playerVM.play(tracks.map { Song.from(libraryTrack: $0) }, startingAt: index) }
        }
    }
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
        .ignoresSafeArea(edges: .top)
        .scrollContentBackground(.hidden)
        .background(Color.nodalong.bgBase)
        .navigationTitle(artistName)
        .navigationBarTitleDisplayMode(.inline)
        // Otherwise the nav bar's opaque background covers the top of the
        // photo with a flat purple band.
        .toolbarBackground(.hidden, for: .navigationBar)
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
    }
}

private struct AlbumDetailView: View {
    let albumKey: String
    @Binding var path: NavigationPath
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

    var body: some View {
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
                .navigationTitle(album.albumName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
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
            }
        }
        .background(Color.nodalong.bgBase)
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
            ArtworkThumbnail(url: album.artwork, size: size, isAlbum: true)
                .clipShape(RoundedRectangle(cornerRadius: Corner.artwork, style: .continuous))

            VStack(spacing: 4) {
                Text(album.albumName)
                    .font(Font.nodalong.title3Bold)
                    .foregroundStyle(Color.nodalong.textPrimary)
                    .multilineTextAlignment(.center)
                    .contentShape(.rect)
                    .onTapGesture {
                        path.append(PendingCatalogAlbumLookup(
                            name: album.albumName, artistName: album.artistName, artwork: album.artwork
                        ))
                    }

                Text(album.artistName)
                    .font(Font.nodalong.subheadlineMedium)
                    .foregroundStyle(Color.nodalong.purpleAccent)
                    .contentShape(.rect)
                    .onTapGesture {
                        path.append(PendingCatalogArtistLookup(name: album.artistName))
                    }

                Text("\(album.trackCount) track\(album.trackCount == 1 ? "" : "s")")
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textSecondary)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 24)
    }

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
                .foregroundStyle(Color.nodalong.textPrimary)
                .lineLimit(1)
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
            // Play within the album: load the whole list, start at this track,
            // so the rest of the album auto-plays after it.
            Task { await playerVM.play(tracks.map { Song.from(libraryTrack: $0) }, startingAt: index) }
        }
    }

}

// MARK: - Shared rows

private struct AlbumHero: View {
    let album: AlbumGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkThumbnail(url: album.artwork, size: ScreenMetrics.bounds.width - 40, isAlbum: true)
                .clipShape(RoundedRectangle(cornerRadius: Corner.artwork, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(text: album.albumName, font: Font.nodalong.headline, color: Color.nodalong.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MarqueeText(text: album.artistName, font: Font.nodalong.subheadline, color: Color.nodalong.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(album.trackCount) tracks")
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textTertiary)
            }
        }
    }
}

private struct AlbumTileView: View {
    let album: AlbumGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geo in
                ArtworkThumbnail(url: album.artwork, size: geo.size.width, isAlbum: true)
                    .clipShape(RoundedRectangle(cornerRadius: Corner.artwork, style: .continuous))
            }
            .aspectRatio(1, contentMode: .fit)
            .padding(.bottom, 6)
            Text(album.albumName)
                .font(Font.nodalong.custom(13, .bold))
                .foregroundStyle(Color.nodalong.textPrimary)
                .lineLimit(1)
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

    @AppStorage(albumArtworkStyleKey) private var albumArtworkStyleRaw = AlbumArtworkStyle.vinyl.rawValue

    var body: some View {
        let isVinylStyle = AlbumArtworkStyle(rawValue: albumArtworkStyleRaw) == .vinyl
        if isAlbum, isVinylStyle {
            VinylArtworkView(url: url, size: size, flipsOnTap: flipsOnTap)
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

private func emptyState(icon: String, message: String) -> some View {
    VStack(spacing: 12) {
        Image(systemName: icon)
            .font(Font.nodalong.largeTitle)
            .foregroundStyle(Color.nodalong.textSecondary)
        Text(message)
            .font(Font.nodalong.subheadline)
            .foregroundStyle(Color.nodalong.textSecondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}

#if DEBUG
#Preview {
    NavigationStack { ShelfView() }.withPreviewEnvironment()
}
#endif
