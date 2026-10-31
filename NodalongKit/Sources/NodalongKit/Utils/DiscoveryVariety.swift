import Foundation

/// Keeps "Found for you" from suggesting the same artists every week.
///
/// Apple's similar-artists list is fixed per artist and the user's top seeds
/// barely change, so without these the same graph hubs win every run.

/// Seeds for this run: the strongest few always stay, the rest are drawn
/// (weighted, seeded) from the next tier — a different corner of the graph
/// each week while the playlist still sounds like you.
///
/// With no `shuffleSeed` it is simply the top `total`, so callers that want a
/// stable answer get one.
public func rotatedSeeds(
    _ ranked: [SeededArtist],
    stable: Int = 4,
    total: Int = 8,
    poolEnd: Int = 25,
    shuffleSeed: UInt64?
) -> [SeededArtist] {
    guard let shuffleSeed, ranked.count > total else { return Array(ranked.prefix(total)) }
    let fixed = Array(ranked.prefix(stable))
    let pool = Array(ranked[stable..<min(poolEnd, ranked.count)])
    let need = max(0, total - fixed.count)
    guard pool.count > need else { return fixed + pool }

    // Efraimidis–Spirakis weighted sampling without replacement.
    var rng = TasteShuffleGenerator(seed: shuffleSeed)
    let keyed = pool.map { artist -> (SeededArtist, Double) in
        let u = Double.random(in: Double.leastNonzeroMagnitude..<1, using: &rng)
        return (artist, pow(u, 1 / max(artist.weight, 0.0001)))
    }
    let drawn = keyed.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.key < $1.0.key }.prefix(need).map(\.0)
    // Keep strongest-first order so descriptions still lead with the biggest.
    return fixed + drawn.sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.key < $1.key }
}

public let noveltyWindowDays: Double = 28
public let noveltyFloor: Double = 0.25

/// Multipliers for artists suggested recently: `noveltyFloor` right after a
/// suggestion, recovering linearly to 1 over `noveltyWindowDays`. Artists not
/// in `recent` (or fully recovered) are omitted.
///
/// - Parameter recent: normalized artist key → when it was last suggested
///   (epoch seconds).
public func noveltyMultipliers(recent: [String: Double], nowSeconds: Double) -> [String: Double] {
    var out: [String: Double] = [:]
    let window = noveltyWindowDays * 86_400
    for (key, at) in recent {
        let age = max(0, nowSeconds - at)
        guard age < window else { continue }
        out[key] = noveltyFloor + (1 - noveltyFloor) * (age / window)
    }
    return out
}

/// Which first-hop candidates to expand again for a second hop: only ones a
/// single seed pointed at (hubs are already over-represented), picked by the
/// seeded draw so it varies week to week. Returns indices into `candidates`.
public func secondHopPicks(_ candidates: [CandidateArtist], count: Int = 6, shuffleSeed: UInt64?) -> [CandidateArtist] {
    let singles = candidates.filter { $0.seedNames.count == 1 }
    guard let shuffleSeed else { return Array(singles.prefix(count)) }
    var rng = TasteShuffleGenerator(seed: shuffleSeed &+ 7)
    var pool = singles
    pool.shuffle(using: &rng)
    return Array(pool.prefix(count))
}
