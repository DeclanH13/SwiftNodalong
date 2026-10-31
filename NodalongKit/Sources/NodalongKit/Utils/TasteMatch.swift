import Foundation

/// How much two people's listening overlaps, shaped for display.
///
/// Shown as a coarse band plus the actual shared artists rather than a
/// percentage: real overlap between two people is small (a handful of artists
/// even for genuine friends), so a raw "9%" would read as "you don't match" and
/// imply precision the data doesn't have.
public struct TasteMatch: Sendable, Equatable {
    public enum Band: String, Sendable { case strong, some, little }

    /// Shared artists, display spelling taken from `theirs`, sorted A→Z.
    public let sharedArtists: [String]
    public let band: Band

    public init(sharedArtists: [String], band: Band) {
        self.sharedArtists = sharedArtists
        self.band = band
    }
}

public let tasteMatchStrongThreshold = 8
public let tasteMatchSomeThreshold   = 3

/// `nil` when the two share no artists (the card is simply hidden).
public func tasteMatch(mine: TasteProfile, theirs: TasteProfile) -> TasteMatch? {
    let shared = mine.artists.intersection(theirs.artists)
    guard !shared.isEmpty else { return nil }
    let names = shared.sorted().map { theirs.displayName(for: $0) ?? mine.displayName(for: $0) ?? $0.capitalized }
    let band: TasteMatch.Band =
        shared.count >= tasteMatchStrongThreshold ? .strong :
        shared.count >= tasteMatchSomeThreshold   ? .some   : .little
    return TasteMatch(sharedArtists: names, band: band)
}
