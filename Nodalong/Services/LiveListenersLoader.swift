import Foundation
import NodalongKit

/// One-shot "who's playing right now" read for a set of followed users —
/// one RTDB read per uid, no persistent observers. Parties are excluded
/// (callers already surface hosts separately).
enum LiveListenersLoader {
    private static let presence = UserPresenceService()

    static func load(followingUids: [String], excluding hostUids: Set<String> = []) async -> [LiveNowEntry] {
        let uids = followingUids.filter { !hostUids.contains($0) }
        guard !uids.isEmpty else { return [] }
        let profiles = await UserProfileCache.shared.profiles(uids: uids)
        let byUid = Dictionary(uniqueKeysWithValues: profiles.map { ($0.uid, $0) })
        return await withTaskGroup(of: LiveNowEntry?.self) { group in
            for uid in uids {
                group.addTask {
                    guard let np = await presence.getNowPlayingOnce(uid: uid),
                          np.isPlaying, let p = byUid[uid] else { return nil }
                    return LiveNowEntry(uid: uid, username: p.username,
                                        avatarEmoji: p.avatarEmoji, avatarColor: p.avatarColor,
                                        kind: .listening(catalogId: np.catalogId, isPreviewPlayback: np.isPreviewPlayback))
                }
            }
            var out: [LiveNowEntry] = []
            for await e in group { if let e { out.append(e) } }
            return out
        }
    }
}
