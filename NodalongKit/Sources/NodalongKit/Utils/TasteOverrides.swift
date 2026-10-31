import Foundation

/// The user's own corrections to what the app thinks they like.
///
/// Keyed by `primaryArtist(name).lowercased()` — the same key everything else
/// in taste uses, so "Dahi & Childish Gambino" and "Dahi" are one artist.
///
/// - **blocked**: never a seed, never suggested, never given a search boost.
/// - **reduced**: still counts, at `reducedMultiplier` of its weight.
public struct TasteOverrides: Codable, Equatable, Sendable {
    public var blocked: Set<String> = []
    public var reduced: Set<String> = []

    public static let reducedMultiplier = 0.3

    public init(blocked: Set<String> = [], reduced: Set<String> = []) {
        self.blocked = blocked
        self.reduced = reduced
    }

    public static func key(_ artist: String) -> String { primaryArtist(artist).lowercased() }

    public var isEmpty: Bool { blocked.isEmpty && reduced.isEmpty }

    /// 0 for blocked, `reducedMultiplier` for reduced, otherwise 1.
    public func multiplier(forKey key: String) -> Double {
        if blocked.contains(key) { return 0 }
        if reduced.contains(key) { return Self.reducedMultiplier }
        return 1
    }

    public mutating func block(_ artist: String) {
        let k = Self.key(artist)
        guard !k.isEmpty else { return }
        reduced.remove(k); blocked.insert(k)
    }

    public mutating func reduce(_ artist: String) {
        let k = Self.key(artist)
        guard !k.isEmpty else { return }
        blocked.remove(k); reduced.insert(k)
    }

    /// Removes any override for this artist key.
    public mutating func clear(key: String) {
        blocked.remove(key); reduced.remove(key)
    }
}

extension TasteWeights {
    /// The same weights with the user's overrides applied: blocked artists get
    /// no boost at all, reduced ones a fraction of theirs.
    public func applying(_ overrides: TasteOverrides) -> TasteWeights {
        guard !overrides.isEmpty else { return self }
        var scaled = artists
        for key in overrides.reduced { if let w = scaled[key] { scaled[key] = w * TasteOverrides.reducedMultiplier } }
        return TasteWeights(artists: scaled, genres: genres, blocked: blocked.union(overrides.blocked))
    }
}
