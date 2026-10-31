import Foundation
import NodalongKit

/// State + orchestration for the Search tab.
///
/// Two-axis filtering:
/// - `mode` — **People** (search Nodalong users) or **Music** (search the
///   active music service's catalog — Apple Music or Spotify, whichever is
///   connected; see `activeMusicService(playerVM:apple:spotify:)`). Top-level
///   mental model: "am I looking for a person or for songs?"
/// - `scope` (only meaningful when `mode == .music`) — All / Artists /
///   Albums / Songs. Lets the user narrow what they're after; we send the
///   matching focused request to the catalog to save quota.
///
/// Both axes are debounced by the same 150 ms timer so quick toggle-while-
/// typing collapses into one network call.
@MainActor
final class SearchViewModel: ObservableObject {

    /// Top-level segmented selector. Defaults to `.music` because music
    /// discovery is the more common path; user can swap to People.
    enum SearchMode: String, CaseIterable, Identifiable {
        case people = "People"
        case music  = "Music"
        var id: String { rawValue }
    }

    /// Sub-selector inside the Music mode. `.all` shows artists + albums +
    /// songs stacked; the others narrow to that one section.
    enum MusicSearchScope: String, CaseIterable, Identifiable {
        case all     = "All"
        case artists = "Artists"
        case albums  = "Albums"
        case songs   = "Songs"
        var id: String { rawValue }
    }

    @Published var query              = ""
    @Published var mode: SearchMode   = .music
    @Published var scope: MusicSearchScope = .all

    /// User results. Only populated when `mode == .people`.
    @Published private(set) var userResults: [UserProfile] = []

    /// The unified, word-match-ranked list shown for the All scope. Rebuilt
    /// whenever results arrive or the taste weights change.
    @Published private(set) var rankedHits: [SearchHit] = []
    /// What the user listens to — set by `SearchView` from `LibraryViewModel`.
    /// Only ever breaks ties within a match tier. See `rankSearchHits`.
    var taste: TasteWeights = .empty {
        didSet { if oldValue != taste { rerank() } }
    }

    /// Music catalog results. Sections are populated selectively based on
    /// `scope` — e.g. `.songs` leaves `artists` and `albums` empty so the UI
    /// doesn't render stale data after a scope swap.
    @Published private(set) var results: CombinedSearchResults = .empty {
        didSet { rerank() }
    }
    private var resultCache: [String: (results: CombinedSearchResults, at: Date)] = [:]
    private static let resultCacheTTL: TimeInterval = 300
    private static let resultCacheLimit = 20

    /// The query `results` were fetched for (the live `query` may already be
    /// a keystroke ahead of it).
    private var resultsQuery = ""

    private func rerank() {
        guard scope == .all, !resultsQuery.isEmpty else { rankedHits = []; return }
        let hits = results.artists.map(SearchHit.artist)
            + results.albums.map(SearchHit.album)
            + results.tracks.map(SearchHit.track)
        rankedHits = rankSearchHits(hits, query: resultsQuery, taste: taste)
    }

    @Published private(set) var isSearching    = false
    @Published private(set) var followingUids: Set<String> = []

    /// A genuinely genre-scoped songs chart, shown instead of `results`
    /// when a genre tile is tapped — deliberately a fully separate piece
    /// of state from `query`/`mode`/`scope` rather than layered on top of
    /// them. Setting `query` to the genre name and reusing the normal
    /// `.onChange`-driven search machinery was the first design and was
    /// rejected: that debounced free-text search would fire ~300ms later
    /// and silently overwrite these correct results with the exact
    /// wrong-genre problem this exists to fix (see `showGenreChart`).
    @Published private(set) var genreChartName: String? = nil
    @Published private(set) var genreChartTracks: [SearchItem] = []
    private var genreTask: Task<Void, Never>? = nil

    /// The real underlying error from the most recent failed catalog call,
    /// when one occurred — distinguishes "genuinely no results" from "the
    /// search never actually ran" (e.g. Spotify returning 403). Mirrors
    /// `PlayerViewModel.lastPlaybackErrorDetail`'s established pattern.
    /// Cleared at the start of every new search.
    @Published private(set) var lastSearchErrorDetail: String? = nil

    private var searchTask: Task<Void, Never>? = nil

    // MARK: - Recent searches (local browsing history)

    /// A shortcut back into a previous search — tapping re-populates `query`
    /// (and `mode`/`scope`) and re-runs it through the normal search
    /// pipeline. Persisted locally (UserDefaults, per-uid) — this is
    /// on-device browsing history, not something worth syncing.
    struct RecentSearchEntry: Codable, Identifiable, Equatable {
        enum Kind: String, Codable { case person, artist, album, track }
        let id: String
        let kind: Kind
        let displayName: String
        /// What to type back into `query` to re-run this exact search.
        let queryText: String
    }

    @Published private(set) var recentSearches: [RecentSearchEntry] = []

    private static func recentSearchesKey(uid: String) -> String { "nodalong.recentSearches.\(uid)" }

    func loadRecentSearches(uid: String) {
        guard let data = UserDefaults.standard.data(forKey: Self.recentSearchesKey(uid: uid)),
              let entries = try? JSONDecoder().decode([RecentSearchEntry].self, from: data)
        else { return }
        recentSearches = entries
    }

    /// Records a tapped result as a recent search — upserts to the front
    /// (de-duped by kind+displayName so re-tapping the same thing doesn't
    /// create a duplicate entry), capped at 10.
    func recordRecentSearch(kind: RecentSearchEntry.Kind, displayName: String, queryText: String, uid: String) {
        guard !displayName.isEmpty else { return }
        var entries = recentSearches
        entries.removeAll { $0.kind == kind && $0.displayName == displayName }
        entries.insert(RecentSearchEntry(id: UUID().uuidString, kind: kind, displayName: displayName, queryText: queryText), at: 0)
        entries = Array(entries.prefix(10))
        recentSearches = entries
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.recentSearchesKey(uid: uid))
        }
    }

    func clearRecentSearches(uid: String) {
        recentSearches = []
        UserDefaults.standard.removeObject(forKey: Self.recentSearchesKey(uid: uid))
    }

    /// Re-runs a recent search — sets `mode`/`scope`/`query` from the entry
    /// and triggers a fresh (non-debounced) search, same as a scope tap.
    func selectRecentSearch(_ entry: RecentSearchEntry, via service: any MusicService) {
        mode = entry.kind == .person ? .people : .music
        if mode == .music { scope = .all }
        query = entry.queryText
        search(via: service, debounce: false)
    }

    // MARK: - Browse content (shown while `query` is empty)

    @Published private(set) var suggestedUsers: [UserProfile] = []
    @Published private(set) var liveNow: [LiveNowEntry] = []
    @Published private(set) var popularAlbums: [AlbumResult] = []

    /// Popular albums are the same for everyone, so they persist under the
    /// shared `_catalog` pseudo-uid (like `MusicDetailCache`) and restore
    /// synchronously — the browse rail is populated on the first frame.
    private static let popularAlbumsKey = "popularAlbums"
    private static let sharedUid = "_catalog"

    init() {
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1",
           let saved = SnapshotStore.load([AlbumResult].self, key: Self.popularAlbumsKey, uid: Self.sharedUid) {
            popularAlbums = saved
        }
    }

    /// Fetches the popular-albums rail at launch (it doesn't depend on the
    /// follow graph), so Search's first open already has it. No-op if there.
    func warmPopularAlbums(musicService: AppleMusicService) async {
        guard musicService.isAuthenticated else { return }
        if let fresh = try? await musicService.getPopularAlbums(limit: 10), !fresh.isEmpty {
            if popularAlbums != fresh { popularAlbums = fresh }
            SnapshotStore.save(fresh, key: Self.popularAlbumsKey, uid: Self.sharedUid)
        }
    }

    /// Genre charts turn over daily — cache them per genre for a few hours so
    /// re-tapping a tile (or coming back) is instant.
    private var genreChartCache: [String: (songs: [SearchItem], at: Date)] = [:]
    private static let genreChartTTL: TimeInterval = 6 * 3600

    /// Tracks which uid's browse content is currently loaded — mirrors
    /// `LibraryViewModel.loadedForUid` so an account switch re-fetches
    /// instead of silently showing the previous account's data.
    private var loadedBrowseContentForUid: String? = nil
    private let presenceService = UserPresenceService()

    /// Loads the browse-state content once per signed-in account. The three
    /// fetches are independent (popular albums / suggested people / who's
    /// live) so they run concurrently; each assigns only on success — a
    /// flaky one can't blank a section that already loaded.
    func loadBrowseContent(uid: String, followingUids: [String], musicService: AppleMusicService) async {
        guard loadedBrowseContentForUid != uid else { return }
        loadedBrowseContentForUid = uid

        async let albums: [AlbumResult] = (try? await musicService.getPopularAlbums(limit: 10)) ?? []
        var excluded = Set(followingUids)
        excluded.insert(uid)
        async let suggested: [UserProfile] = (try? await getSuggestedUsers(excluding: excluded)) ?? []
        async let live: [LiveNowEntry] = loadLiveNow(followingUids: followingUids)

        let fetchedAlbums = await albums
        if !fetchedAlbums.isEmpty {
            popularAlbums = fetchedAlbums
            SnapshotStore.save(fetchedAlbums, key: Self.popularAlbumsKey, uid: Self.sharedUid)
        }
        suggestedUsers = await suggested
        liveNow        = await live
    }

    /// Mirrors `HomeViewModel.loadLiveNow` — combines hosted parties
    /// (batched via `FollowingCache`, shared with Home so both don't pay
    /// separately for the same read) with one-time solo-listening presence
    /// reads. Duplicated rather than shared with `HomeViewModel` directly —
    /// it's ~15 lines and the two view models have no other coupling; a
    /// shared dependency here isn't worth the indirection.
    private func loadLiveNow(followingUids: [String]) async -> [LiveNowEntry] {
        guard !followingUids.isEmpty else { return [] }

        let liveParties = await FollowingCache.shared.liveParties(hostedBy: followingUids)
        let hostingUids = Set(liveParties.map(\.hostUid))
        let soloUids = followingUids.filter { !hostingUids.contains($0) }

        var soloEntries: [LiveNowEntry] = []
        if !soloUids.isEmpty {
            let profiles = await UserProfileCache.shared.profiles(uids: soloUids)
            let profilesByUid = Dictionary(uniqueKeysWithValues: profiles.map { ($0.uid, $0) })
            soloEntries = await withTaskGroup(of: LiveNowEntry?.self) { group in
                for uid in soloUids {
                    group.addTask { [presenceService] in
                        guard let nowPlaying = await presenceService.getNowPlayingOnce(uid: uid),
                              nowPlaying.isPlaying, let profile = profilesByUid[uid] else { return nil }
                        return LiveNowEntry(
                            uid: uid, username: profile.username,
                            avatarEmoji: profile.avatarEmoji, avatarColor: profile.avatarColor,
                            kind: .listening(catalogId: nowPlaying.catalogId, isPreviewPlayback: nowPlaying.isPreviewPlayback)
                        )
                    }
                }
                var results: [LiveNowEntry] = []
                for await entry in group { if let entry { results.append(entry) } }
                return results
            }
        }

        let partyEntries = liveParties.map {
            LiveNowEntry(
                uid: $0.hostUid, username: $0.hostUsername,
                avatarEmoji: $0.hostAvatarEmoji, avatarColor: $0.hostAvatarColor,
                kind: .hostingParty($0)
            )
        }
        return partyEntries + soloEntries
    }

    // MARK: - Follow graph (for People-mode results)

    func loadFollowing(myUid: String) async {
        let entries = (try? await getFollowedEntries(uid: myUid)) ?? []
        followingUids = Set(entries.map { $0.uid })
    }

    func toggleFollow(myUid: String, myUsername: String, targetUser: UserProfile) async {
        if followingUids.contains(targetUser.uid) {
            followingUids.remove(targetUser.uid)
            do { try await unfollowUser(myUid: myUid, targetUid: targetUser.uid) }
            catch { followingUids.insert(targetUser.uid) }
        } else {
            followingUids.insert(targetUser.uid)
            do { try await followUser(myUid: myUid, myUsername: myUsername, targetUid: targetUser.uid, targetUsername: targetUser.username) }
            catch { followingUids.remove(targetUser.uid) }
        }
    }

    // MARK: - Search execution

    /// Kick off a search. Reads the current `mode` / `scope` / `query`
    /// snapshot. Called from `.onChange` of any of those.
    ///
    /// `debounce`: `true` (default) for query text changes — the 150 ms
    /// sleep lets the user keep typing without spamming the backend.
    /// `false` for a mode/scope tap — that's already a single, deliberate
    /// action with nothing more coming, so waiting out a debounce meant for
    /// "might still be typing" only adds pure, avoidable lag to a button
    /// tap.
    func search(via service: any MusicService, debounce: Bool = true) {
        searchTask?.cancel()
        genreTask?.cancel()
        genreChartName = nil
        lastSearchErrorDetail = nil
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else {
            userResults = []
            results     = .empty
            return
        }
        let currentMode  = mode
        let currentScope = scope
        completionTask?.cancel()
        searchTask = Task {
            if debounce {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
            }
            isSearching = true
            defer { isSearching = false }
            await perform(query: q, mode: currentMode, scope: currentScope, service: service)
        }
    }

    /// Clears the input and any cached results. Used by the Cancel button
    /// in the search bar.
    func clear() {
        searchTask?.cancel()
        genreTask?.cancel()
        genreChartName = nil
        query       = ""
        userResults = []
        results     = .empty
    }

    // MARK: - Genre charts (browse-state genre tiles)

    /// Shows a genuinely genre-scoped chart of songs, bypassing free-text
    /// search entirely — the fix for genre tiles returning whatever's
    /// merely popular under a keyword match (e.g. "Rock" surfacing a
    /// top-charting pop artist) rather than anything actually in that
    /// genre. Apple-only: `AppleMusicService.getGenreChartSongs` is a
    /// concrete-service method, not part of `MusicService`, mirroring
    /// `loadBrowseContent`'s existing precedent for `getPopularAlbums`.
    func showGenreChart(_ genreName: String, musicService: AppleMusicService) {
        searchTask?.cancel()
        genreTask?.cancel()
        lastSearchErrorDetail = nil
        genreChartName = genreName
        if let hit = genreChartCache[genreName.lowercased()], Date().timeIntervalSince(hit.at) < Self.genreChartTTL {
            genreChartTracks = hit.songs
            isSearching = false
            return
        }
        genreChartTracks = []
        isSearching = true
        genreTask = Task {
            defer { isSearching = false }
            let songs = await musicService.getGenreChartSongs(genreName: genreName, limit: 25)
            guard !Task.isCancelled else { return }
            let items = songs.map(Self.songToSearchItem)
            genreChartTracks = items
            if !items.isEmpty { genreChartCache[genreName.lowercased()] = (items, Date()) }
        }
    }

    /// Dismisses the genre chart back to the normal browse state.
    func exitGenreChart() {
        genreTask?.cancel()
        genreChartName = nil
        genreChartTracks = []
    }

    // MARK: - Private

    private func perform(
        query: String,
        mode: SearchMode,
        scope: MusicSearchScope,
        service: any MusicService
    ) async {
        switch mode {
        case .people:
            // People mode: only Nodalong user search. No catalog calls.
            let fetched = (try? await searchUsers(query: query)) ?? []
            // A stale search (superseded by a later keystroke, but whose
            // network call kept running rather than actually being
            // interrupted — Task cancellation only reliably stops OUR OWN
            // code, not necessarily a request already handed off to
            // Firestore/MusicKit) must not overwrite whatever the CURRENT
            // search has already shown. Without this check, results could
            // visibly flicker backward to an older query's answer while
            // typing, which reads as the whole search feature being slow
            // or broken even when each individual request was fine.
            guard !Task.isCancelled else { return }
            userResults = fetched
            results     = .empty

        case .music:
            // Music mode: clear user results, fan out to the relevant Apple
            // Music endpoints based on scope.
            userResults = []
            guard service.isAuthenticated else {
                results = .empty
                return
            }
            // Session cache: backspacing, retyping or returning to a query is
            // instant instead of another round trip.
            let cacheKey = "\(service.serviceType.rawValue)|\(scope.rawValue)|\(query.lowercased())"
            if let hit = resultCache[cacheKey], Date().timeIntervalSince(hit.at) < Self.resultCacheTTL {
                resultsQuery = query
                results = hit.results
                FieldLog.event("search", "\(scope.rawValue) cache=hit")
                return
            }
            if scope == .all { startArtistCompletions(query: query, cacheKey: cacheKey, service: service) }
            let started = Date()
            let fetched = await fetchMusic(query: query, scope: scope, service: service)
            guard !Task.isCancelled else { return }
            // Numbers only — never the query text (the field log's privacy contract).
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let hitCount = fetched.artists.count + fetched.albums.count + fetched.tracks.count
            FieldLog.event("search", "\(scope.rawValue) took \(ms)ms hits=\(hitCount) cache=miss")
            if hitCount > 0 {
                resultCache[cacheKey] = (fetched, Date())
                if resultCache.count > Self.resultCacheLimit {
                    for key in resultCache.sorted(by: { $0.value.at < $1.value.at }).prefix(resultCache.count - Self.resultCacheLimit).map(\.key) {
                        resultCache[key] = nil
                    }
                }
            }
            resultsQuery = query
            results = fetched
            // Completions that landed before the main results are merged now.
            applyExtraArtists(for: query, cacheKey: cacheKey)
        }
    }

    // MARK: - Artists while still typing

    /// Names the local prefix matcher draws from (your Shelf artists); set by
    /// `SearchView`. Recent artist searches are added automatically.
    var localArtistCandidates: [String] = []

    private var completionTask: Task<Void, Never>?
    private var extraArtists: [String: [ArtistResult]] = [:]

    /// Starts, alongside the main request, two ways of finding the artist for a
    /// half-typed query: your own artists that the text could be heading towards
    /// (instant when already resolved), and Apple's suggestions endpoint. They
    /// merge into the list whenever they land — never delaying the main results.
    private func startArtistCompletions(query: String, cacheKey: String, service: any MusicService) {
        guard let apple = service as? AppleMusicService,
              query.trimmingCharacters(in: .whitespaces).count >= 3 else { return }
        completionTask?.cancel()
        let candidates = localArtistCandidates
            + recentSearches.filter { $0.kind == .artist }.map(\.displayName)
        let local = localArtistMatches(query: query, candidates: candidates, weights: taste, limit: 2)
        completionTask = Task { [weak self] in
            async let remote = apple.artistCompletions(for: query)
            var resolvedLocal: [ArtistResult] = []
            for name in local {
                // Through the persistent name cache: free after the first time.
                if let r = await MusicDetailCache.shared.resolveArtistByName(name, fetch: {
                    let found = try? await apple.searchAll(name, maxPerType: 1)
                    return found?.artists.first
                }) { resolvedLocal.append(r) }
            }
            let remoteArtists = await remote
            guard !Task.isCancelled else { return }
            await self?.finishCompletions(query: query, cacheKey: cacheKey, local: resolvedLocal, remote: remoteArtists)
        }
    }

    private func finishCompletions(query: String, cacheKey: String, local: [ArtistResult], remote: [ArtistResult]) {
        // Numbers only — never the query text (the field log's privacy contract).
        FieldLog.event("search", "artist via local=\(local.count) suggestions=\(remote.count) main=\(results.artists.count)")
        extraArtists[query.lowercased()] = mergingArtists(local, into: remote)
        if extraArtists.count > 20 { extraArtists = [query.lowercased(): extraArtists[query.lowercased()] ?? []] }
        applyExtraArtists(for: query, cacheKey: cacheKey)
    }

    private func applyExtraArtists(for query: String, cacheKey: String) {
        guard resultsQuery == query, let extra = extraArtists[query.lowercased()], !extra.isEmpty else { return }
        let merged = mergingArtists(extra, into: results.artists)
        guard merged.count != results.artists.count else { return }
        results = CombinedSearchResults(artists: merged, albums: results.albums, tracks: results.tracks)
        resultCache[cacheKey] = (results, Date())
    }

    /// Per-scope dispatcher. `.all` runs the multi-type request; the others
    /// hit a single-type endpoint so we don't pay for data we'll discard.
    /// Each branch catches MusicKit errors and prints them so the user can
    /// see the real cause in the Xcode console when a search returns empty
    /// despite an obviously-popular query.
    private func fetchMusic(
        query: String,
        scope: MusicSearchScope,
        service: any MusicService
    ) async -> CombinedSearchResults {
        switch scope {
        case .all:
            do {
                let raw = try await service.searchAll(query, maxPerType: 12)
                return CombinedSearchResults(
                    artists: raw.artists,
                    albums:  raw.albums,
                    tracks:  raw.tracks.map(Self.songToSearchItem)
                )
            } catch {
                if !Self.isCancellation(error) {
                    debugLog("[Nodalong.Search] searchAll('\(query)') failed: \(error)")
                    lastSearchErrorDetail = Self.errorDetail(error)
                }
                return .empty
            }

        case .artists:
            do {
                let artists = try await service.searchArtists(query, maxResults: 25)
                return CombinedSearchResults(artists: artists, albums: [], tracks: [])
            } catch {
                if !Self.isCancellation(error) {
                    debugLog("[Nodalong.Search] searchArtists('\(query)') failed: \(error)")
                    lastSearchErrorDetail = Self.errorDetail(error)
                }
                return .empty
            }

        case .albums:
            do {
                let albums = try await service.searchAlbums(query, maxResults: 25)
                return CombinedSearchResults(artists: [], albums: albums, tracks: [])
            } catch {
                if !Self.isCancellation(error) {
                    debugLog("[Nodalong.Search] searchAlbums('\(query)') failed: \(error)")
                    lastSearchErrorDetail = Self.errorDetail(error)
                }
                return .empty
            }

        case .songs:
            do {
                let songs = try await service.searchTracks(query, maxResults: 25)
                return CombinedSearchResults(
                    artists: [],
                    albums:  [],
                    tracks:  songs.map(Self.songToSearchItem)
                )
            } catch {
                if !Self.isCancellation(error) {
                    debugLog("[Nodalong.Search] searchTracks('\(query)') failed: \(error)")
                    lastSearchErrorDetail = Self.errorDetail(error)
                }
                return .empty
            }
        }
    }

    /// Extracts a human-readable message from a caught error — prefers
    /// `LocalizedError.errorDescription` (both `SpotifyServiceError` and
    /// `AppleMusicServiceError` provide one) and falls back to the raw
    /// description for anything else. Mirrors
    /// `PlayerViewModel.lastPlaybackErrorDetail`'s existing convention.
    private static func errorDetail(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    /// `true` for the benign "request cancelled" errors produced when a newer
    /// keystroke supersedes an in-flight debounced search. These are expected,
    /// not failures, so they shouldn't reach the console.
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    /// Converts a `Song` (returned by MusicService) into a `SearchItem`
    /// (consumed by the SearchView row). Pulled out so the conversion
    /// happens in exactly one place.
    private static func songToSearchItem(_ song: Song) -> SearchItem {
        SearchItem(
            key:              "track:\(song.trackId)",
            title:            song.title,
            artist:           song.artist,
            album:            song.album,
            artwork:          song.artwork,
            uri:              song.uri,
            catalogId:        song.catalogId,
            isrc:             song.isrc,
            duration:         song.duration,
            trackNumber:      song.trackNumber,
            albumReleaseDate: song.albumReleaseDate,
            sourceService:    song.sourceService,
            isExplicit:       song.isExplicit,
            isPlayable:       song.isPlayable,
            releaseDate:      song.releaseDate,
            genres:           song.genres
        )
    }

    #if DEBUG
    fileprivate func applyMockPreviewState(users: [UserProfile]) {
        self.userResults = users
    }
    #endif
}

#if DEBUG
extension SearchViewModel {
    /// Search VM pre-populated with fixture user results for previews.
    static var mockPreview: SearchViewModel {
        let vm = SearchViewModel()
        vm.applyMockPreviewState(users: [PreviewFixtures.friendProfile])
        return vm
    }
}
#endif
