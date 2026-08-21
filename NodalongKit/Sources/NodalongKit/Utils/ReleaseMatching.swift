// When one ISRC matches several catalog releases (original album, deluxe
// reissue, "Greatest Hits" compilation, singles re-release), picks which one
// is most likely the release the user actually expects — used both for
// resolving playback and for choosing which artwork to store.

private let compilationKeywords = [
    "greatest hits", "best of", "collection", "deluxe", "anniversary",
    "remaster", "compilation", "the hits", "singles", "b-sides", "bonus track",
]

// Case-insensitive substring check against the fixed keyword list above.
public func containsCompilationKeyword(_ albumName: String) -> Bool {
    let lower = albumName.lowercased()
    return compilationKeywords.contains { lower.contains($0) }
}

private func normalize(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

private func score(candidateAlbum: String, expectedAlbum: String?) -> Int {
    var score = 0
    if let expectedAlbum, !expectedAlbum.isEmpty {
        let expected = normalize(expectedAlbum)
        let candidate = normalize(candidateAlbum)
        if candidate == expected {
            score += 100
        } else if candidate.contains(expected) || expected.contains(candidate) {
            score += 50
        }
    }
    if containsCompilationKeyword(candidateAlbum) {
        score -= 30
    }
    return score
}

// Index of the best-scoring candidate album name, or nil for an empty list.
// Ties keep the original (first-result) order, so when nothing distinguishes
// the candidates this behaves exactly like today's `.first`.
public func bestReleaseIndex(albumNames: [String], expectedAlbum: String?) -> Int? {
    guard !albumNames.isEmpty else { return nil }
    return albumNames
        .enumerated()
        .map { (offset: $0.offset, score: score(candidateAlbum: $0.element, expectedAlbum: expectedAlbum)) }
        .max { lhs, rhs in
            lhs.score != rhs.score ? lhs.score < rhs.score : lhs.offset > rhs.offset
        }?
        .offset
}

/// True when `album` names a SINGLE's own release rather than a real album —
/// either an explicit `" - Single"` / `" - EP"` store suffix, or an album
/// name that is just the track title again (which is how a standalone single
/// is represented: the "album" it belongs to is itself).
///
/// This matters because the catalog is keyed by **ISRC**, and a song released
/// as a standalone single and the same recording on an album/EP share one
/// ISRC — so they share one catalog row. Whichever release was ingested first
/// owns that row's album name for every user. A row still describing the
/// single is the weaker answer: it splits the track out of its album in
/// Shelf's `groupByAlbum`, which keys on album name.
///
/// Deliberately does NOT treat `" - EP"` alone as single-like when the name
/// before the suffix differs from the track title — an EP is a real multi-
/// track release worth grouping under.
public func isSingleLikeAlbum(album: String, trackTitle: String) -> Bool {
    let a = normalize(album)
    guard !a.isEmpty else { return false }
    // ONLY an explicit "- Single" store suffix counts.
    //
    // This deliberately does NOT treat "album name == track title" as
    // evidence of a single, even though a standalone single is represented
    // that way. A **title track** is far too common — a device capture
    // flagged "This Is Why" (Paramore), "Visions of a Life" (Wolf Alice),
    // "3D Country" (Geese) and "Romance" (Fontaines D.C.) as single-like,
    // all of which are real albums. Since `isBetterRelease` uses this to
    // decide whether a catalog row's album may be OVERWRITTEN, that
    // misclassification would let a later write replace a perfectly good
    // album name — corrupting shared data to fix a narrower problem. The
    // explicit suffix is sufficient for the case this exists for.
    return a.hasSuffix("- single") || a.hasSuffix("-single")
}

/// True only when `existingAlbum` is the weaker description of the release and
/// `newAlbum` is a genuine upgrade — a one-directional check, so a catalog row
/// can self-correct toward a better match but never regress an already-good
/// one.
///
/// Two upgrade paths:
/// 1. Existing looks like a compilation/deluxe/etc. and the new one doesn't.
/// 2. Existing looks like the track's own **single** release and the new one
///    is a real album/EP — see `isSingleLikeAlbum`. This is what pulls a
///    track that was first ingested as a single (so its shared, ISRC-keyed
///    catalog row says e.g. "Dungarvan Bay - Single") back into the album it
///    was actually saved from ("Salt of the Lee"), instead of stranding it as
///    its own one-track tile in Shelf.
///
/// `trackTitle` is needed only for path 2; pass the catalog row's own title.
public func isBetterRelease(newAlbum: String, existingAlbum: String, trackTitle: String = "") -> Bool {
    if containsCompilationKeyword(existingAlbum) && !containsCompilationKeyword(newAlbum) {
        return true
    }
    guard !newAlbum.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
    return isSingleLikeAlbum(album: existingAlbum, trackTitle: trackTitle)
        && !isSingleLikeAlbum(album: newAlbum, trackTitle: trackTitle)
}

// True when `candidate` and `expected` plausibly name the same release —
// normalized exact match, or containment in either direction (covers store
// suffixes like " - Single" / " - EP" / "(Deluxe)" appearing on one side but
// not the other). Used as a CONFIDENCE gate on top of `bestReleaseIndex`:
// the index always returns *something* for a non-empty list, but callers
// resolving "the album named X" must be able to tell "best candidate
// genuinely is X" apart from "nothing here is X at all, this is just the
// least-bad option" (e.g. a pre-release single whose song only lists its
// upcoming parent album in the `.albums` relationship).
public func albumNamesMatch(_ candidate: String, _ expected: String) -> Bool {
    let c = normalize(candidate)
    let e = normalize(expected)
    guard !c.isEmpty, !e.isEmpty else { return false }
    return c == e || c.contains(e) || e.contains(c)
}

// True only for a normalized EXACT match — no containment leniency. Used
// where `albumNamesMatch`'s "- Single"/"- EP"/edition-suffix tolerance is
// actively wrong: a recording's own `.albums` relationship can legitimately
// contain ONLY a promotional single/feat. edit (its own genuine release),
// which `albumNamesMatch` accepts as "the same album" via containment even
// though it's a different, usually much shorter release than the true
// parent album sharing that base name. Gating on an exact match first, and
// only falling through to a full catalog search (which can find the real
// album even when it's absent from this one recording's relationship)
// otherwise, stops a same-base-name single from winning by being the only
// candidate available in the relationship.
public func albumNamesExactMatch(_ candidate: String, _ expected: String) -> Bool {
    let c = normalize(candidate)
    let e = normalize(expected)
    guard !c.isEmpty, !e.isEmpty else { return false }
    return c == e
}
