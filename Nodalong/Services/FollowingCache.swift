import Foundation
import NodalongKit

/// One followed-user entry — a `Sendable` struct (not the API's tuple, which
/// can't cross an actor boundary) so it can live in a `Task`'s result.
struct FollowEntry: Sendable, Hashable {
    let uid: String
    let username: String
}

/// Session-scoped dedupe for the launch-time fan-out.
///
/// At cold launch, `HomeViewModel.load`, `FeedView`'s party-discovery banner,
/// and `getFollowingFeed` (inside its own fetch) all independently read the
/// current user's following list within the same second — 3 identical
/// Firestore reads for data that hasn't changed. `getLivePartiesHostedBy` is
/// similarly read twice (Home + Feed) for the same following set. This actor
/// (pattern-matches `CatalogCache`) collapses concurrent callers onto one
/// in-flight fetch and serves a short-TTL cached result to callers that land
/// moments later.
///
/// A short TTL (not "forever, until invalidated") is deliberate: this covers
/// the launch-time burst, not a durable follow-graph cache — a slightly stale
/// read past the TTL is harmless (the next natural fetch corrects it), so
/// there's no need for every reader to remember to invalidate. `invalidate()`
/// exists for the cases that DO matter immediately (see below).
actor FollowingCache {
    static let shared = FollowingCache()
    private init() {}

    private var entriesResult: (uid: String, entries: [FollowEntry], at: Date)?
    private var entriesTask: Task<[FollowEntry], Never>?
    private var entriesTaskUid: String?

    private var partiesResult: (key: String, parties: [ListeningParty], at: Date)?
    private var partiesTask: Task<[ListeningParty], Never>?

    func following(uid: String, maxAge: TimeInterval = 30) async -> [FollowEntry] {
        if let r = entriesResult, r.uid == uid, Date().timeIntervalSince(r.at) < maxAge {
            return r.entries
        }
        if let task = entriesTask, entriesTaskUid == uid { return await task.value }
        let task = Task { [uid] () -> [FollowEntry] in
            ((try? await getFollowingList(uid: uid)) ?? [])
                .map { FollowEntry(uid: $0.uid, username: $0.username) }
        }
        entriesTask = task
        entriesTaskUid = uid
        let entries = await task.value
        entriesResult = (uid, entries, Date())
        entriesTask = nil
        entriesTaskUid = nil
        return entries
    }

    func liveParties(hostedBy uids: [String], maxAge: TimeInterval = 30) async -> [ListeningParty] {
        let key = uids.sorted().joined(separator: ",")
        if let r = partiesResult, r.key == key, Date().timeIntervalSince(r.at) < maxAge {
            return r.parties
        }
        if let task = partiesTask { return await task.value }
        let task = Task { (try? await getLivePartiesHostedBy(uids: uids)) ?? [] }
        partiesTask = task
        let parties = await task.value
        partiesResult = (key, parties, Date())
        partiesTask = nil
        return parties
    }

    /// Called by `followUser`/`unfollowUser` themselves (see `Follows.swift`)
    /// so a follow-graph change is picked up immediately by the next Home or
    /// Feed load, rather than waiting out the TTL.
    func invalidate() {
        entriesResult = nil
        partiesResult = nil
    }
}
