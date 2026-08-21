import Foundation

// Apple's catalog frequently lists the same underlying release more than
// once — an explicit and a clean pressing as two separate album ids, or a
// standard edition alongside a deluxe/anniversary/remaster with a nearly
// identical name. Left alone, an artist's discography shows visible
// duplicates. `dedupeAlbumEditions` folds each group down to one primary
// card (explicit preferred, per product decision) and files the rest under
// `AlbumResult.alternates` for a secondary "Alternative versions" list.

/// Compiled once. `NSRegularExpression` construction parses the pattern
/// and builds a matching engine; these previously recompiled on every
/// call, inside hot grouping/render paths. Kept `Optional` + `try?` so
/// failure semantics are identical to the previous inline versions.
private enum EditionRx {
    static let canonicalBracket: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\s*[\(\[](deluxe|anniversary|remaster(ed)?|explicit|clean|bonus track|expanded|special edition|collector'?s edition)[^\)\]]*[\)\]]"#,
        options: .caseInsensitive
    )
    static let canonicalDash: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\s+-\s+(deluxe|anniversary|remaster(ed)?|explicit|clean|bonus track|expanded|special).*$"#,
        options: .caseInsensitive
    )
    static let labelBracket: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"[\(\[]([^\)\]]*\b(?:deluxe|anniversary|remaster(?:ed)?|explicit|clean|bonus track|expanded|special edition|collector'?s edition)[^\)\]]*)[\)\]]"#,
        options: .caseInsensitive
    )
    static let labelDash: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\s-\s((?:deluxe|anniversary|remaster(?:ed)?|explicit|clean|bonus track|expanded|special).*)$"#,
        options: .caseInsensitive
    )
}

/// Strips edition-describing noise from an album title so different
/// editions of the same release group together — "We Were Just Here",
/// "We Were Just Here (Explicit)", "We Were Just Here (Deluxe Edition)" all
/// reduce to the same canonical form. Deliberately narrower than
/// `stripSearchNoise` (built for track-title search fallback, which also
/// strips featured-artist credits) — two different albums can legitimately
/// share a featured-artist credit without being the same release, so this
/// only strips version/edition noise.
public func canonicalAlbumTitle(_ title: String) -> String {
    var result = title
        if let regex = EditionRx.canonicalBracket {
        let range = NSRange(result.startIndex..., in: result)
        result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
    }
        if let regex = EditionRx.canonicalDash {
        let range = NSRange(result.startIndex..., in: result)
        result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

/// Extracts a human-readable edition label from the noise `canonicalAlbumTitle`
/// strips away — e.g. "We Were Just Here (Deluxe Edition)" → "Deluxe Edition".
/// Returns `nil` when the title carries no such marker (the caller falls back
/// to an explicit/clean-derived label in that case).
public func albumEditionLabel(_ title: String) -> String? {
        if let regex = EditionRx.labelBracket,
       let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
       let range = Range(match.range(at: 1), in: title) {
        return String(title[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
        if let regex = EditionRx.labelDash,
       let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
       let range = Range(match.range(at: 1), in: title) {
        return String(title[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return nil
}

/// Groups `albums` by (canonical title, artist) and folds every group down
/// to one primary entry — explicit preferred (product decision: "always
/// default to the explicit version"), then more tracks (a deluxe edition is
/// typically a superset), then original order. The rest of each group is
/// attached to the primary's `alternates`, each labeled via
/// `albumEditionLabel` when the title carries its own marker, or an
/// explicit/clean label derived from the content-rating difference
/// otherwise. Order of the returned primaries matches the order groups were
/// first seen in `albums`.
public func dedupeAlbumEditions(_ albums: [AlbumResult]) -> [AlbumResult] {
    var order: [String] = []
    var groups: [String: [AlbumResult]] = [:]
    for album in albums {
        let key = "\(canonicalAlbumTitle(album.name))||\(album.artistName.lowercased())"
        if groups[key] == nil {
            order.append(key)
            groups[key] = []
        }
        groups[key]!.append(album)
    }

    return order.compactMap { key -> AlbumResult? in
        guard var members = groups[key], !members.isEmpty else { return nil }
        guard members.count > 1 else { return members[0] }

        members.sort { lhs, rhs in
            if lhs.isExplicit != rhs.isExplicit { return lhs.isExplicit }
            if lhs.totalTracks != rhs.totalTracks { return lhs.totalTracks > rhs.totalTracks }
            return false
        }
        let primary = members.removeFirst()
        let alternates: [AlbumResult] = members.map { alt in
            var alt = alt
            alt.alternates = []
            if alt.isExplicit != primary.isExplicit {
                alt.editionLabel = alt.isExplicit ? "Explicit" : "Clean"
            } else {
                alt.editionLabel = albumEditionLabel(alt.name) ?? "Alternate version"
            }
            return alt
        }
        var result = primary
        result.alternates = alternates
        return result
    }
}
