import Foundation

/// Reorders `items` so tracks by the same artist sit as far apart as possible,
/// keeping the original (best-first) order wherever that causes no clash.
///
/// Greedy: at each position take the earliest remaining item whose artist
/// hasn't appeared within the last `gap` positions; if every remaining item
/// clashes, take the one whose artist appeared longest ago. Artists are grouped
/// with `primaryArtist`, the same normalisation the per-artist cap uses, so a
/// featured credit can't dodge the spread. Only order changes, never membership.
public func spreadByArtist<T>(_ items: [T], gap: Int = 4, artist: (T) -> String) -> [T] {
    func key(_ t: T) -> String { primaryArtist(artist(t)).lowercased() }
    var remaining = items
    var out: [T] = []
    out.reserveCapacity(items.count)
    var lastPos: [String: Int] = [:]
    while !remaining.isEmpty {
        let pos = out.count
        let idx = remaining.firstIndex { pos - (lastPos[key($0)] ?? -gap - 1) > gap }
            ?? remaining.indices.min { (lastPos[key(remaining[$0])] ?? -1) < (lastPos[key(remaining[$1])] ?? -1) }!
        let t = remaining.remove(at: idx)
        lastPos[key(t)] = pos
        out.append(t)
    }
    return out
}
