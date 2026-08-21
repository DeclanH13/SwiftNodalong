import SwiftUI
import NodalongKit

/// Album track list + metadata for a catalog-search album.
///
/// Reached from SearchView or from a catalog-resolved album in the Shelf.
/// Loads the full track listing on appear via whichever music service is
/// currently connected; tap a track → play.
struct AlbumDetailSearchView: View {
    let album: AlbumResult

    @EnvironmentObject private var musicService:   AppleMusicService
    @EnvironmentObject private var spotifyService: SpotifyMusicService
    @EnvironmentObject private var playerVM:  PlayerViewModel
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @Environment(FirebaseAuthViewModel.self) private var authVM

    /// Whichever backend is actually connected — browsing must route here,
    /// not hardcode Apple Music.
    private var activeService: any MusicService {
        activeMusicService(playerVM: playerVM, apple: musicService, spotify: spotifyService)
    }

    @State private var tracks:         [SearchItem] = []
    /// Starts `true` (not `false`) so the very first render shows the
    /// loading skeleton instead of an empty "Tracks" section for one frame
    /// before `.task` has had a chance to run.
    @State private var isLoading       = true
    @State private var isSavingAlbum   = false

    /// True only when every loaded track is already in the user's library.
    /// Shows "Saved to Shelf" state on the album save button.
    private var allTracksInLibrary: Bool {
        !tracks.isEmpty && tracks.allSatisfy {
            libraryVM.isInLibrary(catalogId: $0.catalogId, uri: $0.uri)
        }
    }

    /// Shared with `ResolvingAlbumView`'s placeholder AND with Shelf's own
    /// `AlbumDetailView` — one canonical album-screen size across the whole
    /// app (per direct request: "the way we show an album from Shelf is how
    /// it should be everywhere"). Computed, not a stored constant, because
    /// it depends on screen width. Not `private`: referenced from
    /// `ResolvingAlbumView.swift` so the two can never drift apart.
    static var heroArtworkSize: CGFloat { ScreenMetrics.bounds.width - 64 }

    /// Local marker for "open the catalog artist by name" — mirrors Shelf's
    /// own `PendingCatalogArtistLookup` but is self-contained here so the
    /// artist-name tap works regardless of which ambient `NavigationStack`
    /// this screen is pushed onto (Home/Search/Shelf/the player's sheet each
    /// register their own destinations, none of which know about this one).
    private struct PendingArtistLookup: Hashable {
        let name: String
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                headerSection
                trackListCard
                if !album.alternates.isEmpty {
                    alternateVersionsSection
                }
                // Clear the floating mini-player pill when a track is
                // playing (matches Shelf's own AlbumDetailView / FeedView).
                if playerVM.nowPlaying != nil {
                    Color.clear.frame(height: 70)
                }
            }
        }
        .background(Color.nodalong.bgBase)
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: PendingArtistLookup.self) { pending in
            ResolvingArtistView(name: pending.name) {
                let t0 = Date()
                // Same cache key as the speculative prefetch in `.task`
                // below — if that already resolved (or is in flight), this
                // is a hit instead of a fresh lookup.
                let result = await MusicDetailCache.shared.resolveArtistByName(pending.name) {
                    let results = try? await activeService.searchAll(pending.name, maxPerType: 1)
                    return results?.artists.first
                }
                diagLog("AlbumDetailSearchView artist tap: resolve('\(pending.name)') \(Int(Date().timeIntervalSince(t0) * 1000))ms")
                return result
            }
        }
        .task {
            // Revisit guard — a session cache hit below makes this
            // effectively free anyway, but skip the whole dance (including
            // re-mapping to SearchItem) if this screen instance already has
            // its tracks.
            guard tracks.isEmpty, activeService.isAuthenticated else { isLoading = false; return }
            isLoading = true
            defer { isLoading = false }

            // Speculative artist-name resolve — the artist NAME is already
            // known the instant this screen appears (before the tracks fetch
            // even starts), so warm the same name-keyed cache the artist-name
            // tap's own resolve closure reads. Best-effort, fire-and-forget:
            // if the user never taps the artist name, this was free; if they
            // do, it's often already a hit instead of a fresh ~260ms lookup.
            if playerVM.activeService == .appleMusic {
                let service = activeService
                let artistName = album.artistName
                Task {
                    _ = await MusicDetailCache.shared.resolveArtistByName(artistName) {
                        let results = try? await service.searchAll(artistName, maxPerType: 1)
                        return results?.artists.first
                    }
                }
            }

            let songs: [NodalongKit.Song]
            if playerVM.activeService == .appleMusic {
                // Session-cached — a revisit (even a fresh screen instance
                // for the same album, e.g. navigating back and forward)
                // skips the MusicKit round trip entirely.
                let service = musicService
                let (id, name, art) = (album.id, album.name, album.artwork)
                songs = await MusicDetailCache.shared.tracks(albumId: id) {
                    (try? await service.getAlbumTracks(albumId: id, albumName: name, artwork: art)) ?? []
                }
            } else {
                songs = (try? await activeService.getAlbumTracks(
                    albumId: album.id, albumName: album.name, artwork: album.artwork
                )) ?? []
            }

            // Map Song → SearchItem so the existing row UI keeps working.
            tracks = songs.map { song in
                SearchItem(
                    key:              "track:\(song.trackId)",
                    title:            song.title,
                    artist:           song.artist,
                    album:            album.name,
                    artwork:          album.artwork,
                    uri:              song.uri,
                    catalogId:        song.catalogId,
                    isrc:             song.isrc,
                    duration:         song.duration,
                    trackNumber:      song.trackNumber,
                    albumReleaseDate: song.albumReleaseDate,
                    sourceService:    song.sourceService
                )
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        VStack(spacing: 12) {
            // `flipsOnTap: true` — the one opted-in surface for the idle
            // rock + tap-to-flip. `ResolvingAlbumView` renders this
            // identical hero at this identical size and deliberately does
            // NOT opt in: it's a transient placeholder swapped out for this
            // real view once the album resolves, so an interactive gesture
            // has nothing durable to attach to there.
            ArtworkThumbnail(url: album.artwork, size: Self.heroArtworkSize, showsLowResPlaceholder: true, isAlbum: true, flipsOnTap: true)
                .clipShape(RoundedRectangle(cornerRadius: Corner.artwork, style: .continuous))
            VStack(spacing: 4) {
                Text(album.name)
                    .font(Font.nodalong.title3Bold)
                    .foregroundStyle(Color.nodalong.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                NavigationLink(value: PendingArtistLookup(name: album.artistName)) {
                    Text(album.artistName)
                        .font(Font.nodalong.subheadlineMedium)
                        .foregroundStyle(Color.nodalong.purpleAccent)
                }
                .buttonStyle(.plain)
                Text("\(album.totalTracks) track\(album.totalTracks == 1 ? "" : "s")")
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textSecondary)
            }
            .padding(.horizontal, 16)

            // Save/remove all tracks in one tap. Unlike Shelf's own album
            // view (which has no equivalent — everything there is already
            // saved), a catalog album genuinely might not be yet.
            Button {
                Task { await toggleAlbumSave() }
            } label: {
                Label(
                    allTracksInLibrary ? "Saved to Shelf" : "Save Album",
                    systemImage: allTracksInLibrary ? Icons.heart : Icons.heartOutline
                )
                .font(Font.nodalong.subheadlineMedium)
                .foregroundStyle(allTracksInLibrary ? Color.nodalong.purpleAccent : Color.nodalong.textPrimary)
            }
            .disabled(tracks.isEmpty || isSavingAlbum)
        }
        .padding(.vertical, 24)
    }

    // MARK: - Track list

    @ViewBuilder
    private var trackListCard: some View {
        VStack(spacing: 0) {
            if isLoading && tracks.isEmpty {
                // `album.totalTracks` is already known client-side (part of
                // the tapped `AlbumResult`, no network needed) — matching the
                // skeleton's row COUNT to it means the card is already the
                // right height before the real fetch ever lands, so there's
                // no size jump when shimmer rows are replaced by real ones.
                // A hardcoded placeholder count here was the real source of
                // the "pop" complaint: even with the per-row stagger
                // animation, the whole card visibly grew/shrank the instant
                // data arrived whenever the real track count differed from
                // the fixed guess.
                let skeletonCount = max(album.totalTracks, 1)
                ForEach(0..<skeletonCount, id: \.self) { idx in
                    ShimmerView()
                        .frame(height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    if idx < skeletonCount - 1 {
                        Divider()
                            .background(Color.nodalong.bgCard.opacity(0.4))
                            .padding(.leading, 16)
                    }
                }
                .transition(.opacity)
            } else {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, track in
                    albumTrackRow(track: track, number: idx + 1, index: idx)
                        // Staggered reveal — each row's `.animation` fires off
                        // the SAME `tracks.count` change (0 → N, one shot) but
                        // with its own per-index delay, so rows cascade in
                        // top-to-bottom instead of popping in as a block.
                        .opacity(rowsRevealed ? 1 : 0)
                        .offset(x: rowsRevealed ? 0 : -12)
                        .animation(
                            .easeOut(duration: 0.32).delay(Double(idx) * 0.035),
                            value: rowsRevealed
                        )
                    if idx < tracks.count - 1 {
                        Divider()
                            .background(Color.nodalong.bgCard.opacity(0.4))
                            .padding(.leading, 60)
                    }
                }
            }
        }
        .background(Color.nodalong.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        .padding(.horizontal, 16)
        .animation(.easeInOut(duration: 0.2), value: isLoading)
        .onChange(of: tracks.count) { _, count in
            if count > 0 { rowsRevealed = true }
        }
    }

    /// Flips once tracks land, driving the staggered per-row reveal above.
    /// A `MusicDetailCache` hit still goes through this — `tracks` still goes
    /// 0 → N via the same assignment, just moments sooner — so a revisit
    /// plays a quick, snappy stagger rather than skipping it outright; it
    /// only ever flips false→true once per screen instance (a fresh push
    /// always starts with fresh `@State`, so there's no stale-true to guard).
    @State private var rowsRevealed = false

    // MARK: - Alternative versions

    /// Other editions of this same release folded away by
    /// `dedupeAlbumEditions` (explicit/clean pairs, deluxe/remaster/etc.) —
    /// listed here instead of shown as separate discography cards. Tapping
    /// one pushes its own `AlbumDetailSearchView`, resolved independently.
    @ViewBuilder
    private var alternateVersionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Alternative versions")
                .font(Font.nodalong.headline)
                .foregroundStyle(Color.nodalong.textPrimary)
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 12)

            VStack(spacing: 0) {
                ForEach(Array(album.alternates.enumerated()), id: \.element.id) { idx, alt in
                    NavigationLink(value: alt) {
                        HStack(spacing: 12) {
                            ArtworkThumbnail(url: alt.artwork, size: 44, isAlbum: true)
                                .clipShape(RoundedRectangle(cornerRadius: Corner.artwork, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(alt.name)
                                    .font(Font.nodalong.subheadlineMedium)
                                    .foregroundStyle(Color.nodalong.textPrimary)
                                    .lineLimit(1)
                                if let label = alt.editionLabel {
                                    Text(label)
                                        .font(Font.nodalong.caption)
                                        .foregroundStyle(Color.nodalong.textSecondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(Font.nodalong.caption)
                                .foregroundStyle(Color.nodalong.textSecondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    if idx < album.alternates.count - 1 {
                        Divider()
                            .background(Color.nodalong.bgCard.opacity(0.4))
                            .padding(.leading, 72)
                    }
                }
            }
            .background(Color.nodalong.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Album save

    /// Saves all tracks if any are unsaved; removes all if every track is already saved.
    private func toggleAlbumSave() async {
        guard let uid = authVM.currentUser?.uid else { return }
        isSavingAlbum = true
        defer { isSavingAlbum = false }

        let docs: [LibraryTrackDoc] = tracks.map { track in
            LibraryTrackDoc(
                catalogId:        track.catalogId ?? "",
                title:            track.title,
                artist:           track.artist,
                album:            album.name,
                artwork:          album.artwork,
                uri:              track.uri,
                sourceService:    .appleMusic,
                isrc:             track.isrc,
                duration:         track.duration,
                trackNumber:      track.trackNumber,
                albumReleaseDate: track.albumReleaseDate,
                savedAt:          Date().timeIntervalSince1970 * 1000
            )
        }

        if allTracksInLibrary {
            await libraryVM.removeAlbum(uid: uid, tracks: docs)
        } else {
            await libraryVM.saveAlbum(uid: uid, tracks: docs)
        }
    }

    @ViewBuilder
    private func albumTrackRow(track: SearchItem, number: Int, index: Int) -> some View {
        let isLiked = libraryVM.isInLibrary(catalogId: track.catalogId, uri: track.uri)
        HStack(spacing: 12) {
            Text("\(number)")
                .font(Font.nodalong.caption)
                .foregroundStyle(Color.nodalong.textSecondary)
                .frame(width: 24, alignment: .trailing)

            // No artist subtitle — the whole screen already establishes it
            // (this is that artist's album), so repeating it on every row
            // was pure redundancy. Kept in Playlist rows, where it's still
            // meaningful (a playlist spans multiple artists).
            Text(track.title)
                .font(Font.nodalong.subheadlineMedium).foregroundStyle(Color.nodalong.textPrimary).lineLimit(1)
            Spacer()
            if let dur = track.duration {
                Text(formatTrackDuration(dur))
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textSecondary)
            }
            TrackActionsMenuButton(
                song:         .from(searchItem: track),
                onAddToQueue: { playerVM.addToQueue(.from(searchItem: track)) },
                onToggleLike: {
                    guard let uid = authVM.currentUser?.uid else { return }
                    let doc = LibraryTrackDoc(
                        catalogId:     track.catalogId ?? "",
                        title:         track.title,
                        artist:        track.artist,
                        album:         album.name,
                        artwork:       album.artwork,
                        uri:           track.uri,
                        sourceService: .appleMusic,
                        isrc:          track.isrc,
                        duration:      track.duration,
                        trackNumber:   track.trackNumber,
                        savedAt:       Date().timeIntervalSince1970 * 1000
                    )
                    Task { await libraryVM.toggleLibrary(uid: uid, track: doc) }
                },
                isLiked: isLiked
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(.rect)
        .onTapGesture {
            guard activeService.isAuthenticated else { return }
            // Play within the album: load the whole list, start at this track.
            Task { await playerVM.play(tracks.map { Song.from(searchItem: $0) }, startingAt: index) }
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        AlbumDetailSearchView(album: PreviewFixtures.album)
    }
    .withPreviewEnvironment()
}
#endif
