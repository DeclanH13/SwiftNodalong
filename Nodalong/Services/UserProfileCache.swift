import Foundation
import NodalongKit

/// Session-scoped cache of `UserProfile` documents, keyed by uid.
///
/// At cold launch the same followed-user profile set was read from Firestore
/// **three times concurrently**:
///   1. `getFriendsSpotlightsToday` → `getUserProfiles` (batched)
///   2. `HomeViewModel.loadLiveNow` → `getUserProfiles` (batched again, in
///      the very same task, moments later)
///   3. `getFollowingFeed` → one `getDocument()` **per followed user**
///
/// `FollowingCache` already dedupes the follow *list*, but nothing deduped the
/// profile *documents* those paths then fetched. On the slow capture this is
/// the bulk of `spotlights+liveNow` (1897ms), Home's single largest cost.
///
/// Mirrors `FollowingCache`/`CatalogCache`: actor-isolated, TTL'd, with
/// in-flight sharing so concurrent callers for the same uid set await one
/// fetch instead of racing their own.
actor UserProfileCache {
    static let shared = UserProfileCache()
    private init() {}

    private var cache: [String: (profile: UserProfile, at: Date)] = [:]
    private var inFlight: [String: Task<[UserProfile], Never>] = [:]

    /// Returns profiles for `uids`, serving whatever is still fresh from
    /// memory and fetching only the remainder. Order is not guaranteed —
    /// callers that care should re-sort (same contract as `getUserProfiles`).
    func profiles(uids: [String], maxAge: TimeInterval = 60) async -> [UserProfile] {
        let now = Date()
        var hits: [UserProfile] = []
        var missing: [String] = []
        for uid in Set(uids) {
            if let entry = cache[uid], now.timeIntervalSince(entry.at) < maxAge {
                hits.append(entry.profile)
            } else {
                missing.append(uid)
            }
        }
        guard !missing.isEmpty else { return hits }

        let key = missing.sorted().joined(separator: ",")
        if let existing = inFlight[key] { return hits + (await existing.value) }

        let task = Task { (try? await getUserProfiles(uids: missing)) ?? [] }
        inFlight[key] = task
        let fetched = await task.value
        inFlight[key] = nil
        let stamp = Date()
        for profile in fetched { cache[profile.uid] = (profile, stamp) }
        return hits + fetched
    }

    /// Drops everything — call when the follow graph or a profile changes in a
    /// way the TTL shouldn't paper over.
    func invalidate() { cache.removeAll() }
}

/// Resolves a profile to push from a bare uid — through the shared profile
/// cache rather than a fresh Firestore read — and starts warming that person's
/// detail bundle at the same moment, so the fetch overlaps the push instead of
/// following it.
func profileForNavigation(uid: String, viewerUid: String?) async -> UserProfile? {
    if let viewerUid { SocialCache.shared.prefetch(uid: uid, viewerUid: viewerUid) }
    if let cached = await UserProfileCache.shared.profiles(uids: [uid]).first { return cached }
    return try? await getUserProfile(uid: uid)
}
