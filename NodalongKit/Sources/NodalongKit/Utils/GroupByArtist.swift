public struct ArtistEntry: Sendable {
    public let name: String
    public let artwork: String
    public let trackCount: Int
    public let albumCount: Int
}

public func groupByArtist(_ tracks: [LibraryTrackDoc]) -> [ArtistEntry] {
    // key = lowercased name for dedup; value = (displayName, tracks)
    var map: [String: (display: String, tracks: [LibraryTrackDoc])] = [:]
    for track in tracks {
        let name = primaryArtistName(from: track.artist)
        let key  = name.lowercased().trimmingCharacters(in: .whitespaces)
        if map[key] == nil {
            map[key] = (display: name, tracks: [])
        }
        map[key]!.tracks.append(track)
    }

    var entries: [ArtistEntry] = []
    for (_, pair) in map {
        let artistTracks = pair.tracks
        // Artwork from the most recently saved track.
        let sorted = artistTracks.sorted { $0.savedAt > $1.savedAt }
        let albumNames = Set(artistTracks.map { $0.album.isEmpty ? "Singles" : $0.album })
        entries.append(ArtistEntry(
            name: pair.display,
            artwork: sorted[0].artwork,
            trackCount: artistTracks.count,
            albumCount: albumNames.count
        ))
    }

    entries.sort { $0.name.lowercased() < $1.name.lowercased() }
    return entries
}

public func getAlbumsForArtist(_ allAlbumGroups: [AlbumGroup], artistName: String) -> [AlbumGroup] {
    allAlbumGroups.filter { $0.artistName.lowercased() == artistName.lowercased() }
}

private func primaryArtistName(from artist: String) -> String {
    // Delegates to `primaryArtist(_:)` (SearchQueryNormalization.swift), which
    // splits on the first of `,` / `&` / `feat.` / `ft.` / `featuring` / `with`
    // — a strict superset of the old feat.-only splitting this used to do.
    // `GroupByAlbum.swift` had the identical bug (and the identical fix)
    // shipped in an earlier session — this second, separate copy for artist
    // grouping was missed at the time. Without it, per-track credit strings
    // like "Dahi & Childish Gambino" / "Dahi, Kendrick Lamar & Amber..."
    // each produced their OWN artist entry instead of collapsing under the
    // shared primary artist "Dahi" — one album could fragment into as many
    // "artists" as it has featured-artist tracks.
    let name = artist.isEmpty ? "Unknown Artist" : artist
    return primaryArtist(name)
}
