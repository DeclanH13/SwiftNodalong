import Foundation
import NodalongKit

/// The Following feed — the social heart of the app.
///
/// Aggregates `Post`s from every user the current user follows: tap-to-play
/// in-app, attribution to the source user, and a nod-counter that increments
/// when you play a track *they* surfaced. Spotlight tracks from followed
/// users appear inline with gold styling, treated as in-feed recommendations
/// rather than separated.
///
/// **There is no longer a "Your Music" filter.** Your own recent listens
/// live on your Profile (which is itself "the music you've been listening to,
/// for yourself"). The Feed is purely "what your follows are listening to."
///
/// Reads: `getFollowingFeed` in API/Firestore.
/// Drives: FeedView's list. Tap → `PlayerViewModel.play()` + `tryNod()`.
@MainActor
final class FeedViewModel: ObservableObject {
    @Published private(set) var posts:    [Post] = [] { didSet { PublishCounter.bump("feed.posts"); recomputeDerived() } }
    @Published private(set) var isLoading       = false

    /// Album-level: people you follow, ranked by how many of them played
    /// something from this album. Home shows the top 10; the see-all screen
    /// shows them all, so this is published uncapped.
    @Published private(set) var friendsListeningAlbums: [FriendsListeningAlbum] = []

    /// Track-level: the most-nodded tracks among people you follow in the
    /// last 7 days. Same source as above, different aggregation.
    @Published private(set) var mostNoddedThisWeek: [Post] = []

    /// Derived once per change to `posts`, never from a view body.
    ///
    /// Both aggregations build dictionaries and sort over the whole feed —
    /// up to 100 posts — and `HomeView` read them from computed properties,
    /// so each ran TWICE per render there (once for the section-availability
    /// check, once for the section body) plus a third time uncapped on the
    /// see-all screen. `HomeView` observes nine app-wide objects, so a
    /// `isPlaying` toggle was re-aggregating the entire feed four times.
    ///
    /// A `didSet` rather than per-call-site memoisation for the same reason
    /// `LibraryViewModel.recomputeDerived()` uses one: `posts` is assigned or
    /// mutated in six places here (snapshot restore, load, refresh, and the
    /// optimistic nod bump plus its two rollbacks), and a `didSet` means none
    /// of them can forget.
    ///
    /// The 7-day cutoff is therefore evaluated when `posts` changes rather
    /// than per render. `posts` is reassigned on load, on pull-to-refresh and
    /// on foreground-return, so the window stays current in practice.
    private func recomputeDerived() {
        friendsListeningAlbums = NodalongKit.friendsListeningAlbums(from: posts)
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600).timeIntervalSince1970 * 1000
        mostNoddedThisWeek = NodalongKit.mostNoddedPosts(from: posts, since: cutoff, limit: 10)
    }

    /// Session-only set of `(nodder)_(source)_(track)` keys we've already
    /// awarded a nod for today. Backed by `nod_records/{nodder}_{source}_{track}_{day}`
    /// in Firestore for the cross-session, once-per-calendar-day guard, but
    /// this avoids hitting Firestore for repeat plays within one session.
    private var sessionNodSet: Set<String> = []

    /// Set once data has been loaded for the current session. Prevents
    /// redundant Firestore reads when `.task` re-fires on tab re-visit.
    /// Published (not just private) so `FeedView` can show a spinner instead
    /// of `emptyState` on its very first synchronous render — before
    /// `.task` has had a chance to flip `isLoading` — rather than a
    /// momentary blank-looking placeholder.
    @Published private(set) var hasLoaded = false

    /// Initial load. `myUid` is the *current* user's UID — used to query
    /// "users I follow" and to skip self-nods.
    /// Skips the fetch if already loaded — `refresh(myUid:)` forces a re-fetch.
    ///
    /// Stale-while-revalidate: if there's a persisted snapshot from the last
    /// successful load, it renders immediately (first frame shows real
    /// posts, not a spinner) while the network fetch refreshes silently
    /// underneath. A failed/empty refresh never blanks out what's already
    /// showing — `posts` only ever changes to a genuinely fresh, non-empty
    /// result (or to `[]` if it was already empty, so a real "you have no
    /// followed posts" state still renders correctly).
    func load(myUid: String? = nil) async {
        guard !isLoading, !hasLoaded else { return }
        diagLog("FeedViewModel.load: start")
        let t0 = Date()
        if posts.isEmpty, let uid = myUid {
            // TEMPORARY DIAGNOSTIC — see HomeViewModel.restoreSnapshotIfNeeded.
            if let snap = SnapshotStore.load([Post].self, key: "feedPosts", uid: uid) {
                diagLog("FeedViewModel: snapshot HIT — \(snap.count) posts instantly")
                posts = snap
            } else {
                diagLog("FeedViewModel: snapshot MISS — cold network load this launch")
            }
        }
        isLoading = posts.isEmpty
        defer { isLoading = false }
        let fresh = await fetchPosts(myUid: myUid)
        diagLog("FeedViewModel.load: fetchPosts returned \(fresh.count) in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
        if !fresh.isEmpty || posts.isEmpty { posts = fresh }
        if let uid = myUid { SnapshotStore.save(posts, key: "feedPosts", uid: uid) }
        hasLoaded = true
    }

    /// Pull-to-refresh + foreground-return refresh. Skips the loading flag
    /// so the UI doesn't flicker.
    func refresh(myUid: String? = nil) async {
        let fresh = await fetchPosts(myUid: myUid)
        if !fresh.isEmpty || posts.isEmpty { posts = fresh }
        if let uid = myUid { SnapshotStore.save(posts, key: "feedPosts", uid: uid) }
    }

    /// Called when a card is tapped to play. Awards a nod with session-level
    /// and backend dedup.
    /// - Session set prevents double-counting if the same card is tapped
    ///   twice before a refresh.
    /// - Backend `tryIncrementNod` is the authoritative guard (atomic
    ///   Firestore transaction); session set is the optimistic-UI shortcut.
    func tryNod(_ post: Post, nodderUid: String) async {
        guard let sourceUid = post.sourceUid, let trackId = post.trackId else { return }
        guard nodderUid != sourceUid else { return }

        let key = "\(nodderUid)_\(sourceUid)_\(trackId)"
        guard !sessionNodSet.contains(key) else { return }
        sessionNodSet.insert(key)

        guard let idx = posts.firstIndex(where: { $0.id == post.id }) else { return }
        posts[idx].nods += 1

        do {
            let wasNew = try await tryIncrementNod(nodderUid: nodderUid, sourceUid: sourceUid, trackId: trackId)
            if !wasNew {
                // Already nodded in a prior session — revert optimistic bump
                // but keep the session key to avoid retrying.
                posts[idx].nods = max(0, posts[idx].nods - 1)
            }
        } catch {
            // Network error — revert and drop session key so retry works on
            // next play.
            posts[idx].nods = max(0, posts[idx].nods - 1)
            sessionNodSet.remove(key)
        }
    }

    // MARK: - Private

    private func fetchPosts(myUid: String?) async -> [Post] {
        guard let uid = myUid else { return [] }
        return (try? await getFollowingFeed(myUid: uid)) ?? []
    }

    #if DEBUG
    fileprivate func applyMockPreviewState(posts: [Post]) {
        self.posts = posts
    }
    #endif
}

#if DEBUG
extension FeedViewModel {
    /// Feed VM pre-populated with fixture posts for previews.
    static var mockPreview: FeedViewModel {
        let vm = FeedViewModel()
        vm.applyMockPreviewState(posts: PreviewFixtures.posts)
        return vm
    }
}
#endif
