import Foundation

/// Nodalong has no explicit "friends" collection — a **friend is a mutual
/// follow**. This computes that intersection from a user's `following` and
/// `followers` uid lists, preserving `following` order (so an invite list reads
/// in the order the user chose to follow people).
///
/// Used for party invites and to gate who may join a listening party.
public func friendUids(following: [String], followers: [String]) -> [String] {
    let followerSet = Set(followers)
    var seen = Set<String>()
    return following.filter { uid in
        guard followerSet.contains(uid), !seen.contains(uid) else { return false }
        seen.insert(uid)
        return true
    }
}
