import SwiftUI
import NodalongKit

/// Album track list + metadata for a catalog-search album.
///
/// Reached from SearchView or from a catalog-resolved album in the Shelf.
/// Loads the full track listing on appear via whichever music service is
/// currently connected; tap a track → play.
struct AlbumDetailSearchView: View {
    let album: AlbumResult

    @EnvironmentObject private var router:         AppRouter
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

    /// The real catalog artist behind `album.artistName`, once the
    /// speculative resolve in `.task` has produced it. Held so the header's
    /// artist tap can push the ARTIST ITSELF rather than a
    /// `PendingArtistLookup` marker — see `CatalogPrefetch.artistByName`'s
    /// doc comment for why a warm cache alone still shows a resolving
    /// screen.
    @State private var resolvedArtist: ArtistResult?
    /// Other editions of this release.
    ///
    /// NOT read from `album.alternates`: that is only ever populated for an
    /// album that arrived from an artist's discography (the one path where
    /// `dedupeAlbumEditions` has sibling albums to group), so reaching the
    /// same album from Search, Home, or a resolve showed no section at all.
    /// Looked up on demand instead — see `CatalogPrefetch.alternates`.
    @State private var alternates: [AlbumResult] = []
    @State private var tracks:         [SearchItem] = []
    /// Starts `true` (not `false`) so the very first render shows the
    /// loading skeleton instead of an empty "Tracks" section for one frame
    /// before `.task` has had a chance to run.
    @State private var isLoading       = true
    @State private var isSavingAlbum   = false
    /// The artist / alternates prefetch runs once per screen, not on every
    /// re-appearance (popping back to this album re-runs `.task`).
    @State private var didWarmNeighbours = false

    /// Seeds the track list (and the header's artist) from the synchronous
    /// cache peeks, so an album that was prefetched or visited paints
    /// populated on its FIRST frame. Reading through the actor in `.task`
    /// always painted one skeleton frame and then cross-faded out of it,
    /// however warm the cache was.
    init(album: AlbumResult) {
        self.album = album
        if let songs = MusicDetailCache.peekAlbumTracks(albumId: album.id) {
            _tracks = State(initialValue: Self.items(from: songs, album: album))
            _isLoading = State(initialValue: false)
            // 🔴 Required. Rows render at `opacity(rowsRevealed ? 1 : 0)`,
            // and `rowsRevealed` only flips on a `tracks.count` CHANGE — which
            // a seeded list never makes. Without this the rows were present,
            // sized and completely invisible (shipped once, 2026-10-30).
            _rowsRevealed = State(initialValue: true)
        }
        _resolvedArtist = State(initialValue: MusicDetailCache.peekArtistByName(album.artistName))
    }

    /// `Song` → `SearchItem` so the existing row UI keeps working. Shared by
    /// `init`'s seed and `.task`'s fetch so the two can't disagree.
    private static func items(from songs: [NodalongKit.Song], album: AlbumResult) -> [SearchItem] {
        songs.map { song in
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
                sourceService:    song.sourceService,
                isExplicit:       song.isExplicit,
                isPlayable:       song.isPlayable,
                releaseDate:      song.releaseDate
            )
        }
    }

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

    /// Extra space above the hero for the spotlight beam to occupy. Slightly
    /// less than the beam's own reach (`VinylSpotlight.beamHeight`), so the
    /// beam's narrow end runs off the top of the visible area rather than
    /// resolving to a visible point — the light source reads as being
    /// somewhere above the screen, not floating just inside it.
    static var spotlightHeadroom: CGFloat { VinylSpotlight.beamHeight(for: heroArtworkSize) * 0.72 }

    /// The spotlight only makes sense over a record. In square-artwork mode
    /// there is no disc, and a circular lit band would sit wrong on a square
    /// cover — so the whole effect is skipped rather than adapted.
    private var isVinylStyle: Bool {
        AlbumArtworkStyle(rawValue: albumArtworkStyleRaw) == .vinyl
    }

    /// Local marker for "open the catalog artist by name" — mirrors Shelf's
    /// own `PendingCatalogArtistLookup` but is self-contained here so the
    /// artist-name tap works regardless of which ambient `NavigationStack`
    /// this screen is pushed onto (Home/Search/Shelf/the player's sheet each
    /// register their own destinations, none of which know about this one).
    private struct PendingArtistLookup: Hashable {
        let name: String
    }

    @AppStorage(albumArtworkStyleKey) private var albumArtworkStyleRaw = AlbumArtworkStyle.vinyl.rawValue

    var body: some View {
        VStack(spacing: 0) {
        ScrollView {
            VStack(spacing: 0) {
                headerSection
                trackListCard
                if !alternates.isEmpty {
                    AlternateVersionsSection(alternates: alternates)
                }
                // Clear the floating mini-player pill when a track is
                // playing (matches Shelf's own AlbumDetailView / FeedView).
                if playerVM.nowPlaying != nil {
                    Color.clear.frame(height: 70)
                }
            }
        }
        }
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .screenControls()
        // Tell the router this album is what's on top. Carousels push albums
        // with `NavigationLink(value:)`, which the router never sees — without
        // this its slot stays `nil`, the dedup has nothing to match, and this
        // screen's own "…" → Album stacks a second copy of itself.
        .onAppear {
            router.claimTopIdentity(
                .album(name: album.name, artist: album.artistName),
                onto: router.selectedTab
            )
        }
        .navigationDestination(for: PendingArtistLookup.self) { pending in
            ResolvingArtistView(name: pending.name, cached: MusicDetailCache.peekArtistByName(pending.name)) {
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
            // Speculative artist-name resolve — the artist NAME is already
            // known the instant this screen appears (before the tracks fetch
            // even starts), so warm the same name-keyed cache the artist-name
            // tap's own resolve closure reads. Best-effort, fire-and-forget:
            // if the user never taps the artist name, this was free; if they
            // do, it's often already a hit instead of a fresh ~260ms lookup.
            //
            // Routed through `CatalogPrefetch.artistByName`, which also
            // CHAINS into the artist's own detail fetch. Resolving identity
            // alone left `ArtistDetailSearchView` to start its `core` fetch
            // cold on arrival, so the tap showed a resolve spinner and then
            // a second loading state behind it.
            //
            // Runs BEFORE the tracks guard below: since `init` can seed the
            // tracks from cache, that guard now returns early on a warm open,
            // and the neighbours still need warming.
            if !didWarmNeighbours, playerVM.activeService == .appleMusic {
                didWarmNeighbours = true
                let artistName = album.artistName
                let service = musicService
                Task { resolvedArtist = await CatalogPrefetch.artistByName(artistName, service: service) }
                let thisAlbum = album
                Task { alternates = await CatalogPrefetch.alternates(for: thisAlbum, service: service) }
            }

            // Revisit guard — skip the fetch (including re-mapping to
            // SearchItem) if this screen instance already has its tracks,
            // whether from `init`'s cache seed or an earlier run.
            guard tracks.isEmpty, activeService.isAuthenticated else { isLoading = false; return }
            isLoading = true
            defer { isLoading = false }

            let songs: [NodalongKit.Song]
            if playerVM.activeService == .appleMusic {
                // Session-cached — a revisit (even a fresh screen instance
                // for the same album, e.g. navigating back and forward)
                // skips the MusicKit round trip entirely.
                let service = musicService
                let (id, name, art) = (album.id, album.name, album.artwork)
                songs = await MusicDetailCache.shared.tracks(
                    albumId: id, releaseDate: album.releaseDate,
                    name: name, artist: album.artistName, artwork: art
                ) {
                    (try? await service.getAlbumTracks(albumId: id, albumName: name, artwork: art)) ?? []
                }
            } else {
                songs = (try? await activeService.getAlbumTracks(
                    albumId: album.id, albumName: album.name, artwork: album.artwork
                )) ?? []
            }

            // Apple's live list has the real titles; fix any saved placeholders.
            Task { await libraryVM.healStaleTracks(from: songs) }

            tracks = Self.items(from: songs, album: album)
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
                // No `.clipShape` here — a rect clip around a vinyl disc
                // hard-cuts its shadow at the frame edge instead of letting
                // it bleed past the circle as designed (this was the actual
                // cause of the shadow-clipping artifact on this exact hero).
                // `VinylSpotlight`'s beam is a `.background`, free to render
                // past the disc's own bounds regardless of whether anything
                // upstream clips it.
                .vinylSpotlight(size: Self.heroArtworkSize, isEnabled: isVinylStyle)
                // Room for the beam to come from. Without it the beam has
                // nowhere to reach and the scroll view clips it at its top
                // edge, which reads as a grey wedge rather than a light.
                .padding(.top, isVinylStyle ? Self.spotlightHeadroom : 0)
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Text(album.name)
                        .font(Font.nodalong.title3Bold)
                        .foregroundStyle(Color.nodalong.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    if album.isExplicit { ExplicitBadge() }
                }
                // Push the resolved artist directly when we have one —
                // that lands on `ArtistDetailSearchView` immediately, with
                // its `core` cache already warm. Falling back to the pending
                // marker only when the speculative resolve hasn't landed
                // yet (or failed) keeps the previous behaviour as the floor.
                // Routed through the router rather than a `NavigationLink` so
                // it carries a `NavIdentity` — this is the tap a device log
                // caught stacking artist pages invisibly, because a link push
                // is something the router can neither see nor dedup.
                Button {
                    let identity = NavIdentity.artist(name: album.artistName)
                    if let resolvedArtist {
                        router.push(resolvedArtist, identity: identity)
                    } else {
                        router.push(PendingArtistLookup(name: album.artistName), identity: identity)
                    }
                } label: { artistNameLabel }
                .buttonStyle(.plain)
                Text(albumMetaLine)
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
    private var artistNameLabel: some View {
        Text(album.artistName)
            .font(Font.nodalong.subheadlineMedium)
            .foregroundStyle(Color.nodalong.purpleAccent)
    }

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

    /// "11 tracks · 2024" once released; "11 tracks · Releases 3 Oct" before.
    ///
    /// The unreleased case is the whole reason this exists: Apple returns a
    /// pre-release album's unreleased tracks as "Track 1", "Track 3" with no
    /// duration, which reads as a broken screen until something says the
    /// record simply isn't out yet.
    private var albumMetaLine: String {
        let tracks = "\(album.totalTracks) track\(album.totalTracks == 1 ? "" : "s")"
        guard let date = Self.releaseDateParser.date(from: album.releaseDate) else { return tracks }
        if date > Date() {
            return "\(tracks) · Releases \(Self.upcomingFormatter.string(from: date))"
        }
        return "\(tracks) · \(Calendar.current.component(.year, from: date))"
    }

    /// Whether this row can't be played yet.
    ///
    /// 🔴 Checks the release DATE as well as Apple's `playParameters` signal,
    /// and the date is what actually carries this. `isPlayable` is the more
    /// authoritative of the two but it only exists on freshly-fetched tracks:
    /// `MusicDetailCache` disk-persists album tracks, `Song.isPlayable`
    /// decodes tolerantly as `?? true`, so every already-cached album
    /// restored as fully playable and the first version of this shipped
    /// doing nothing on exactly the albums the user had already opened.
    /// The cache is versioned now, but a date comparison is correct on any
    /// vintage of stored row — `albumReleaseDate` has always been populated —
    /// and it self-corrects the moment the date passes, which no stored flag
    /// does. Same reasoning as Shelf's own album screen.
    private func isUnreleased(_ track: SearchItem) -> Bool {
        if !track.isPlayable { return true }
        guard let raw = track.releaseDate ?? track.albumReleaseDate,
              let date = Self.releaseDateParser.date(from: raw)
        else { return false }
        return date > Date()
    }

    /// The date shown where a playable row shows its duration. Falls back to a
    /// plain label when Apple gives no per-track date, which happens — the
    /// row still has to explain why it can't be played.
    private func releaseLabel(for track: SearchItem) -> String {
        guard let raw = track.releaseDate ?? track.albumReleaseDate,
              let date = Self.releaseDateParser.date(from: raw)
        else { return "Unreleased" }
        return Self.upcomingFormatter.string(from: date)
    }

    /// `en_US_POSIX` because the stored format is fixed `"yyyy-MM-dd"` and must
    /// not be reinterpreted by the device locale — same convention as
    /// `HomeSeeAllView.releaseDateFormatter`. Both are `static` so a
    /// `DateFormatter` is never constructed inside a view body.
    private static let releaseDateParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Display side, so this one IS localised.
    private static let upcomingFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f
    }()

    @ViewBuilder
    private func albumTrackRow(track: SearchItem, number: Int, index: Int) -> some View {
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
                .font(Font.nodalong.subheadlineMedium)
                .foregroundStyle(isUnreleased(track) ? Color.nodalong.textTertiary
                                                     : Color.nodalong.textPrimary)
                .lineLimit(1)
            Spacer()
            // An unreleased track has no duration, so the slot carries its
            // release date instead — the one thing worth knowing about a row
            // you can't play.
            if isUnreleased(track) {
                Text(releaseLabel(for: track))
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textTertiary)
            } else if let dur = track.duration {
                Text(formatTrackDuration(dur))
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textSecondary)
            }
            // Nothing in this menu can act on a track that isn't playable:
            // it can't be queued, and saving or spotlighting a placeholder
            // titled "Track 3" would write that placeholder to Firestore.
            if !isUnreleased(track) {
                TrackActionsMenuButton(
                    song:         .from(searchItem: track),
                    onAddToQueue: { playerVM.addToQueue(.from(searchItem: track)) }
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(.rect)
        .onTapGesture {
            guard activeService.isAuthenticated else { return }
            guard !isUnreleased(track) else { return }
            // 🔴 Only the PLAYABLE tracks enter the queue, with the start index
            // remapped into that filtered list. Loading the whole album would
            // mean tapping the one released single on a pre-release record
            // queues every unreleased track behind it — each failing to
            // resolve and burning straight through
            // `skipUnplayableAndAdvance`, one "Skipped (unavailable)" toast
            // at a time.
            let playable = tracks.filter { !isUnreleased($0) }
            guard let start = playable.firstIndex(where: { $0.key == track.key }) else { return }
            Task { await playerVM.play(playable.map { Song.from(searchItem: $0) }, startingAt: start) }
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
