public struct AlbumGroup: Sendable, Hashable, Identifiable {
    // Compound key "album|||artist" — same-named albums by different artists stay separate.
    public let key: String
    public let albumName: String
    public let artistName: String
    public let artwork: String
    public let trackCount: Int
    public let albumReleaseDate: String?
    public let tracks: [LibraryTrackDoc]

    public var id: String { key }
}

public func groupByAlbum(_ tracks: [LibraryTrackDoc]) -> [AlbumGroup] {
    var map: [String: [LibraryTrackDoc]] = [:]

    for track in tracks {
        // Runs the album name through `stripSearchNoise(_:)` before keying —
        // a track saved via a different path than the rest of its album
        // (e.g. an earlier individual play/like/sync vs. a later "Save
        // Album" batch) can carry a differently-suffixed album string for
        // the same real release ("Salt of the Lee" vs "Salt of the Lee -
        // EP"), which would otherwise split one album into two Shelf
        // groups. Lowercase + trim so case variants ("The Beatles" vs "the
        // beatles") merge into one group too.
        let normalizedAlbum = stripSearchNoise(track.album).lowercased().trimmingCharacters(in: .whitespaces)
        // The key is the ALBUM NAME ALONE — no artist component — once
        // there IS an album name. A various-artists compilation's tracks
        // are genuinely credited to different primary artists by design
        // (not the feat.-credit variance `primaryArtist(_:)` already
        // handles), so keying on (album, artist) split one real album into
        // several spurious "single" tiles — confirmed on device
        // ("HELP(2)"). A genuine title collision between two unrelated
        // releases is rare in practice, and Apple's own catalog already
        // disambiguates the common case (e.g. "HELP" vs "HELP(2)") with a
        // suffix `stripSearchNoise` doesn't touch.
        //
        // Tracks with NO album at all are the one exception that still
        // needs per-artist keying — otherwise every artist's standalone
        // singles (all sharing the same empty album name) would collapse
        // into one giant "Singles" bucket across the whole library.
        let key = normalizedAlbum.isEmpty
            ? "||||\(primaryArtistName(track.artist).lowercased())"
            : normalizedAlbum
        map[key, default: []].append(track)
    }

    var groups: [AlbumGroup] = []
    for (key, groupTracks) in map {
        let sorted = groupTracks.sorted {
            switch ($0.trackNumber, $1.trackNumber) {
            case let (a?, b?): return a < b
            case (_?, nil):    return true
            default:           return false
            }
        }
        let first = sorted[0]
        let releaseDate = sorted.first(where: { $0.albumReleaseDate != nil })?.albumReleaseDate
        // `defaultLabel` preserves today's exact display (the
        // representative track's own normalized primary artist) for the
        // overwhelming common case — only overridden to "Various Artists"
        // when the group's tracks genuinely disagree on primary artist.
        let artistLabel = albumArtistLabel(
            defaultLabel: primaryArtistName(first.artist),
            trackArtists: groupTracks.map(\.artist)
        )
        groups.append(AlbumGroup(
            key: key,
            albumName: first.album.isEmpty ? "Singles" : first.album,
            artistName: artistLabel,
            artwork: first.artwork,
            trackCount: sorted.count,
            albumReleaseDate: releaseDate,
            tracks: sorted
        ))
    }

    // Sort: artist A→Z, then album release date oldest→newest, then album name
    // A→Z as a stable tiebreaker. The tiebreaker is critical — without it,
    // albums with no release date sort in dictionary-insertion order (random),
    // causing the grid to flicker and reorder between renders.
    //
    // Decorate-sort-undecorate: the comparator previously called
    // `.lowercased()` (which allocates a fresh String) on BOTH sides of EVERY
    // comparison, plus ICU-backed `localizedCompare`. At ~110 groups that's
    // ~750 comparisons × 2 allocations. Precomputing each key once per
    // element instead makes it 110 allocations total. Ordering is unchanged —
    // the same keys are compared the same way, just computed once.
    var decorated = groups.map {
        (group: $0, artistKey: $0.artistName.lowercased(), albumKey: $0.albumName.lowercased())
    }
    decorated.sort { a, b in
        let artistCmp = a.artistKey.localizedCompare(b.artistKey)
        if artistCmp != .orderedSame { return artistCmp == .orderedAscending }
        switch (a.group.albumReleaseDate, b.group.albumReleaseDate) {
        case let (aDate?, bDate?):
            if aDate != bDate { return aDate < bDate }
            return a.albumKey < b.albumKey
        case (_?, nil): return true
        case (nil, _?): return false
        default:        return a.albumKey < b.albumKey
        }
    }
    return decorated.map(\.group)
}

private func primaryArtistName(_ artist: String) -> String {
    // Delegates to `primaryArtist(_:)` (SearchQueryNormalization.swift), which
    // splits on the first of `,` / `&` / `feat.` / `ft.` / `featuring` / `with`
    // — a strict superset of the old feat.-only splitting. Without this, a
    // featured-artist track (e.g. "Jamie xx & Honey Dijon") produces a
    // different grouping key than the album's plain tracks ("Jamie xx"),
    // splitting one album into two groups in Shelf.
    let name = artist.isEmpty ? "Unknown Artist" : artist
    return primaryArtist(name)
}
