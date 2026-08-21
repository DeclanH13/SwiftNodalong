/// A followed user who's played something — the identity half of
/// `FriendsListeningAlbum`'s listener list.
public struct FriendListener: Identifiable, Hashable, Sendable {
    public let uid: String
    public let username: String
    public let avatarEmoji: String?
    public let avatarColor: String?

    public var id: String { uid }

    public init(uid: String, username: String, avatarEmoji: String?, avatarColor: String?) {
        self.uid = uid
        self.username = username
        self.avatarEmoji = avatarEmoji
        self.avatarColor = avatarColor
    }
}

/// One album that people you follow have recently played from — powers
/// Home's "Friends are listening to" rail. Deliberately parallel to
/// `RecentAlbum` (which does the same album-level dedup for the CURRENT
/// user's own plays) but tracks WHO listened instead of a replay count,
/// since the point of this rail is "who," not "what."
public struct FriendsListeningAlbum: Identifiable, Hashable, Sendable {
    public let id: String
    public let albumName: String
    public let artistName: String
    public let artwork: String
    /// Catalog id of the representative (most recently played) track —
    /// Nodalong's own internal id, not a real Apple Music identifier. See
    /// `RecentAlbum.uri`'s doc comment — same bug, same fix, applies here.
    public let catalogId: String
    /// The representative track's real Apple Music id — what actually
    /// resolves via `AppleMusicService.resolveAlbum`'s `catalogTrackId`.
    public let uri: String
    /// Representative track's ISRC — the reliable anchor for
    /// `resolveAlbum`, which used to be handed `isrc: nil` here. See
    /// `Post.isrc`.
    public let isrc: String?
    /// Representative track's own TITLE (not the album name) — see
    /// `RecentAlbum.trackTitle`.
    public let trackTitle: String
    /// Distinct followed users who played something from this album,
    /// most-recently-played first. Deduped by uid — one person playing
    /// several tracks off the album counts once.
    public let listeners: [FriendListener]
    public let mostRecentPlayedAt: Double

    public init(
        id: String, albumName: String, artistName: String, artwork: String,
        catalogId: String, uri: String, isrc: String? = nil, trackTitle: String = "",
        listeners: [FriendListener], mostRecentPlayedAt: Double
    ) {
        self.id = id
        self.albumName = albumName
        self.artistName = artistName
        self.artwork = artwork
        self.catalogId = catalogId
        self.uri = uri
        self.isrc = isrc
        self.trackTitle = trackTitle
        self.listeners = listeners
        self.mostRecentPlayedAt = mostRecentPlayedAt
    }
}

/// Groups Feed posts (people you follow, per `getFollowingFeed`) by album
/// name alone — no artist component in the key, same reasoning as
/// `recentAlbums(from:)` (see that function's doc comment: a various-
/// artists compilation's tracks are genuinely credited to different
/// primary artists by design, which used to split one real album into
/// several spurious "single" tiles) — and ranks by how many DISTINCT
/// followed users played from it — most listened first, ties broken by
/// recency. No minimum listener count: a follow graph with little overlap
/// would otherwise leave this permanently empty, so a single-listener
/// album still shows (with its one listener's avatar) at the bottom of the
/// ranking rather than being dropped.
public func friendsListeningAlbums(from posts: [Post]) -> [FriendsListeningAlbum] {
    var groups: [String: [Post]] = [:]
    for post in posts where !post.album.isEmpty {
        let key = stripSearchNoise(post.album).lowercased()
        groups[key, default: []].append(post)
    }
    return groups.compactMap { key, groupPosts -> FriendsListeningAlbum? in
        let sorted = groupPosts.sorted { $0.createdAt > $1.createdAt }
        guard let latest = sorted.first else { return nil }

        var seenUids = Set<String>()
        var listeners: [FriendListener] = []
        for post in sorted {
            guard !seenUids.contains(post.uid) else { continue }
            seenUids.insert(post.uid)
            listeners.append(FriendListener(
                uid: post.uid, username: post.username,
                avatarEmoji: post.avatarEmoji, avatarColor: post.avatarColor
            ))
        }

        // `defaultLabel` preserves today's exact display (the most-recent
        // post's own artist credit, unstripped) for the common case — only
        // overridden to "Various Artists" when the group's tracks
        // genuinely disagree on primary artist.
        let artistLabel = albumArtistLabel(
            defaultLabel: latest.artist,
            trackArtists: groupPosts.map(\.artist)
        )
        return FriendsListeningAlbum(
            id: key, albumName: latest.album, artistName: artistLabel, artwork: latest.artwork,
            catalogId: latest.catalogId, uri: latest.uri, isrc: latest.isrc,
            trackTitle: latest.title,
            listeners: listeners, mostRecentPlayedAt: latest.createdAt
        )
    }
    .sorted { a, b in
        if a.listeners.count != b.listeners.count { return a.listeners.count > b.listeners.count }
        return a.mostRecentPlayedAt > b.mostRecentPlayedAt
    }
}

/// Aggregates nods per unique track (by `catalogId`) across Feed posts
/// created at or after `cutoff`, summing nods across every followed user's
/// own play of that track — powers Home's "Most nodded this week" rail.
/// Returns each group's most-recently-played `Post` with `nods` overridden
/// to the summed total (reuses `Post`'s existing fields/conversions rather
/// than a new model). Tracks with zero total nods are dropped — this rail
/// is meant to surface genuine social proof, not just recent activity
/// (which "Jump Back In"/Feed already cover).
public func mostNoddedPosts(from posts: [Post], since cutoff: Double, limit: Int = 10) -> [Post] {
    var groups: [String: [Post]] = [:]
    for post in posts where post.createdAt >= cutoff && !post.catalogId.isEmpty {
        groups[post.catalogId, default: []].append(post)
    }
    let ranked: [Post] = groups.compactMap { _, groupPosts -> Post? in
        guard var latest = groupPosts.max(by: { $0.createdAt < $1.createdAt }) else { return nil }
        let totalNods = groupPosts.reduce(0) { $0 + $1.nods }
        guard totalNods > 0 else { return nil }
        latest.nods = totalNods
        return latest
    }
    return Array(ranked.sorted { $0.nods > $1.nods }.prefix(limit))
}
