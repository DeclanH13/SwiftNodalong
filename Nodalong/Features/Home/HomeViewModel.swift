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

    @Published private(set) var recentPosts: [Post] = []
    @Published private(set) var recentAlbums: [RecentAlbum] = []
    @Published private(set) var friendsSpotlights: [FriendSpotlight] = []
    @Published private(set) var recommendationShelves: [RecommendationShelf] = []
    @Published private(set) var madeForYouPlaylists: [PlaylistResult] = []
    @Published private(set) var topChartSongs: [Song] = []
    @Published private(set) var liveNow: [LiveNowEntry] = []

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
        var topChartSongs: [Song]
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
        topChartSongs = snap.topChartSongs
        restoredFromSnapshot = true
    }

    private func persistSnapshot(uid: String) {
        SnapshotStore.save(
            HomeSnapshot(
                recentPosts: recentPosts,
                friendsSpotlights: friendsSpotlights,
                recommendationShelves: recommendationShelves,
                madeForYouPlaylists: madeForYouPlaylists,
                topChartSongs: topChartSongs
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

    func load(uid: String, musicService: AppleMusicService) async {
        guard !isLoading else { return }
        isLoading = true
        restoreSnapshotIfNeeded(uid: uid)
        diagLog("HomeViewModel.load: start")
        let t0 = Date()
        defer {
            isLoading = false
            hasLoaded = true
            persistSnapshot(uid: uid)
            diagLog("HomeViewModel.load: ALL 5 tasks done in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
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
                self?.set(\.recentPosts, posts)
                self?.set(\.recentAlbums, NodalongKit.recentAlbums(from: posts))
                diagLog("HomeViewModel.load: getYourMusicFeed \(Int(Date().timeIntervalSince(t) * 1000))ms")
            },
            Task { @MainActor [weak self] in
                let t = Date()
                guard canPersonalize,
                      let shelves = try? await musicService.getPersonalRecommendations(maxGroups: 5)
                else { return }
                self?.set(\.recommendationShelves, shelves)
                diagLog("HomeViewModel.load: getPersonalRecommendations \(Int(Date().timeIntervalSince(t) * 1000))ms")
            },
            Task { @MainActor [weak self] in
                let t = Date()
                guard canPersonalize,
                      let lists = try? await musicService.getMadeForYouPlaylists(maxGroups: 5)
                else { return }
                self?.set(\.madeForYouPlaylists, lists)
                diagLog("HomeViewModel.load: getMadeForYouPlaylists \(Int(Date().timeIntervalSince(t) * 1000))ms")
            },
            Task { @MainActor [weak self] in
                let t = Date()
                guard let songs = try? await musicService.getTopChartSongs(limit: 10) else { return }
                self?.set(\.topChartSongs, songs)
                diagLog("HomeViewModel.load: getTopChartSongs \(Int(Date().timeIntervalSince(t) * 1000))ms")
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
                if let spotlights = try? await spotlightsResult { self?.set(\.friendsSpotlights, spotlights) }
                self?.set(\.liveNow, live)
                diagLog("HomeViewModel.load: spotlights+liveNow \(Int(Date().timeIntervalSince(t) * 1000))ms")
            }
        ]
        for task in tasks { await task.value }
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
        set(\.recentPosts, posts)
        set(\.recentAlbums, NodalongKit.recentAlbums(from: posts))
        persistSnapshot(uid: uid)
    }

    /// Re-checks personalized recommendations (albums + Made For You
    /// playlists) if the initial `load()` lost the race against
    /// `AppleMusicService`'s subscription observer (`subscription` is `nil`
    /// for a moment after launch, so `canPlayFullTracks` can read `false`
    /// for a real subscriber at the exact instant Home's `.task` fires).
    /// Only does anything if both are still empty — a no-op once populated.
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
                            kind: .listening(catalogId: nowPlaying.catalogId)
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
