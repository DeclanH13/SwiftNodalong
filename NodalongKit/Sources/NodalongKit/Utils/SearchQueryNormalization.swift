import Foundation

// Cleans up track title/artist strings before they're sent to a search
// backend's field-scoped query (e.g. Spotify's `track:`/`artist:` filters,
// which are fairly literal — a title carrying "(feat. X)" or
// "- Remastered 2011" routinely returns zero results even when the track
// genuinely exists under a cleaner title). Used only as fallback tiers,
// tried after an unmodified raw search has already come back empty — see
// `SpotifyMusicService.resolve(_:)`.

/// Strips common non-title search noise: parenthetical/bracketed suffixes
/// like "(feat. X)", "(ft. X)", "(with X)", "(Remastered ...)",
/// "(Deluxe ...)", "(Live ...)", "(Radio Edit)", "(Single Version)",
/// "(Original Mix)", "(Explicit)"/"[Explicit]", "(Clean)"/"[Clean]" — plus a
/// trailing " - <suffix>" dash pattern (e.g. "Song Title - Remastered
/// 2011"). Case-insensitive.
///
/// Heuristic, not a general-purpose title parser: a legitimate title that
/// happens to contain "(With Love)" or a dash as part of its real name can
/// get over-stripped. Acceptable here because this is only ever reached
/// after a raw-title search has already failed — a wrong guess costs
/// nothing further, and a right guess turns a false "not found" into a
/// real match.
private enum StripNoiseRx {
    /// Compiled once, at first use. `NSRegularExpression` construction parses
    /// the pattern and builds a matching engine — it is NOT free, and this
    /// previously ran twice on **every** call. `groupByAlbum` calls
    /// `stripSearchNoise` once per track, so a 441-track library meant ~882
    /// regex compilations per grouping call, on the main thread, inside a
    /// view body. Measured at 13.5 ms per `groupByAlbum` call before this
    /// change — most of a 16.7 ms frame budget, which is what produced the
    /// reported scroll stutter.
    ///
    /// Deliberately kept `Optional` + `try?` rather than `try!` so failure
    /// semantics are byte-identical to the previous inline version: a
    /// malformed pattern still degrades to "skip this step" instead of
    /// trapping. This change is pure caching, no behaviour change.
    static let bracket: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\s*[\(\[](feat\.?|ft\.?|featuring|with|remaster(ed)?|deluxe|live|radio edit|single version|original mix|explicit|clean)[^\)\]]*[\)\]]"#,
        options: .caseInsensitive
    )
    static let dash: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\s+-\s+\S.*$"#
    )
}

public func stripSearchNoise(_ title: String) -> String {
    var result = title

    if let regex = StripNoiseRx.bracket {
        let range = NSRange(result.startIndex..., in: result)
        result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
    }

    // Strips from the first " - " onward, not just the trailing segment —
    // simplest correct behavior for the common "Title - Remastered 2011"
    // case; a title with multiple legitimate dashes is rare enough to accept
    // the risk given this only runs as a last-resort fallback.
    if let regex = StripNoiseRx.dash {
        let range = NSRange(result.startIndex..., in: result)
        result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
    }

    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}


/// Returns just the leading artist from a multi-artist string, splitting on
/// the first of `,` / `&` / `feat.` / `ft.` / `featuring` / `with`
/// (case-insensitive, each preceded by whitespace). Returns the input
/// unchanged if none of those appear.
///
/// Used as a further fallback tier for a field-scoped `artist:` search — a
/// stored artist string like "Drake, Future" can fail to match a search
/// backend's own single-primary-artist field even when "Drake" alone would.
/// Memoises `primaryArtist`, which performs SIX ICU-backed case-insensitive
/// `range(of:)` searches per call. The grouping functions call it once per
/// track (`groupByAlbum` via `albumArtistLabel`, plus `groupByArtist`,
/// `FriendsActivity` and `GroupPostsByAlbum`) — roughly 550 calls, ≈3,300 ICU
/// searches, for a 441-track library, on the main thread inside a view body.
/// Artist strings repeat heavily across a library (one artist, many tracks),
/// so the hit rate is very high.
///
/// Safe to cache because `primaryArtist` is a pure function of its input.
/// Thread-safe via a plain lock — callers span the main actor (Shelf/Home
/// grouping) and background tasks (`SpotifyMusicService.resolve`); the
/// uncontended lock cost is negligible against what it avoids.
private final class PrimaryArtistMemo: @unchecked Sendable {
    static let shared = PrimaryArtistMemo()
    private let lock = NSLock()
    private var cache: [String: String] = [:]

    func value(for artist: String) -> String {
        lock.lock()
        if let hit = cache[artist] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let computed = primaryArtistUncached(artist)

        lock.lock()
        // Bounded so a long session can't grow this without limit. A flush is
        // cheap and correctness-neutral — every entry is recomputable.
        if cache.count > 2_000 { cache.removeAll(keepingCapacity: true) }
        cache[artist] = computed
        lock.unlock()
        return computed
    }
}

public func primaryArtist(_ artist: String) -> String {
    PrimaryArtistMemo.shared.value(for: artist)
}

private func primaryArtistUncached(_ artist: String) -> String {
    let separators = [",", "&", " feat.", " ft.", " featuring", " with"]
    var earliestRange: Range<String.Index>?
    for separator in separators {
        if let range = artist.range(of: separator, options: .caseInsensitive),
           earliestRange == nil || range.lowerBound < earliestRange!.lowerBound {
            earliestRange = range
        }
    }
    guard let range = earliestRange else { return artist }
    return String(artist[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The canonical "is this the same album?" key: `stripSearchNoise`, lowercased
/// and trimmed.
///
/// 🔴 Exists so there is exactly ONE definition of album identity. It had been
/// written out inline three times — `groupByAlbum`'s own grouping key, Home's
/// New-Releases-vs-Shelf dedup, and Home's Recently-Played-vs-Jump-Back-In
/// dedup — which is precisely the drift this codebase has already been bitten
/// by: a dedup that silently stops matching the grouping it is meant to agree
/// with. Change what "same album" means here and every caller follows.
///
/// Note two related keys deliberately do NOT route through this and are not
/// bugs: `canonicalAlbumTitle` (AlbumEditionGrouping) strips *edition*
/// wording — "Deluxe", "Remastered" — which is a different question, and the
/// post-grouping keys in `GroupPostsByAlbum`/`FriendsActivity` omit the trim
/// and are pinned by their own tests.
public func albumMatchKey(_ albumName: String) -> String {
    stripSearchNoise(albumName).lowercased().trimmingCharacters(in: .whitespaces)
}
