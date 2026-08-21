import Foundation
import NodalongKit

/// Everything `UserProfileView` needs beyond the `UserProfile` it was pushed
/// with, cached as one unit.
///
/// The identity half of a profile (avatar, username, bio) is already instant —
/// every push site passes a complete `UserProfile`. These five are what used
/// to arrive late and make the spotlight carousel and recents rail pop in.
struct ProfileBundle: Sendable {
    var recentTracks:     [Post]
    var spotlightHistory: [SpotlightTrack]
    var playlists:        [Playlist]
    var followerCount:    Int
    /// Viewer-relative, unlike the rest. Safe to cache per-target because the
    /// viewer is fixed for a session, and `followUser`/`unfollowUser`
    /// invalidate both parties (see `Follows.swift`).
    var isFollowing:      Bool

    static let empty = ProfileBundle(
        recentTracks: [], spotlightHistory: [], playlists: [],
        followerCount: 0, isFollowing: false
    )
}

/// Session cache for the *social* graph — profile detail bundles and
/// followers/following lists.
///
/// Mirrors `UserProfileCache`'s shape deliberately (TTL + in-flight sharing,
/// so concurrent callers join one fetch rather than duplicating it). The
/// point is that a real tap either lands on a completed warm entry or joins a
/// fetch already in progress — it can never start a duplicate.
///
/// **Not** a replacement for `FollowingCache`: that holds a single uid's
/// *following* list only, because it exists to serve Home and Feed reading
/// YOUR OWN graph. It can't answer "who follows this arbitrary person", which
/// is what the follow-list screen needs.
///
/// Session-only by design — no `SnapshotStore` persistence. Social data
/// (spotlights, follower counts, now-playing) goes stale fast, and showing a
/// day-old profile is worse than a brief load. Your own profile keeps its
/// disk snapshot (`ProfileView.ProfileSnapshot`); other people's do not.
actor SocialCache {
    static let shared = SocialCache()
    private init() {}

    private var bundles:     [String: (bundle: ProfileBundle, at: Date)] = [:]
    private var bundleTasks: [String: Task<ProfileBundle, Never>] = [:]

    /// Keyed `"<uid>:followers"` / `"<uid>:following"`.
    private var lists:     [String: (profiles: [UserProfile], at: Date)] = [:]
    private var listTasks: [String: Task<[UserProfile], Never>] = [:]

    private static func listKey(_ uid: String, _ mode: FollowListMode) -> String {
        "\(uid):\(mode == .followers ? "followers" : "following")"
    }

    // MARK: - Profile bundles

    /// Returns a cached bundle if fresh, joins an in-flight fetch if one is
    /// running, otherwise fetches. The five underlying calls run concurrently
    /// — same `async let` shape `UserProfileView.loadData()` already used.
    func bundle(uid: String, viewerUid: String, maxAge: TimeInterval = 120) async -> ProfileBundle {
        if let entry = bundles[uid], Date().timeIntervalSince(entry.at) < maxAge {
            return entry.bundle
        }
        if let existing = bundleTasks[uid] { return await existing.value }

        let task = Task { () -> ProfileBundle in
            async let tracks    = getYourMusicFeed(uid: uid)
            async let history   = getSpotlightHistory(uid: uid)
            async let playlists = getUserPlaylists(uid: uid)
            async let count     = getFollowerCount(uid: uid)
            async let follows   = isFollowing(myUid: viewerUid, targetUid: uid)
            return ProfileBundle(
                recentTracks:     (try? await tracks)  ?? [],
                spotlightHistory: (try? await history) ?? [],
                // Without security rules enforcing visibility yet, private
                // playlists are filtered client-side — same rule the view
                // applied before this moved here.
                playlists:        ((try? await playlists) ?? []).filter { $0.visibility != .private },
                followerCount:    (try? await count)   ?? 0,
                isFollowing:      (try? await follows) ?? false
            )
        }
        bundleTasks[uid] = task
        let value = await task.value
        bundles[uid] = (value, Date())
        bundleTasks[uid] = nil
        return value
    }

    /// Non-blocking peek — returns a bundle only if one is already cached and
    /// fresh. Lets a view paint a warm profile on its very first frame
    /// without awaiting anything.
    func cachedBundle(uid: String, maxAge: TimeInterval = 120) -> ProfileBundle? {
        guard let entry = bundles[uid], Date().timeIntervalSince(entry.at) < maxAge else { return nil }
        return entry.bundle
    }

    // MARK: - Follow lists

    /// Resolves the bare `(uid, username)` entries into full `UserProfile`s
    /// via the existing `UserProfileCache`, preserving the server's order and
    /// dropping any uid whose profile is missing (e.g. a deleted account)
    /// rather than rendering a blank row — identical semantics to the
    /// hand-rolled version this replaced in `FollowListView.load()`.
    func followList(uid: String, mode: FollowListMode, maxAge: TimeInterval = 60) async -> [UserProfile] {
        let key = Self.listKey(uid, mode)
        if let entry = lists[key], Date().timeIntervalSince(entry.at) < maxAge {
            return entry.profiles
        }
        if let existing = listTasks[key] { return await existing.value }

        let task = Task { () -> [UserProfile] in
            let entries = mode == .followers
                ? (try? await getFollowersList(uid: uid)) ?? []
                : (try? await getFollowingList(uid: uid)) ?? []
            guard !entries.isEmpty else { return [] }
            let fetched = await UserProfileCache.shared.profiles(uids: entries.map(\.uid))
            let byUid = Dictionary(fetched.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
            return entries.compactMap { byUid[$0.uid] }
        }
        listTasks[key] = task
        let value = await task.value
        lists[key] = (value, Date())
        listTasks[key] = nil
        return value
    }

    func cachedFollowList(uid: String, mode: FollowListMode, maxAge: TimeInterval = 60) -> [UserProfile]? {
        guard let entry = lists[Self.listKey(uid, mode)],
              Date().timeIntervalSince(entry.at) < maxAge else { return nil }
        return entry.profiles
    }

    // MARK: - Warming (fire-and-forget; never awaited by a view)

    nonisolated func prefetch(uid: String, viewerUid: String) {
        Task { _ = await bundle(uid: uid, viewerUid: viewerUid) }
    }

    /// Bounded warm for a list of people currently on screen. `limit` matches
    /// the bound Round 9.20 established for album/artist browse-prefetch —
    /// and matters more here, since each bundle is ~5 billed Firestore reads.
    nonisolated func prefetch(uids: [String], viewerUid: String, limit: Int = 6) {
        Task {
            for uid in uids.prefix(limit) where uid != viewerUid {
                _ = await bundle(uid: uid, viewerUid: viewerUid)
            }
        }
    }

    nonisolated func prefetchFollowLists(uid: String) {
        Task {
            _ = await followList(uid: uid, mode: .followers)
            _ = await followList(uid: uid, mode: .following)
        }
    }

    // MARK: - Invalidation

    func invalidate(uid: String) {
        bundles[uid] = nil
        lists[Self.listKey(uid, .followers)] = nil
        lists[Self.listKey(uid, .following)] = nil
    }

    func invalidateAll() {
        bundles.removeAll()
        lists.removeAll()
    }
}
