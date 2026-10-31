import Foundation
import NodalongKit

/// View model for the Home/Hub tab — the "for you" landing screen, distinct
/// from Feed (which is strictly about people you follow). Loads once per
/// session via `hasLoaded`, refreshed by pull-to-refresh, mirroring
/// `ProfileView`'s established guard pattern.
///
/// Stale-while-revalidate: `restoreSnapshotIfNeeded` populates every
/// `@Published` array synchronously from the last successful `load()`'s
/// persisted snapshot (`SnapshotStore`), so a relaunch renders real content
/// on the first frame instead of an empty screen. `load()` then refreshes
/// each section from the network — independently, not gated by source order
/// (see below) — and only replaces a section's data on success, so a flaky
/// refresh can never blank out what's already showing.
@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    /// True once a persisted snapshot has populated this screen — `HomeView`
    /// uses this (not `isLoading` alone) to decide whether a genuine
    /// first-ever launch needs skeleton placeholders.
    @Published private(set) var restoredFromSnapshot = false
    /// True while a load's results are being collected but not yet applied —
    /// see `beginBatch`. `HomeView` treats it like `isLoading` so a first-ever
    /// launch keeps its skeletons up until the single commit.
    @Published private(set) var isBatchOpen = false

    @Published private(set) var recentPosts: [Post] = []
    @Published private(set) var recentAlbums: [RecentAlbum] = []
    @Published private(set) var friendsSpotlights: [FriendSpotlight] = []
    @Published private(set) var recommendationShelves: [RecommendationShelf] = []
    /// The 10-group version "Recommended for You → See All" shows, warmed in
    /// the background once Home has loaded so that screen opens populated.
    /// Session-only and not snapshotted: it's a convenience, and the screen
    /// fetches for itself when this is empty.
    @Published private(set) var allRecommendationShelves: [RecommendationShelf] = []
    @Published private(set) var madeForYouPlaylists: [PlaylistResult] = []
    @Published private(set) var liveNow: [LiveNowEntry] = []
    /// Latest releases from the artists in the user's own Shelf. Loaded by
    /// `loadNewReleases` rather than as a sixth child of `load()` — it needs
    /// the Shelf's artist list, which belongs to `LibraryViewModel`, so it
    /// genuinely can't start until that has landed.
    @Published private(set) var newReleases: [AlbumResult] = []
    /// Apple's editorial "New Music Daily", as albums. Same for everyone —
    /// the non-personal counterpart to `newReleases`.
    @Published private(set) var newMusicDaily: [AlbumResult] = []
    /// Apple's chart for the listener's own city. Empty wherever Apple
    /// doesn't publish one, which is normal — the section hides itself.
    /// Chart sections whose contents genuinely changed since the last launch.
    ///
    /// 🔴 `HomeView` used to treat the chart rails as fresh whenever they were
    /// merely non-empty — which is always. Fresh sections sort above EVERY
    /// non-fresh one regardless of `baseRank`, so two Apple chart rails sat
    /// permanently above Live Now and Jump Back In on any day the user's
    /// follows were quiet: the exact inversion `baseRank` exists to prevent,
    /// and the doc comment on `freshSections` stated the rule the code broke.
    @Published private(set) var freshCharts: Set<HomeSectionID> = []

    /// What each chart held last launch, captured once at snapshot restore and
    /// thereafter only read. Absent on a cold launch with no snapshot, which
    /// deliberately reads as NOT fresh: a brand-new account should not have
    /// charts pushed above its own listening just because it has never seen
    /// them before.
    private var previousChartIds: [HomeSectionID: Set<String>] = [:]

    @Published private(set) var cityChartSongs: [Song] = []
    /// Apple's chart for the user's own most-listened genre, plus that
    /// genre's name for the section heading.
    @Published private(set) var genreChartSongs: [Song] = []
    @Published private(set) var genreChartName: String = ""
    /// Apple's own recently-played containers — albums and playlists,
    /// including listening that happened outside Nodalong.
    @Published private(set) var recentlyPlayedAlbums: [AlbumResult] = []
    @Published private(set) var recentlyPlayedPlaylists: [PlaylistResult] = []

    private let presenceService = UserPresenceService()

    /// What gets persisted/restored across launches. `liveNow` is
    /// deliberately excluded — it's a live "who's online right now" signal
    /// and would be actively misleading if shown stale. "Recently Added" is
    /// ALSO excluded — it used to be an Apple-Music-library fetch owned by
    /// this VM, but is now derived directly from `LibraryViewModel.tracks`
    /// (Nodalong's own Shelf) at the View layer, so there's nothing here to
    /// snapshot for it.
    private struct HomeSnapshot: Codable {
        var recentPosts: [Post]
        var friendsSpotlights: [FriendSpotlight]
        var recommendationShelves: [RecommendationShelf]
        var madeForYouPlaylists: [PlaylistResult]
        /// Optional so a snapshot written before this field existed still
        /// decodes. `SnapshotStore.load` swallows a decode failure with
        /// `try?`, so a required new key would silently turn every launch
        /// back into a cold network load with no signal — the exact trap
        /// this codebase has already been bitten by on `CatalogTrack`.
        var newReleases: [AlbumResult]?
        var newMusicDaily: [AlbumResult]?
        var cityChartSongs: [Song]?
        var genreChartSongs: [Song]?
        var genreChartName: String?
        var recentlyPlayedAlbums: [AlbumResult]?
        var recentlyPlayedPlaylists: [PlaylistResult]?
    }

    private func restoreSnapshotIfNeeded(uid: String) {
        guard !hasLoaded, recentPosts.isEmpty else { return }
        // TEMPORARY DIAGNOSTIC — the whole stale-while-revalidate design rests
        // on this restore succeeding. `SnapshotStore.load` swallows a decode
        // failure with `try?`, so a model change that breaks decoding would
        // silently turn every launch back into a cold network load with no
        // visible signal. Log which way it went until that's confirmed.
        guard let snap = SnapshotStore.load(HomeSnapshot.self, key: "home", uid: uid) else {
            diagLog("HomeViewModel: snapshot MISS — cold network load this launch")
            return
        }
        diagLog("HomeViewModel: snapshot HIT — rendering \(snap.recentPosts.count) posts instantly")
        recentPosts = snap.recentPosts
        recentAlbums = NodalongKit.recentAlbums(from: snap.recentPosts)
        friendsSpotlights = snap.friendsSpotlights
        recommendationShelves = snap.recommendationShelves
        madeForYouPlaylists = snap.madeForYouPlaylists
        newReleases = snap.newReleases ?? []
        newMusicDaily = snap.newMusicDaily ?? []
        cityChartSongs = snap.cityChartSongs ?? []
        genreChartSongs = snap.genreChartSongs ?? []
        genreChartName = snap.genreChartName ?? ""
        recentlyPlayedAlbums = snap.recentlyPlayedAlbums ?? []
        recentlyPlayedPlaylists = snap.recentlyPlayedPlaylists ?? []
        // What the user saw LAST launch, kept only to compare the incoming
        // network result against — see `noteChartFreshness`.
        previousChartIds[.cityCharts]  = Set(cityChartSongs.map(\.uri))
        previousChartIds[.genreCharts] = Set(genreChartSongs.map(\.uri))
        restoredFromSnapshot = true
    }

    private func persistSnapshot(uid: String) {
        SnapshotStore.save(
            HomeSnapshot(
                recentPosts: recentPosts,
                friendsSpotlights: friendsSpotlights,
                recommendationShelves: recommendationShelves,
                madeForYouPlaylists: madeForYouPlaylists,
                newReleases: newReleases,
                newMusicDaily: newMusicDaily,
                cityChartSongs: cityChartSongs,
                genreChartSongs: genreChartSongs,
                genreChartName: genreChartName,
                recentlyPlayedAlbums: recentlyPlayedAlbums,
                recentlyPlayedPlaylists: recentlyPlayedPlaylists
            ),
            key: "home", uid: uid
        )
    }

    /// Every section fetch is independent, EXCEPT the `followingUids`-
    /// dependent pair (spotlights + live now), which is a genuine barrier —
    /// it can't start until the following-list fetch resolves. Each section
    /// now assigns its `@Published` property the instant ITS OWN fetch
    /// lands, inside its own task-group child — not gated by the fixed
    /// source order the old `async let` sequence awaited in, so a fast
    /// section (e.g. Top Charts) can render before a slow one (e.g.
    /// Recommendations) instead of waiting behind it. Every assignment is
    /// success-gated (`try?` / `guard let`) so a failed refresh never blanks
    /// out content a snapshot or a prior load already rendered.
    /// Assigns only when the value actually changed.
    ///
    /// `@Published` fires `objectWillChange` on EVERY assignment, equal or
    /// not — so a refresh that returns byte-identical data still forces a
    /// re-render. That's what made Home visibly "load twice": the snapshot
    /// paints instantly, then each of the 5 network tasks reassigns its own
    /// section as it lands (plus `refreshOwnRecents` again when the launch
    /// sync completes), and on a typical launch most of that data hasn't
    /// changed at all. Guarding on equality makes the no-change case
    /// invisible while a genuine change still comes through immediately.
    ///
    /// Free to do — every model here is already `Hashable`.
    private func set<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<HomeViewModel, T>, _ new: T) {
        guard self[keyPath: keyPath] != new else { return }
        self[keyPath: keyPath] = new
    }

    // MARK: Batched commit
    //
    // Home used to apply each section the instant ITS fetch landed. With the
    // last launch's snapshot already on screen, that meant the page visibly
    // rearranged itself a few times in the first seconds — Jump Back In
    // gaining its second half, rails swapping contents, and sections
    // re-sorting between "fresh" and not as each landed (a section could jump
    // position). Now fetches STAGE a commit instead, and everything is
    // applied together in one MainActor turn: one re-render, one set of
    // changes, section order decided once.
    //
    // The snapshot stays on screen until then. A hard deadline stops one slow
    // source from holding the others back forever; anything arriving after it
    // applies on arrival, as before.

    private var stagedCommits: [@MainActor () -> Void] = []
    private var batchDeadline: Task<Void, Never>?
    private var batchUid: String?

    /// Opens a commit window. Pair with `commitBatch()`.
    func beginBatch(uid: String, deadline: TimeInterval = 4) {
        // A second load starting while one is mid-flight joins the open
        // window rather than discarding what the first has already staged.
        guard !isBatchOpen else { return }
        stagedCommits = []
        batchUid = uid
        isBatchOpen = true
        batchDeadline?.cancel()
        batchDeadline = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
            guard !Task.isCancelled else { return }
            diagLog("HomeViewModel: batch deadline hit — committing what has landed")
            self?.commitBatch()
        }
    }

    /// Applies everything staged since `beginBatch`, then persists the
    /// snapshot. Safe to call twice (the deadline and the normal path race).
    func commitBatch() {
        batchDeadline?.cancel()
        batchDeadline = nil
        guard isBatchOpen else { return }
        isBatchOpen = false
        let commits = stagedCommits
        stagedCommits = []
        for commit in commits { commit() }
        if let uid = batchUid { persistSnapshot(uid: uid) }
    }

    /// Applies `commit` now if no window is open (a late arrival, or a
    /// refresh outside a load), otherwise holds it for `commitBatch`.
    private func stage(_ commit: @escaping @MainActor () -> Void) {
        if isBatchOpen {
            stagedCommits.append(commit)
        } else {
            commit()
            if let uid = batchUid { persistSnapshot(uid: uid) }
        }
    }

    func load(uid: String, musicService: AppleMusicService) async {
        guard !isLoading else { return }
        isLoading = true
        restoreSnapshotIfNeeded(uid: uid)
        diagLog("HomeViewModel.load: start")
        let t0 = Date()
        defer {
            isLoading = false
            hasLoaded = true
            diagLog("HomeViewModel.load: ALL tasks done in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
        }

        let canPersonalize = musicService.canPlayFullTracks

        // Unstructured `Task { @MainActor in ... }` children, collected and
        // awaited together, rather than `TaskGroup.addTask { @MainActor in }`
        // — the latter compiles but emits a "sending closure" data-race
        // warning under strict concurrency (each child closure captures
        // `self`/`musicService` across the group's isolation boundary in a
        // way the region-based checker flags as a future Swift 6 error).
        // This form sidesteps that entirely: each `Task` is independently
        // MainActor-isolated from creation, so there's no boundary to cross.
        let tasks: [Task<Void, Never>] = [
            Task { @MainActor [weak self] in
                let t = Date()
                guard let posts = try? await getYourMusicFeed(uid: uid) else { return }
                let albums = NodalongKit.recentAlbums(from: posts)
                self?.stage { [weak self] in
                    self?.set(\.recentPosts, posts)
                    self?.set(\.recentAlbums, albums)
                }
                diagLog("HomeViewModel.load: getYourMusicFeed \(Int(Date().timeIntervalSince(t) * 1000))ms")
            },
            Task { @MainActor [weak self] in
                let t = Date()
                guard canPersonalize,
                      let shelves = try? await musicService.getPersonalRecommendations(maxGroups: 5)
                else { return }
                self?.stage { [weak self] in self?.set(\.recommendationShelves, shelves) }
                diagLog("HomeViewModel.load: getPersonalRecommendations \(Int(Date().timeIntervalSince(t) * 1000))ms")
                self?.warmAllRecommendations(musicService: musicService)
            },
            Task { @MainActor [weak self] in
                let t = Date()
                guard canPersonalize,
                      let lists = try? await musicService.getMadeForYouPlaylists(maxGroups: 5)
                else { return }
                self?.stage { [weak self] in self?.set(\.madeForYouPlaylists, lists) }
                diagLog("HomeViewModel.load: getMadeForYouPlaylists \(Int(Date().timeIntervalSince(t) * 1000))ms")
            },
            Task { @MainActor [weak self] in
                let t = Date()
                let songs = await musicService.getCityChartSongs(limit: 10)
                self?.stage { [weak self] in
                    self?.noteChartFreshness(.cityCharts, songs)
                    self?.set(\.cityChartSongs, songs)
                }
                diagLog("HomeViewModel.load: getCityChartSongs \(songs.count) in \(Int(Date().timeIntervalSince(t) * 1000))ms")
            },
            Task { @MainActor [weak self] in
                let t = Date()
                let containers = await musicService.getRecentlyPlayedContainers()
                self?.stage { [weak self] in
                    self?.set(\.recentlyPlayedAlbums, containers.albums)
                    self?.set(\.recentlyPlayedPlaylists, containers.playlists)
                }
                diagLog("HomeViewModel.load: recentlyPlayedContainers \(containers.albums.count) albums / \(containers.playlists.count) playlists in \(Int(Date().timeIntervalSince(t) * 1000))ms")
            },
            Task { @MainActor [weak self] in
                // Genuine barrier: both depend on followingUids, so they
                // can't start until it resolves — but are independent of
                // each other, so still run concurrently once unblocked.
                let t = Date()
                let followingUids = await FollowingCache.shared.following(uid: uid).map(\.uid)
                diagLog("HomeViewModel.load: FollowingCache.following \(Int(Date().timeIntervalSince(t) * 1000))ms")
                async let spotlightsResult = getFriendsSpotlightsToday(followingUids: followingUids)
                let live = await self?.loadLiveNow(followingUids: followingUids) ?? []
                let spotlights = try? await spotlightsResult
                self?.stage { [weak self] in
                    if let spotlights { self?.set(\.friendsSpotlights, spotlights) }
                    self?.set(\.liveNow, live)
                }
                diagLog("HomeViewModel.load: spotlights+liveNow \(Int(Date().timeIntervalSince(t) * 1000))ms")
            },
            Task { @MainActor [weak self] in
                let t = Date()
                // nil = couldn't load: keep what's showing.
                guard let albums = await musicService.getNewMusicDaily() else { return }
                self?.stage { [weak self] in self?.set(\.newMusicDaily, albums) }
                diagLog("HomeViewModel.load: getNewMusicDaily \(albums.count) in \(Int(Date().timeIntervalSince(t) * 1000))ms")
            }
        ]
        for task in tasks { await task.value }
    }

    /// Latest releases from the artists in the user's own Shelf.
    ///
    /// Separate from `load()` because it genuinely depends on another view
    /// model: the artist list comes from `LibraryViewModel`, so this can't
    /// start until that has landed. Folding it in as a sixth task-group
    /// child would either block on the library fetch inside `load()` (which
    /// would defeat the whole point of those children being independent) or
    /// run against an empty artist list on a cold launch.
    ///
    /// `savedAlbumKeys` are `AlbumGroup.key` values from the user's Shelf.
    /// A release the user has already saved is not news, so it's filtered
    /// out — matched by rebuilding `groupByAlbum`'s own key from the
    /// release's title so the two agree by construction rather than by two
    /// separate normalisation rules drifting apart.
    func loadNewReleases(
        shelfArtists: [String],
        savedAlbumKeys: Set<String>,
        musicService: AppleMusicService
    ) async {
        guard !shelfArtists.isEmpty else { return }
        // nil = the request failed: keep whatever is showing. An EMPTY result
        // is real information and must clear a stale rail — this used to
        // `return` on empty, so a restored snapshot could never go away.
        guard let releases = await musicService.getNewReleases(fromArtists: shelfArtists) else { return }
        let unsaved = releases.filter {
            !savedAlbumKeys.contains(Self.shelfAlbumKey(for: $0.name))
                && !savedAlbumKeys.contains(Self.shelfAlbumKey(for: canonicalAlbumTitle($0.name)))
        }
        stage { [weak self] in self?.set(\.newReleases, unsaved) }
    }

    /// Apple's chart for the user's own most-listened genre.
    ///
    /// Sequenced with `loadNewReleases` for the same reason: the genre comes
    /// from `LibraryViewModel.genreEntries`, so it can't start until the
    /// library has landed. Genre has been captured on every track at ingest
    /// since August but until now only fed one Shelf grouping.
    func loadGenreChart(genreName: String, musicService: AppleMusicService) async {
        guard !genreName.isEmpty else { return }
        let songs = await musicService.getGenreChartSongs(genreName: genreName, limit: 10)
        guard !songs.isEmpty else { return }
        stage { [weak self] in
            self?.noteChartFreshness(.genreCharts, songs)
            self?.set(\.genreChartSongs, songs)
            self?.set(\.genreChartName, genreName)
        }
    }

    /// Marks a chart section fresh only if its contents actually differ from
    /// what the previous launch showed.
    ///
    /// Compares by `uri` — every catalog song has one, and a chart is an
    /// ordered list of catalog songs. Membership rather than order, so a
    /// reshuffle of the same ten tracks is correctly NOT news.
    private func noteChartFreshness(_ id: HomeSectionID, _ songs: [Song]) {
        let ids = Set(songs.map(\.uri))
        let changed = previousChartIds[id].map { !$0.isEmpty && ids != $0 } ?? false
        if changed { freshCharts.insert(id) } else { freshCharts.remove(id) }
    }

    /// Album identity for the "do I already own this?" check, delegating to
    /// the shared `albumMatchKey` so it cannot drift from `groupByAlbum`'s
    /// own grouping — it used to restate that keying inline, and a dedup that
    /// silently stops agreeing with the grouping it mirrors is exactly the
    /// failure this indirection exists to prevent.
    ///
    /// Checked twice by the caller — once on the raw title and once on
    /// `canonicalAlbumTitle` — so a reissue ("Blonde (10th Anniversary
    /// Edition)") is recognised as an album the user already owns rather
    /// than announced as news. `stripSearchNoise` alone doesn't strip
    /// edition suffixes; that's `canonicalAlbumTitle`'s job.
    private static func shelfAlbumKey(for albumName: String) -> String {
        albumMatchKey(albumName)
    }

    /// Refreshes ONLY what a completed library sync can actually change: the
    /// user's own recent tracks (Jump Back In). The full `load()` used to
    /// run here (`HomeView`'s `.onChange(of: syncService.lastSyncedAt)`),
    /// which meant Home did its entire 5-task network load a SECOND time on
    /// every cold launch — re-fetching both MusicKit recommendation
    /// requests, Top Charts, the following list, spotlights and Live Now —
    /// roughly 3s of contended work for data none of that touches.
    func refreshOwnRecents(uid: String) async {
        guard let posts = try? await getYourMusicFeed(uid: uid) else { return }
        let albums = NodalongKit.recentAlbums(from: posts)
        batchUid = uid
        stage { [weak self] in
            self?.set(\.recentPosts, posts)
            self?.set(\.recentAlbums, albums)
        }
    }

    /// Re-checks personalized recommendations (albums + Made For You
    /// playlists) if the initial `load()` lost the race against
    /// `AppleMusicService`'s subscription observer (`subscription` is `nil`
    /// for a moment after launch, so `canPlayFullTracks` can read `false`
    /// for a real subscriber at the exact instant Home's `.task` fires).
    /// Only does anything if both are still empty — a no-op once populated.
    /// Fetches the See All screen's larger set after a pause, so it never
    /// competes with Home's own first load or its tiles' prefetches. A
    /// separate request rather than fetching 10 groups up front: Home's rail
    /// and Made For You share the 5-group request, and asking for more there
    /// would change what Home shows.
    private func warmAllRecommendations(musicService: AppleMusicService) {
        guard allRecommendationShelves.isEmpty else { return }
        Task(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let all = try? await musicService.getPersonalRecommendations(maxGroups: 10), !all.isEmpty else { return }
            self?.allRecommendationShelves = all
        }
    }

    func refreshPersonalizedContentIfNeeded(musicService: AppleMusicService) async {
        guard recommendationShelves.isEmpty, madeForYouPlaylists.isEmpty, musicService.canPlayFullTracks else { return }
        do {
            set(\.recommendationShelves, try await musicService.getPersonalRecommendations(maxGroups: 5))
            set(\.madeForYouPlaylists, try await musicService.getMadeForYouPlaylists(maxGroups: 5))
        } catch {
            debugLog("[Nodalong.Home] personalized recommendations failed: \(error)")
        }
    }

    /// Combines two structurally different data sources into one "who's live
    /// right now" list: hosted parties (batched Firestore query, shared with
    /// Feed's party-discovery banner via `FollowingCache` so both don't each
    /// pay for the same read) and solo listening presence (one-time RTDB
    /// read per followed uid — no persistent observers, matching this VM's
    /// load-once/pull-to-refresh convention). A followed user hosting a
    /// party is only ever shown as hosting, not double-counted as also
    /// "listening solo."
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
}

#if DEBUG
extension HomeViewModel {
    /// Sets preview-only mock state directly, bypassing `load(uid:musicService:)`
    /// (which would hit Firestore/MusicKit — unavailable in the preview sandbox).
    func applyMockPreviewState(recentPosts: [Post]) {
        self.recentPosts = recentPosts
        self.hasLoaded = true
    }

    static var mockPreview: HomeViewModel {
        let vm = HomeViewModel()
        vm.applyMockPreviewState(recentPosts: PreviewFixtures.posts)
        return vm
    }
}
#endif
