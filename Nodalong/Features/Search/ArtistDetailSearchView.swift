import SwiftUI
import NodalongKit

/// Artist profile + album list + top tracks for a catalog-search artist.
///
/// Loads the artist's albums and a subset of their tracks on appear via
/// whichever music service is currently connected. Albums navigate to
/// AlbumDetail; top tracks play via `PlayerViewModel`.
struct ArtistDetailSearchView: View {
    let artist: ArtistResult

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

    enum DiscographyTab: String, CaseIterable {
        case albums    = "Albums"
        /// Was "Singles & EPs" — renamed and its content merged with the
        /// former standalone "Features on" section (Apple Music's "Appears
        /// On" data) into one combined tab, per direct request.
        case discovery = "Discovery"
    }

    @State private var albums:         [AlbumResult] = []
    @State private var topTracks:      [Song]        = []
    @State private var similarArtists: [ArtistResult] = []
    @State private var featuresOn:     [AlbumResult]  = []
    @State private var isLoading       = false
    @State private var hasLoaded       = false
    @State private var discographyTab: DiscographyTab = .albums
    @State private var topSongsPage = 0
    /// True once `topTracks` holds the FULL top-songs list rather than just
    /// `getArtistCore`'s first page. Gates the pagination arrows only — page
    /// 1's five rows render immediately either way. Without this, the arrows
    /// appear and the page count jumps 2 → 6 under the user a beat after the
    /// screen paints, which is what read as Top Songs "refreshing itself".
    @State private var topSongsComplete = false
    // Own page state per tab (rather than leaving it inside
    // `DiscographyPageGrid`) so `PageArrowsRow` can be rendered as a
    // sibling OUTSIDE the boxed grid — see `discographySection`. Reset to 0
    // on every tab switch via `.onChange(of: discographyTab)`, matching the
    // implicit reset that used to happen for free when each tab's
    // `DiscographyPageGrid` was a distinct view torn down and recreated by
    // the `if/else` branch switch.
    @State private var albumsGridPage = 0
    @State private var discoveryGridPage = 0

    // Newest release first — `releaseDate` is a plain "yyyy-MM-dd" string
    // (`AppleMusicService.dateFormatter`), so a lexicographic comparison
    // already sorts chronologically; no date parsing needed.
    private var fullAlbums:  [AlbumResult] { albums.filter { $0.albumType == "album"  }.sorted { $0.releaseDate > $1.releaseDate } }
    private var singleAlbums:[AlbumResult] { albums.filter { $0.albumType == "single" }.sorted { $0.releaseDate > $1.releaseDate } }

    /// "Discovery" tab content — singles/EPs plus "Features on" albums
    /// (Apple Music's "Appears On" relationship), merged into one tab per
    /// direct request. Deduped by id in case the same release somehow shows
    /// up via both relationships (rare, but they're genuinely different
    /// MusicKit queries — `.albums` filtered to singles vs. `.appearsOnAlbums`).
    private var discoveryAlbums: [AlbumResult] {
        var seen = Set<String>()
        return (singleAlbums + featuresOn).filter { seen.insert($0.id).inserted }
    }

    private var trackPages: [[Song]] {
        guard !topTracks.isEmpty else { return [] }
        return stride(from: 0, to: topTracks.count, by: 5).map {
            Array(topTracks[$0..<min($0 + 5, topTracks.count)])
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heroSection

                // While nothing has landed yet, show a skeleton instead of a
                // bare spinner. The instant either section's data arrives
                // (independently — see `loadData()`), that section renders
                // for real; nothing here waits for the slower one anymore.
                if isLoading && topTracks.isEmpty && albums.isEmpty {
                    artistLoadingSkeleton
                } else {
                    if !topTracks.isEmpty { popularSection }
                    discographySection
                    if !similarArtists.isEmpty { similarArtistsSection }
                }

                // Clear the floating mini-player pill when a track is playing —
                // the TabView's safeAreaInset doesn't reliably push pushed-screen
                // scroll content above the iOS 26 floating tab bar + pill, so we
                // reserve the space explicitly (matching FeedView).
                if playerVM.nowPlaying != nil {
                    Color.clear.frame(height: 70)
                }
            }
            .padding(.bottom, 40)
        }
        // Full-bleed header, take five — but structurally different from
        // the four attempts that failed. Those all tried to make the HERO
        // reach upward past its own slot (a taller frame plus
        // `ignoresSafeArea`, a bottom-aligned background, a measured
        // `.global` offset) — every one needed a number, and every number
        // was right in some presentation contexts and wrong in others
        // (notably a sheet, where the measured offset was simply wrong).
        //
        // This instead extends the SCROLL VIEW into the top safe area, so
        // its first child — the hero — naturally begins at the very top
        // with nothing to compute. The system supplies the geometry in
        // every context (pushed screen, sheet, any device), so there is no
        // number here that can be right in one place and wrong in another,
        // which was the actual failure mode all four previous times.
        .ignoresSafeArea(edges: .top)
        .background(Color.nodalong.bgBase)
        .navigationBarTitleDisplayMode(.inline)
        // Without this the nav bar paints its own opaque background over
        // the top of the photo — the purple band. Hiding it lets the photo
        // show through behind the back button.
        .toolbarBackground(.hidden, for: .navigationBar)
        // The grid is now pushed by VALUE (`NavigationLink(value:)` on the
        // "See all" button) rather than by an `.navigationDestination(item:)`
        // binding. That item binding was the actual cause of the
        // long-running album-navigation breakage: it presents whenever its
        // item is non-nil, so once the grid was on screen, pushing an album
        // ON TOP of it re-evaluated the artist view with the item still set
        // and re-presented the grid — hence "tap an album, get the See all
        // list again", with the real album screen buried underneath (which
        // is exactly what pressing back twice revealed).
        //
        // `DiscographyTab` is registered here only; nothing else in the app
        // uses that type, so there is no duplicate-registration ambiguity.
        // `AlbumResult` is deliberately NOT registered here — every stack
        // this screen can be pushed onto (Home / Search / Shelf / the
        // player's sheet) already registers it, and SwiftUI resolves
        // duplicate same-type destinations in favour of the one closest to
        // the stack's ROOT (not the closest ancestor, which is what an
        // earlier fix here incorrectly assumed) — so adding a second one
        // locally could never take effect anyway, and only added noise.
        .navigationDestination(for: DiscographyTab.self) { tab in
            DiscographyGridView(
                title: tab.rawValue,
                albums: tab == .albums ? fullAlbums : discoveryAlbums
            )
        }
        .task { await loadData() }
    }

    // MARK: - Hero

    /// Deliberately plain — no status-bar bleed, no `ignoresSafeArea`, no
    /// `GeometryReader` measurement. Four attempts at making the photo
    /// bleed under the status bar each broke a different way (a gap at the
    /// top, the title clipped at the bottom, and — the version this
    /// replaced — a geometry measurement that came out wrong specifically
    /// when this screen is reached inside a sheet, e.g. from Now Playing's
    /// artist tap, vs. a normal push from Search/Home/Shelf). Per direct
    /// product decision, this trades the "photo touches the very top"
    /// effect for a design with no bleed math to get wrong in any
    /// presentation context — the hero just sits normally below the
    /// system status bar / nav bar, like every other screen in the app.
    @ViewBuilder
    private var heroSection: some View {
        let heroURL = ArtworkURL.sized(artist.imageUrl, points: ScreenMetrics.bounds.width)
        // ROOT CAUSE of the long-running "artist name is missing" bug: the
        // previous versions put the photo AND the title as siblings inside
        // one `ZStack`, then applied `.frame(height: 260).clipped()` to the
        // whole thing. But `AsyncImage` + `.scaledToFill()` has a natural
        // size FAR larger than 260pt, and a ZStack sizes to its largest
        // child — so the stack itself was hundreds of points tall, the
        // `.bottomLeading`-aligned title anchored to the bottom of THAT,
        // way below the 260pt frame, and `.clipped()` removed it entirely.
        // (In the earlier status-bar-bleed versions the geometry differed
        // just enough that the title landed half-on/half-off the boundary —
        // which is exactly what the screenshots showed.)
        //
        // Fix: the photo goes in an `.overlay` on a base that is ALREADY
        // constrained to 260pt (so it can never inflate the layout), the
        // clip happens there, and the gradient + title go in a SECOND
        // overlay applied AFTER the clip — so they're sized to the real
        // 260pt box and can never be clipped away. This mirrors Shelf's own
        // `ArtistDetailView` hero, whose "Full discography" button uses the
        // same after-the-frame overlay and has always rendered correctly.
        // Taller than the old 260 because the hero now starts at the very
        // top of the screen (see `.ignoresSafeArea(edges: .top)` on the
        // ScrollView) — roughly the first 100pt sits behind the status bar
        // and nav bar, so this keeps a similar amount of photo visible
        // BELOW the back button to what the non-bleeding 260 showed.
        Color.nodalong.bgCard
            .frame(maxWidth: .infinity)
            .frame(height: 340)
            .overlay {
                if heroURL.isEmpty {
                    Color.nodalong.bgCard
                } else {
                    CachedArtworkImage(
                        urlString: heroURL,
                        // Same blur-up as the album hero — whichever small
                        // carousel tile led here almost certainly already
                        // decoded and cached the 160px bucket of this exact
                        // photo.
                        lowResURLString: ArtworkURL.sized(artist.imageUrl, points: 44),
                        placeholder: { ShimmerView() },
                        failure: { Color.nodalong.bgCard }
                    )
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [.clear, .clear, Color.black.opacity(0.75)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .overlay(alignment: .bottomLeading) {
                    Text(artist.name)
                        .font(Font.nodalong.titleBold)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.6), radius: 6, y: 2)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                }
            }
    }

    // MARK: - Loading skeleton

    /// Shown only until either section has data — see the `body` condition.
    @ViewBuilder
    private var artistLoadingSkeleton: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top Songs")
                .font(Font.nodalong.headline)
                .foregroundStyle(Color.nodalong.textPrimary)
                .padding(.horizontal, 20)
            SkeletonRail(tileSize: 100)
        }
        .padding(.top, 20)
    }

    // MARK: - Popular

    @ViewBuilder
    private var popularSection: some View {
        let pages = trackPages
        VStack(alignment: .leading, spacing: 8) {
            Text("Top Songs")
                .font(Font.nodalong.headline)
                .foregroundStyle(Color.nodalong.textPrimary)
                .padding(.horizontal, 20)

            TabView(selection: $topSongsPage) {
                ForEach(Array(pages.enumerated()), id: \.offset) { idx, page in
                    VStack(spacing: 0) {
                        ForEach(page) { song in
                            popularTrackRow(song)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .background(Color.nodalong.bgCard)
                    .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                    .padding(.horizontal, 20)
                    .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 5 * 56 + 28)

            // Bottom-left/right, matching `SpotlightCarousel`'s bare
            // chevron style — a discrete row below the card, not an
            // overlay, so it can't sit on top of the last track row.
            if topSongsComplete && pages.count > 1 {
                PageArrowsRow(pageIndex: $topSongsPage, pageCount: pages.count)
                    .padding(.horizontal, 20)
            }
        }
        .padding(.top, 20)
    }

    @ViewBuilder
    private func popularTrackRow(_ song: Song) -> some View {
        let isLiked = libraryVM.isInLibrary(catalogId: song.catalogId, uri: song.uri)
        HStack(spacing: 12) {
            ArtworkThumbnail(url: song.artwork, size: 44, isTrack: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(Font.nodalong.subheadlineMedium)
                    .foregroundStyle(Color.nodalong.textPrimary)
                    .lineLimit(1)
                Text(song.artist)
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            TrackActionsMenuButton(
                song:         song,
                onAddToQueue: { playerVM.addToQueue(song) },
                onToggleLike: {
                    guard let uid = authVM.currentUser?.uid else { return }
                    let doc = LibraryTrackDoc(
                        catalogId:     song.catalogId ?? "",
                        title:         song.title,
                        artist:        song.artist,
                        album:         song.album,
                        artwork:       song.artwork,
                        uri:           song.uri,
                        sourceService: song.sourceService,
                        isrc:          song.isrc,
                        duration:      song.duration,
                        trackNumber:   song.trackNumber,
                        albumReleaseDate: song.albumReleaseDate,
                        savedAt:       Date().timeIntervalSince1970 * 1000
                    )
                    Task { await libraryVM.toggleLibrary(uid: uid, track: doc) }
                },
                isLiked: isLiked
            )
        }
        .frame(height: 56)
        .contentShape(.rect)
        .onTapGesture {
            guard activeService.isAuthenticated else { return }
            // Play within the Top Songs list so the rest auto-plays after it.
            if let idx = topTracks.firstIndex(where: { $0.id == song.id }) {
                Task { await playerVM.play(topTracks, startingAt: idx) }
            } else {
                Task { await playerVM.play(song) }
            }
        }
    }

    // MARK: - Discography

    @ViewBuilder
    private var discographySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Discography")
                    .font(Font.nodalong.headline)
                    .foregroundStyle(Color.nodalong.textPrimary)
                Spacer()
                // The one and only way into the full grid, and a plain
                // value-based link so it behaves like every other push in
                // the app (see the destination declarations on `body`).
                NavigationLink(value: discographyTab) {
                    HStack(spacing: 2) {
                        Text("See all")
                        Image(systemName: "chevron.right")
                            .font(Font.nodalong.caption2Semibold)
                    }
                    .font(Font.nodalong.subheadlineMedium)
                    .foregroundStyle(Color.nodalong.purpleAccent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 16)

            // One rounded card wraps the tabs AND the album row — the
            // rounded top edge now sits above the tabs, not just around the
            // carousel below them (previously the tabs floated free above a
            // separately-rounded row).
            VStack(spacing: 0) {
                // Tabs just switch the carousel. The retap-to-grid gesture
                // that used to live here is gone: it required a second,
                // programmatic push mechanism (the item binding that broke
                // album navigation), it was never discoverable — which is
                // why the explicit "See all ›" link above was added — and
                // a tab behaving differently on its second tap is unusual
                // on its own.
                HStack(spacing: 0) {
                    ForEach(DiscographyTab.allCases, id: \.self) { tab in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { discographyTab = tab }
                        } label: {
                            VStack(spacing: 8) {
                                Text(tab.rawValue)
                                    .font(Font.nodalong.subheadline(emphasized: discographyTab == tab))
                                    .foregroundStyle(discographyTab == tab ? Color.nodalong.textPrimary : Color.nodalong.textSecondary)
                                    .frame(maxWidth: .infinity)
                                Rectangle()
                                    .fill(discographyTab == tab ? Color.nodalong.purpleAccent : Color.nodalong.bgCard.opacity(0.4))
                                    .frame(height: 3)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 14)

                // Tab-button switch only, NOT an outer swipeable TabView —
                // deliberate. `DiscographyPageGrid` below is now ITSELF a
                // paged, swipeable 2×2 grid; nesting that inside another
                // swipeable TabView (the old Albums/Discovery paging) would
                // leave a horizontal swipe ambiguous between "next grid
                // page" and "switch tabs," which iOS's gesture handling for
                // nested `.page`-style TabViews doesn't resolve cleanly.
                // Trade-off, flagged directly: swiping between the Albums
                // and Discovery tabs themselves no longer works — only the
                // tab buttons above do. Swiping now means "next page of
                // this tab's own album grid."
                // No fixed height here — `DiscographyPageGrid` sizes itself
                // to whatever its CURRENT page actually needs (see its own
                // doc comment for why a flat "always 2 rows tall" container
                // was wrong: a page with 1–3 albums left a large dead gap
                // below them, on-device confirmed via screenshot).
                if discographyTab == .albums {
                    DiscographyPageGrid(albumList: fullAlbums, emptyMessage: "No albums", cardWidth: discographyCardWidth, pageIndex: $albumsGridPage) { album in
                        albumCard(album, width: discographyCardWidth)
                    }
                } else {
                    // Singles/EPs + "Features on" (Apple Music's "Appears
                    // On" data), merged into one tab — see `discoveryAlbums`.
                    DiscographyPageGrid(albumList: discoveryAlbums, emptyMessage: "Nothing to discover yet", cardWidth: discographyCardWidth, pageIndex: $discoveryGridPage) { album in
                        albumCard(album, width: discographyCardWidth)
                    }
                }
            }
            .background(Color.nodalong.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
            .padding(.horizontal, 20)

            // Bottom-left/right, OUTSIDE the boxed card — matching Top
            // Songs' pattern (`PageArrowsRow` as a sibling below the box,
            // on the plain background) rather than the arrows sitting
            // inside the purple card, which read as visually cluttered.
            let visiblePageCount = discographyPageCount(for: discographyTab == .albums ? fullAlbums : discoveryAlbums)
            if visiblePageCount > 1 {
                PageArrowsRow(
                    pageIndex: discographyTab == .albums ? $albumsGridPage : $discoveryGridPage,
                    pageCount: visiblePageCount
                )
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
        }
        .onChange(of: discographyTab) {
            albumsGridPage = 0
            discoveryGridPage = 0
        }
    }

    /// Card width for the discography grid — two columns side by side, so
    /// this is roughly half of `albumCard`'s own default (60% of screen
    /// width), accounting for the section's outer/inner padding and the
    /// grid's own column gap. Padding/gap bumped from an earlier, tighter
    /// pass per direct feedback that the two discs read as "cramped" —
    /// see `DiscographyPageGrid`'s matching `spacing`/`.padding` values.
    private var discographyCardWidth: CGFloat {
        let screenWidth = ScreenMetrics.bounds.width
        return (screenWidth - 40 - 32 - 16) / 2   // outer 20pt×2, page 16pt×2, grid gap 16pt
    }

    /// Artwork rendering delegates to the shared `ArtworkThumbnail(isAlbum:
    /// true)`, which itself renders via `VinylArtworkView` when the user's
    /// `AlbumArtworkStyle` setting is `.vinyl` (the default) — this used to
    /// be a hardcoded, un-toggleable local `vinylArtwork(url:size:)`
    /// function; now this screen follows the same app-wide setting as every
    /// other album-artwork context.
    @ViewBuilder
    private func albumCard(_ album: AlbumResult, width: CGFloat = ScreenMetrics.bounds.width * 0.6) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkThumbnail(url: album.artwork, size: width, isAlbum: true)
            HStack(spacing: 4) {
                MarqueeText(text: album.name, font: Font.nodalong.subheadlineSemibold, color: Color.nodalong.textPrimary)
                if album.isExplicit {
                    explicitBadge
                }
            }
            Text("\(String(album.releaseDate.prefix(4))) · \(album.totalTracks) track\(album.totalTracks == 1 ? "" : "s")")
                .font(Font.nodalong.caption)
                .foregroundStyle(Color.nodalong.textSecondary)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
    }

    /// The standard boxed-E explicit-content mark (matches the convention
    /// other music apps use) — shown inline next to a title, not stamped on
    /// the artwork itself.
    private var explicitBadge: some View {
        Text("🅴")
            .font(Font.nodalong.caption)
            .foregroundStyle(Color.nodalong.textSecondary)
            .fixedSize()
    }

    // MARK: - Similar artists

    @ViewBuilder
    private var similarArtistsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Similar artists")
                .font(Font.nodalong.headline)
                .foregroundStyle(Color.nodalong.textPrimary)
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(similarArtists) { similar in
                        NavigationLink(value: similar) {
                            VStack(spacing: 6) {
                                ArtworkThumbnail(url: similar.imageUrl, size: 64, circular: true)
                                // Reverted from MarqueeText, per direct
                                // feedback — several of these sit side by
                                // side at once (unlike every other marquee
                                // spot in the app, which is one prominent
                                // title at a time), and multiple
                                // independently-scrolling names read as
                                // busy rather than helpful. Wraps to a
                                // second line instead.
                                Text(similar.name)
                                    .font(Font.nodalong.captionMedium)
                                    .foregroundStyle(Color.nodalong.textPrimary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .frame(width: 76)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
            }
            .background(Color.nodalong.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Load

    /// Auto-selects "Discovery" the moment it's clear "Albums" has nothing
    /// to show — an artist with only singles/EPs/features (no LP-type
    /// releases) otherwise landed on a dead "No albums" tab by default, with
    /// the tab that actually has their content one tap away and unlabeled
    /// as such. Only steers away from `.albums`, never away from a tab the
    /// user has already manually chosen (`discographyTab == .albums` guard),
    /// and only when there's actually somewhere better to land — an artist
    /// with genuinely nothing in either tab still shows "No albums" as
    /// before. Called after both `core` and `extras` resolve (`featuresOn`,
    /// part of `discoveryAlbums`, only lands with `extras`), each call
    /// idempotent/harmless if the other hasn't landed yet.
    private func preferDiscoveryTabIfAlbumsEmpty() {
        guard discographyTab == .albums, fullAlbums.isEmpty, !discoveryAlbums.isEmpty else { return }
        discographyTab = .discovery
    }

    private func loadData() async {
        guard activeService.isAuthenticated, !hasLoaded else { return }
        isLoading = true
        defer { isLoading = false; hasLoaded = true }

        if playerVM.activeService == .appleMusic {
            // Session-cached; core (albums/top songs) and extras (similar
            // artists/features-on) are two independent MusicKit requests —
            // see `AppleMusicService.getArtistCore`'s doc comment for why.
            // Both `async let`s start concurrently; each `@State` assignment
            // below fires the instant ITS OWN fetch resolves, so Discography/
            // Top Songs render without waiting on Similar Artists/Features On
            // too (a revisit to either is an instant cache hit either way).
            let service = musicService
            let artistId = artist.id
            async let coreResult = MusicDetailCache.shared.core(artistId: artistId) {
                guard let c = try? await service.getArtistCore(artistId: artistId) else { return nil }
                return ArtistCoreDetails(albums: c.albums, topTracks: c.topTracks)
            }
            async let extrasResult = MusicDetailCache.shared.extras(artistId: artistId) {
                guard let e = try? await service.getArtistExtras(artistId: artistId) else { return nil }
                return ArtistExtraDetails(similarArtists: e.similarArtists, featuresOn: e.featuresOn)
            }
            if let core = await coreResult {
                if albums != core.albums { albums = core.albums }
                if topTracks != core.topTracks { topTracks = core.topTracks }
                // A warm cache already holds the full list, so there's
                // nothing left to top up — show the arrows immediately.
                if core.topTracks.count >= 30 { topSongsComplete = true }
                preferDiscoveryTabIfAlbumsEmpty()
                // Browse-time prefetch — same trick as Search/Home: someone
                // reading this artist's Discography is a likely next tap,
                // so warm the first few albums' track lists now instead of
                // waiting for the tap. Bounded to what's visible without
                // scrolling the carousel.
                for album in core.albums.prefix(6) {
                    let (albumId, albumName, artwork) = (album.id, album.name, album.artwork)
                    Task {
                        _ = await MusicDetailCache.shared.tracks(albumId: albumId) {
                            (try? await service.getAlbumTracks(albumId: albumId, albumName: albumName, artwork: artwork)) ?? []
                        }
                    }
                }
                // Background top-up: `getArtistCore` now deliberately returns
                // only the first page of top songs (one round trip) — real
                // device timing showed paginating to 30 inside the critical
                // path cost 507–1104ms, 55–74% of the whole artist-page load.
                // This tops `topTracks` up to 30 off the critical path;
                // `trackPages` re-paginates reactively, so pages just grow
                // from 2 to 6 with no other change. Guarded so a revisit
                // (already-full cache) doesn't kick off a redundant fetch.
                if core.topTracks.count < 30 {
                    Task {
                        guard let full = try? await service.getArtistTopSongsFull(artistId: artistId),
                              full.count > topTracks.count else {
                            // Nothing more to come — release the arrows so a
                            // multi-page artist isn't left unpageable.
                            topSongsComplete = true
                            return
                        }
                        topTracks = full
                        topSongsComplete = true
                        await MusicDetailCache.shared.updateTopTracks(artistId: artistId, topTracks: full)
                    }
                } else {
                    topSongsComplete = true
                }
                // Same background top-up, for albums — `getArtistCore`'s own
                // `.albums` relationship turned out to have the identical
                // "one unpaginated page from Apple, nothing tops it up"
                // limitation topSongs already had (see
                // `getArtistAlbumsFull`'s doc comment — this is what was
                // actually causing the Discography grid's first page to
                // sometimes show fewer albums than it should on a cold,
                // never-before-viewed artist; not a rendering bug at all).
                if core.albums.count < 50 {
                    Task {
                        guard let full = try? await service.getArtistAlbumsFull(artistId: artistId),
                              full.count > albums.count, full != albums else { return }
                        albums = full
                        preferDiscoveryTabIfAlbumsEmpty()
                        await MusicDetailCache.shared.updateAlbums(artistId: artistId, albums: full)
                    }
                }
            }
            if let extras = await extrasResult {
                similarArtists = extras.similarArtists
                featuresOn = extras.featuresOn
                preferDiscoveryTabIfAlbumsEmpty()
                for similar in extras.similarArtists.prefix(6) {
                    let similarId = similar.id
                    Task {
                        _ = await MusicDetailCache.shared.core(artistId: similarId) {
                            guard let c = try? await service.getArtistCore(artistId: similarId) else { return nil }
                            return ArtistCoreDetails(albums: c.albums, topTracks: c.topTracks)
                        }
                    }
                }
                for album in extras.featuresOn.prefix(6) {
                    let (albumId, albumName, artwork) = (album.id, album.name, album.artwork)
                    Task {
                        _ = await MusicDetailCache.shared.tracks(albumId: albumId) {
                            (try? await service.getAlbumTracks(albumId: albumId, albumName: albumName, artwork: artwork)) ?? []
                        }
                    }
                }
            }
        } else {
            // Suspended-Spotify fallback (see CLAUDE.md) — keeps the
            // protocol pair, but each section now assigns the instant its
            // own fetch lands (two independent tasks, not `async let` +
            // sequential awaits, so whichever finishes first renders first).
            let service = activeService
            let artistId = artist.id
            let albumsTask = Task { try? await service.getArtistAlbums(artistId: artistId) }
            let topTracksTask = Task { try? await service.getArtistTopTracks(artistId: artistId) }
            if let a = await albumsTask.value { albums = a }
            if let t = await topTracksTask.value { topTracks = t }
            // No two-phase top-up on this path — whatever landed is final.
            topSongsComplete = true
            preferDiscoveryTabIfAlbumsEmpty()
        }
    }
}

/// Page count for `DiscographyPageGrid`'s 2×2-per-page chunking. Shared
/// between the grid's own internal `chunks` (which needs the actual
/// sub-arrays, not just a count) and `discographySection`'s external
/// `PageArrowsRow` (which only needs the count, and can't reach `chunks` —
/// it's `private` to the grid) — a plain top-level function so the two
/// can't drift apart the way two independent inline computations once did
/// elsewhere in this file (see `rowCount(forAlbumCount:)`'s own doc
/// comment). Mathematically identical to `stride(from: 0, to: n, by: 4)`'s
/// chunk count for any `n >= 0` — ceiling division by 4.
private func discographyPageCount(for albumList: [AlbumResult]) -> Int {
    (albumList.count + 3) / 4
}

/// A paged 2×2 grid of album cards (4 per page, swipeable), or an
/// empty-state message. No background of its own — sits inside
/// `ArtistDetailSearchView.discographySection`'s single unified card, which
/// owns the `bgCard` fill + rounding; `PageArrowsRow` is rendered
/// separately by that caller too, OUTSIDE the card.
///
/// `pageIndex` is a `@Binding` owned by `discographySection` (one per tab,
/// `albumsGridPage`/`discoveryGridPage`), not local `@State` — needed so
/// `discographySection` can drive the external `PageArrowsRow` from the
/// same value that drives this grid's own `TabView(selection:)`.
///
/// Sizing uses `SpotlightCarousel`'s established two-layer technique: the
/// inner `TabView`'s own frame is PINNED to a CONSTANT, `maxPageHeight` (the
/// tallest page — 2 rows whenever any page is full), so the underlying
/// UIKit paging mechanism never has to relayout mid-swipe — animating that
/// frame directly was tried once already in this project and caused real
/// stutter/clipping bugs (see the decisions log). A separate OUTER frame is
/// the only thing that animates, clipped down to `targetHeight` — a plain
/// COMPUTED property (not `@State`), recomputed fresh from live `chunks` +
/// `pageIndex` on every render, so it cannot go stale the way a
/// hand-synced `@State` value once did here (see `targetHeight`'s own doc
/// comment for the full, previously-misdiagnosed bug history).
///
/// Every PAGE inside the `TabView` is also pinned to the same uniform
/// `maxPageHeight`, not its own row count — `TabView` hands every page the
/// identical slot regardless of what height each one declares, so a
/// shorter page just has empty space at its own bottom (invisible, since
/// its content is top-aligned) rather than the taller pages getting
/// centred and cropped.
private struct DiscographyPageGrid<CardContent: View>: View {
    let albumList: [AlbumResult]
    let emptyMessage: String
    let cardWidth: CGFloat
    @Binding var pageIndex: Int
    @ViewBuilder let cardContent: (AlbumResult) -> CardContent

    /// Room reserved below each disc for its title + caption line.
    ///
    /// `@ScaledMetric` (not a plain constant) because this is an ESTIMATE of
    /// rendered text height, and an under-estimate is what crops content —
    /// the real label block measures ~50pt against this 56pt budget at the
    /// default text size, but at larger accessibility sizes a fixed 56 would
    /// be too small and clip every row.
    @ScaledMetric private var labelHeight: CGFloat = 56

    // Explicit `init` — NOT relying on the synthesized memberwise one.
    // `labelHeight` is `private`, and a struct's synthesized memberwise init
    // takes the most restrictive access level among its stored properties;
    // relying on synthesis here would make the init itself `private` and
    // uncallable from `discographySection` (a sibling type in the same
    // file). Deliberately does NOT assign `labelHeight` — its own `= 56`
    // default applies automatically for any property left untouched here.
    init(albumList: [AlbumResult], emptyMessage: String, cardWidth: CGFloat, pageIndex: Binding<Int>, @ViewBuilder cardContent: @escaping (AlbumResult) -> CardContent) {
        self.albumList = albumList
        self.emptyMessage = emptyMessage
        self.cardWidth = cardWidth
        self._pageIndex = pageIndex
        self.cardContent = cardContent
    }

    private static func rowCount(forAlbumCount count: Int) -> Int {
        max(1, Int((Double(count) / 2.0).rounded(.up)))
    }

    private var chunks: [[AlbumResult]] {
        stride(from: 0, to: albumList.count, by: 4).map {
            Array(albumList[$0..<min($0 + 4, albumList.count)])
        }
    }

    private static var rowGap: CGFloat { 16 }
    private static var pagePadding: CGFloat { 16 }
    private var rowHeight: CGFloat { cardWidth + labelHeight }

    private func pageHeight(forRows rows: Int) -> CGFloat {
        let r = CGFloat(max(rows, 1))
        return rowHeight * r + (rows > 1 ? Self.rowGap : 0) + Self.pagePadding * 2
    }

    /// Rows needed by the TALLEST page — 2 whenever any page is full, 1 when
    /// every page is short (e.g. an artist with only 2 albums total). Every
    /// page is pinned to this so `TabView`'s slot is uniform.
    private var maxRows: Int {
        chunks.map { Self.rowCount(forAlbumCount: $0.count) }.max() ?? 1
    }
    private var maxPageHeight: CGFloat { pageHeight(forRows: maxRows) }

    /// Height the CURRENTLY VISIBLE page needs. A pure function of `chunks`
    /// and `pageIndex`, recomputed on every render — deliberately NOT
    /// `@State`.
    ///
    /// This was previously stored as `@State`, seeded in a custom `init` and
    /// hand-synced by two `.onChange` handlers, and it got permanently stuck
    /// at a 1-row value: `loadData()` assigns `albums` once from `getArtistCore`
    /// and then AGAIN later from a background `getArtistAlbumsFull` top-up, so
    /// this view is routinely created while `albumList` is still empty —
    /// `rowCount(0)` is 1, seeding 1 row. While the list is empty `body`
    /// renders the `emptyMessage` branch, so the `TabView` branch carrying
    /// those `.onChange` handlers doesn't exist yet; when the top-up lands and
    /// that branch finally appears, the handlers are attached fresh and
    /// `.onChange` does not fire for a change that already happened. `@State`
    /// survives it because the empty/non-empty switch is inside one view
    /// instance's own `body` (same identity). The container therefore stayed
    /// sized for 1 row while rendering 2 — content overflowed its slot, got
    /// centred by `TabView`, and `.clipped()` cropped the top row's discs and
    /// the bottom row's labels. It only corrected once `.onChange(of: pageIndex)`
    /// finally fired, i.e. after swiping away and back — exactly the
    /// long-reported symptom. A computed value cannot go stale.
    private var targetHeight: CGFloat {
        let safeIndex = min(max(0, pageIndex), max(0, chunks.count - 1))
        let albumCount = chunks.indices.contains(safeIndex) ? chunks[safeIndex].count : 4
        return pageHeight(forRows: Self.rowCount(forAlbumCount: albumCount))
    }

    var body: some View {
        if albumList.isEmpty {
            Text(emptyMessage)
                .font(Font.nodalong.subheadline)
                .foregroundStyle(Color.nodalong.textSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: pageHeight(forRows: 1))
        } else {
            TabView(selection: $pageIndex) {
                ForEach(Array(chunks.enumerated()), id: \.offset) { idx, chunk in
                    VStack(spacing: Self.rowGap) {
                        ForEach(0..<2, id: \.self) { row in
                            HStack(spacing: Self.rowGap) {
                                ForEach(0..<2, id: \.self) { col in
                                    let i = row * 2 + col
                                    if i < chunk.count {
                                        let album = chunk[i]
                                        NavigationLink(value: album) {
                                            cardContent(album)
                                        }
                                        .buttonStyle(.plain)
                                    } else {
                                        Color.clear.frame(maxWidth: .infinity)
                                    }
                                }
                            }
                        }
                    }
                    .padding(Self.pagePadding)
                    // UNIFORM across every page (`maxPageHeight`, not this
                    // page's own row count) — `TabView` hands every page the
                    // SAME slot regardless of what height each page declares,
                    // so a page taller than that slot gets centred and
                    // cropped top AND bottom by the outer `.clipped()` below.
                    // That mismatch — not a rendering bug — was the actual
                    // cause of "discs cut off at the top, labels missing at
                    // the bottom." See `targetHeight`'s doc comment for the
                    // full story.
                    .frame(height: maxPageHeight, alignment: .top)
                    .tag(idx)
                }
            }
            // Inner frame is CONSTANT (`maxPageHeight`, not the animated
            // `targetHeight`) so the pager's own slot never resizes — only
            // the OUTER crop below animates. Animating a paged `TabView`'s
            // own height instead forces its underlying UIKit page view to
            // relayout mid-swipe (the same reason `SpotlightCarousel` uses
            // this exact two-layer split).
            .frame(height: maxPageHeight)
            .tabViewStyle(.page(indexDisplayMode: .never))
            // Outer animated crop — the only thing that changes height, and
            // it's a plain computed value, not `@State`, so it can't go
            // stale the way the previous `@State displayedHeight` +
            // `.onChange` pair did.
            .frame(height: targetHeight, alignment: .top)
            .clipped()
            .animation(.easeInOut(duration: 0.25), value: targetHeight)
            // No arrows here — `pageIndex` is owned by the caller
            // (`discographySection`) specifically so it can render
            // `PageArrowsRow` itself as a sibling OUTSIDE this grid's
            // boxed background, instead of duplicating a second arrows
            // row inside the box.
        }
    }
}

/// Full grid page for one discography tab — reached by retapping the
/// already-selected "Albums" / "Discovery" tab (see `discographyGridTab`
/// on `ArtistDetailSearchView`), matching Apple Music's own "see all"
/// pattern for a bigger, browsable view than the horizontal carousel.
private struct DiscographyGridView: View {
    let title: String
    let albums: [AlbumResult]

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    /// Matches the `LazyVGrid`'s own math (2 columns, 14pt gap, 20pt outer
    /// padding each side). A plain computed width, NOT a `GeometryReader` —
    /// `GeometryReader` inside a grid cell that's also a `NavigationLink`
    /// label is a known source of the link's tap area collapsing to zero on
    /// cell reuse (e.g. reappearing after popping back from a pushed album),
    /// which reads as "the first tap works, every one after just stays on
    /// this page." `albumCard(_:)` (the carousel version, never reported
    /// broken) already used a fixed width for exactly this reason — this
    /// just brings the grid in line with it.
    private var cellWidth: CGFloat {
        (ScreenMetrics.bounds.width - 40 - 14) / 2
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(albums) { album in
                    NavigationLink(value: album) {
                        VStack(alignment: .leading, spacing: 6) {
                            ArtworkThumbnail(url: album.artwork, size: cellWidth, isAlbum: true)
                                .clipShape(RoundedRectangle(cornerRadius: Corner.artwork, style: .continuous))
                            HStack(spacing: 4) {
                                MarqueeText(text: album.name, font: Font.nodalong.subheadlineMedium, color: Color.nodalong.textPrimary)
                                if album.isExplicit {
                                    Text("🅴")
                                        .font(Font.nodalong.caption2)
                                        .foregroundStyle(Color.nodalong.textSecondary)
                                        .fixedSize()
                                }
                            }
                            Text(String(album.releaseDate.prefix(4)))
                                .font(Font.nodalong.caption)
                                .foregroundStyle(Color.nodalong.textSecondary)
                        }
                        .frame(width: cellWidth, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .background(Color.nodalong.bgBase)
        // No `AlbumResult` destination declared here on purpose. An earlier
        // fix added one under the belief that the closest ancestor wins for
        // duplicate same-type destinations — SwiftUI actually resolves in
        // favour of the one closest to the stack's ROOT, so a local copy
        // could not take effect regardless. Album taps here resolve against
        // the ambient registration on whichever stack this sits in
        // (Home / Search / Shelf / the player's sheet), all of which push
        // `AlbumDetailSearchView`.
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        ArtistDetailSearchView(artist: PreviewFixtures.artist)
    }
    .withPreviewEnvironment()
}
#endif
