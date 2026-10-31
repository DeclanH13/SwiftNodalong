import Foundation

/// "Your week" — a summary of one Monday→Monday window, built entirely from
/// data Home already holds (own recent plays, Shelf saves, spotlights and the
/// Feed), so it costs no reads.
///
/// Honest limit: own plays come from `recent_tracks`, which is capped at the
/// latest ~100, so a heavy listener's recap covers "your latest plays" rather
/// than every play of the week.
public struct WeeklyRecap: Sendable, Equatable {
    public struct ArtistCount: Sendable, Equatable {
        public let name: String
        public let plays: Int
    }
    public struct InSync: Sendable, Equatable {
        public let username: String
        public let sharedArtists: Int
    }

    public let weekStartMs: Double
    public let playCount: Int
    public let topArtists: [ArtistCount]        // max 3
    public let savedCount: Int
    public let spotlightCount: Int
    public let nodsReceived: Int
    public let mostInSync: InSync?
    public let friendTrackOfTheWeek: Post?

    public var isEmpty: Bool { playCount == 0 && savedCount == 0 && spotlightCount == 0 }
}

/// Window is `[weekStartMs, weekEndMs)`.
public func buildWeeklyRecap(
    myPosts: [Post],
    myLibrary: [LibraryTrackDoc],
    mySpotlights: [SpotlightTrack],
    friendPosts: [Post],
    weekStartMs: Double,
    weekEndMs: Double
) -> WeeklyRecap {
    func inWindow(_ ms: Double) -> Bool { ms >= weekStartMs && ms < weekEndMs }

    let plays = myPosts.filter { inWindow($0.createdAt) }

    // Top artists, normalized the same way as everywhere else in the app.
    var counts: [String: (name: String, plays: Int)] = [:]
    for p in plays {
        let name = primaryArtist(p.artist)
        let key = name.lowercased()
        guard !key.isEmpty else { continue }
        counts[key] = (counts[key]?.name ?? name, (counts[key]?.plays ?? 0) + 1)
    }
    let top = counts.values
        .sorted { $0.plays != $1.plays ? $0.plays > $1.plays : $0.name < $1.name }
        .prefix(3)
        .map { WeeklyRecap.ArtistCount(name: $0.name, plays: $0.plays) }

    let saved = myLibrary.filter { inWindow($0.savedAt) }.count
    let spotlights = mySpotlights.filter { inWindow($0.spotlitAt) }.count
    let nods = plays.reduce(0) { $0 + $1.nods }

    // Friends' plays inside the window.
    let friends = friendPosts.filter { inWindow($0.createdAt) }
    let myArtistKeys = Set(plays.map { primaryArtist($0.artist).lowercased() }.filter { !$0.isEmpty })
    var byFriend: [String: (username: String, artists: Set<String>)] = [:]
    for p in friends {
        let key = primaryArtist(p.artist).lowercased()
        guard !key.isEmpty else { continue }
        var entry = byFriend[p.uid] ?? (p.username, [])
        entry.artists.insert(key)
        byFriend[p.uid] = entry
    }
    let inSync = byFriend.values
        .map { WeeklyRecap.InSync(username: $0.username, sharedArtists: $0.artists.intersection(myArtistKeys).count) }
        .filter { $0.sharedArtists > 0 }
        .max { $0.sharedArtists != $1.sharedArtists ? $0.sharedArtists < $1.sharedArtists : $0.username > $1.username }

    let friendTrack = friends.filter { $0.nods > 0 }.max {
        $0.nods != $1.nods ? $0.nods < $1.nods : $0.createdAt < $1.createdAt
    }

    return WeeklyRecap(
        weekStartMs: weekStartMs, playCount: plays.count, topArtists: Array(top),
        savedCount: saved, spotlightCount: spotlights, nodsReceived: nods,
        mostInSync: inSync, friendTrackOfTheWeek: friendTrack
    )
}
