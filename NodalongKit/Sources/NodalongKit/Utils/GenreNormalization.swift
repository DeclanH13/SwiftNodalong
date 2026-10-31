import Foundation

/// Umbrella genre names that carry no information.
///
/// Apple's `genreNames` routinely includes "Music" on nearly every track, which
/// would become the largest bucket in any grouping while telling the user
/// nothing. Localised variants are included because the catalog is
/// storefront-dependent.
public let uninformativeGenres: Set<String> = ["music", "musique", "musik"]

/// Cleans a raw genre list for storage: trims, drops umbrella entries, and
/// de-dupes case-insensitively while preserving the source ordering — the first
/// surviving entry is the most specific.
///
/// Pure string logic, so it lives here rather than in `AppleMusicService`: it
/// has no MusicKit dependency and this is where it can be unit-tested.
public func normalizedGenres(_ raw: [String]) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for name in raw {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let key = trimmed.lowercased()
        guard !uninformativeGenres.contains(key), seen.insert(key).inserted else { continue }
        out.append(trimmed)
    }
    return out
}
