import Foundation
import NodalongKit

/// State for the Shelf tab — Albums grid and Artists list over the user's
/// saved library.
///
/// Holds raw `tracks` plus computed `albums` / `artists` groupings (via
/// `NodalongKit.groupByAlbum` / `groupByArtist`) and a search query for
/// in-shelf filtering. Also kicks off async artist-image lookups against
/// Spotify so the artist list shows photos.
@MainActor
final class ShelfViewModel: ObservableObject {
    enum Segment: String, CaseIterable {
        case playlists = "Playlists"
        case albums = "Albums"
        case artists = "Artists"
        case genres = "Genres"
        case recentlyLiked = "Liked"
    }

    @Published private(set) var tracks: [LibraryTrackDoc] = []
    @Published var segment: Segment = .albums {
        didSet {
            // A freshly-switched segment starts scrolled to the top, so a
            // header left hidden would be stranded over a list that isn't
            // scrolled. In the `didSet` rather than an `.onChange` at the view
            // so no future call site that sets `segment` can forget.
            guard segment != oldValue else { return }
        }
    }

    /// Whether Shelf's tab-root header is currently scrolled away.
    ///
    /// Lives on the view model rather than as `ShelfView` `@State` because all
    /// five segment views drive it and this is the only thing they share — the
    /// alternative was threading a `Binding` through five separate view
    /// signatures. Consistent with `segment` and `searchQuery`, which are
    /// already presentation state held here.
    @Published var searchQuery = ""
    @Published private(set) var artistImages: [String: String] = [:]

    private var imageFetchTask: Task<Void, Never>?
    private static let artistImagesKey = "nodalong.artistImages"

    init() {
        // Pre-load any artist images persisted from a prior launch so the
        // Artists tab shows photos immediately without a MusicKit round-trip.
        if let data  = UserDefaults.standard.data(forKey: Self.artistImagesKey),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            artistImages = saved
        }
    }

    // MARK: - Derived

    // Grouping is NOT done here. `groupByAlbum`/`groupByArtist` are expensive
    // (~13.5 ms for a 441-track library before the Phase 1 regex caching),
    // and these were previously uncached computed properties — so every read
    // re-grouped the whole library. Worse, `filteredAlbums` reads `albums`,
    // so a single Shelf body pass could trigger it several times over.
    //
    // `LibraryViewModel` now computes these once per library change (it owns
    // `tracks`, so it's the correct place), and `setTracks` receives the
    // finished arrays. These stay stored so the filter properties below can
    // read them for free.
    @Published private(set) var albums:  [AlbumGroup]  = []
    @Published private(set) var artists: [ArtistEntry] = []

    var filteredAlbums: [AlbumGroup] {
        guard !searchQuery.isEmpty else { return albums }
        let tokens = tokenize(searchQuery)
        return albums.filter {
            matchesAllTokens(tokens, fields: [$0.albumName.lowercased(), $0.artistName.lowercased()])
        }
    }

    var filteredArtists: [ArtistEntry] {
        guard !searchQuery.isEmpty else { return artists }
        let tokens = tokenize(searchQuery)
        return artists.filter { matchesAllTokens(tokens, fields: [$0.name.lowercased()]) }
    }

    /// The library as a flat song list, most-recently-liked first — backs the
    /// "Liked" Shelf segment. Sorted once by `LibraryViewModel`, not per read.
    @Published private(set) var recentlyLiked: [LibraryTrackDoc] = []

    /// The library bucketed by genre. Genre is overlaid from the shared
    /// catalog, so this stays empty until rows have been through genre ingest.
    @Published private(set) var genres: [GenreEntry] = []

    var filteredGenres: [GenreEntry] {
        guard !searchQuery.isEmpty else { return genres }
        let tokens = tokenize(searchQuery)
        return genres.filter { matchesAllTokens(tokens, fields: [$0.name.lowercased()]) }
    }

    var filteredRecentlyLiked: [LibraryTrackDoc] {
        guard !searchQuery.isEmpty else { return recentlyLiked }
        let tokens = tokenize(searchQuery)
        return recentlyLiked.filter {
            matchesAllTokens(tokens, fields: [$0.title.lowercased(), $0.artist.lowercased(), $0.album.lowercased()])
        }
    }

    // MARK: - Load

    /// Takes the library plus its already-computed groupings. The derived
    /// arrays are passed in rather than recomputed here so the expensive
    /// grouping happens exactly once per library change — see the note on
    /// `albums` above, and `LibraryViewModel.recomputeDerived()`.
    func setTracks(
        _ newTracks: [LibraryTrackDoc],
        albums: [AlbumGroup],
        artists: [ArtistEntry],
        genres: [GenreEntry],
        recentlyLiked: [LibraryTrackDoc]
    ) {
        tracks = newTracks
        self.albums = albums
        self.artists = artists
        self.genres = genres
        self.recentlyLiked = recentlyLiked
    }

    // MARK: - Artist images

    #if DEBUG
    fileprivate func applyMockPreviewState(tracks: [LibraryTrackDoc]) {
        self.tracks = tracks
    }
    #endif

    /// Async-fetches artist photos (via whichever music service is
    /// currently connected) for any artist not yet in the cache. Only
    /// fetches artists whose image is missing — re-visiting the Artists tab
    /// does not re-fetch already-loaded images.
    func fetchArtistImages(via service: any MusicService) async {
        // Only request images for artists we don't already have.
        let unfetched = artists.map(\.name).filter { artistImages[$0] == nil }
        guard !unfetched.isEmpty else { return }

        imageFetchTask?.cancel()
        imageFetchTask = Task {
            await withTaskGroup(of: (String, String?).self) { group in
                for name in unfetched {
                    guard !Task.isCancelled else { break }
                    group.addTask {
                        let results = try? await service.searchAll(name, maxPerType: 1)
                        return (name, results?.artists.first?.imageUrl)
                    }
                }
                for await (name, url) in group {
                    if let url, !url.isEmpty, !Task.isCancelled {
                        artistImages[name] = url
                    }
                }
                // Persist updated cache so images appear instantly on next launch.
                if let data = try? JSONEncoder().encode(artistImages) {
                    UserDefaults.standard.set(data, forKey: Self.artistImagesKey)
                }
            }
        }
        await imageFetchTask?.value
    }
}

#if DEBUG
extension ShelfViewModel {
    /// Shelf VM pre-populated with fixture library tracks for previews.
    static var mockPreview: ShelfViewModel {
        let vm = ShelfViewModel()
        vm.applyMockPreviewState(tracks: PreviewFixtures.libraryTracks)
        return vm
    }
}
#endif
