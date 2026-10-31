import Foundation

/// A genre bucket over the user's Shelf, mirroring `GroupByArtist`'s shape.
public struct GenreEntry: Sendable, Identifiable, Hashable {
    /// Display name, cased as Apple returned it.
    public let name: String
    /// Artwork from the most recently saved track in the bucket.
    public let artwork: String
    public let trackCount: Int
    public let artistCount: Int

    public var id: String { name.lowercased() }

    public init(name: String, artwork: String, trackCount: Int, artistCount: Int) {
        self.name = name
        self.artwork = artwork
        self.trackCount = trackCount
        self.artistCount = artistCount
    }
}

/// Buckets library tracks by genre.
///
/// A track can legitimately carry several genres and is counted under **each**
/// of them — unlike `groupByAlbum`/`groupByArtist`, where a track belongs to
/// exactly one bucket. So the per-genre counts deliberately sum to more than the
/// library size; they answer "how much of my Shelf is this genre", not "how does
/// my Shelf partition".
///
/// Tracks with no genre are skipped rather than bucketed as "Unknown". Genre is
/// overlaid from the shared catalog, so an empty value means *not captured yet*
/// (a row predating genre ingest), not *genre-less* — surfacing that as a real
/// bucket would present missing data as a fact about the music.
public func groupByGenre(_ tracks: [LibraryTrackDoc]) -> [GenreEntry] {
    var map: [String: (display: String, tracks: [LibraryTrackDoc])] = [:]

    for track in tracks {
        for raw in track.genres {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = name.lowercased()
            if map[key] == nil { map[key] = (display: name, tracks: []) }
            map[key]!.tracks.append(track)
        }
    }

    var entries: [GenreEntry] = []
    for (_, pair) in map {
        let sorted = pair.tracks.sorted { $0.savedAt > $1.savedAt }
        let artists = Set(pair.tracks.map { primaryArtist($0.artist).lowercased() })
        entries.append(GenreEntry(
            name: pair.display,
            artwork: sorted.first?.artwork ?? "",
            trackCount: pair.tracks.count,
            artistCount: artists.count
        ))
    }

    // Biggest bucket first; name as a stable tiebreak so the grid doesn't
    // reorder between renders (the same flicker `groupByAlbum` had to fix).
    return entries.sorted {
        $0.trackCount == $1.trackCount
            ? $0.name.lowercased() < $1.name.lowercased()
            : $0.trackCount > $1.trackCount
    }
}

/// Tracks in one genre bucket, newest save first.
public func tracksInGenre(_ genre: String, from tracks: [LibraryTrackDoc]) -> [LibraryTrackDoc] {
    let key = genre.lowercased()
    return tracks
        .filter { $0.genres.contains { $0.lowercased() == key } }
        .sorted { $0.savedAt > $1.savedAt }
}

/// Genres that genuinely describe your library, for offering a discovery tile.
///
/// `groupByGenre` counts a track under every tag it carries, so one mislabelled
/// single (Apple tags "Novacane" `Rock`) is enough to put a genre on the list.
/// Here an artist only belongs to a genre when at least `tasteArtistGenreShare`
/// of their saved tracks carry it, or it is their single most common tag — the
/// same rule `filterCandidates` and `buildTasteSeeds` apply — and a genre needs
/// `minArtists` such artists to count. Ordered by the tracks of the artists that
/// qualify, biggest first.
public func discoverableGenres(_ tracks: [LibraryTrackDoc], minArtists: Int = 3) -> [GenreEntry] {
    var byArtist: [String: [LibraryTrackDoc]] = [:]
    for t in tracks { byArtist[primaryArtist(t.artist).lowercased(), default: []].append(t) }

    var display: [String: String] = [:]
    var members: [String: [(artist: String, tracks: [LibraryTrackDoc])]] = [:]

    for (artist, artistTracks) in byArtist where !artist.isEmpty {
        var counts: [String: Int] = [:]
        for t in artistTracks {
            for raw in Set(t.genres.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !raw.isEmpty {
                let k = raw.lowercased()
                counts[k, default: 0] += 1
                if display[k] == nil { display[k] = raw }
            }
        }
        let top = counts.max { $0.value < $1.value }?.key
        for (k, n) in counts where Double(n) / Double(artistTracks.count) >= tasteArtistGenreShare || k == top {
            let tagged = artistTracks.filter { $0.genres.contains { $0.lowercased() == k } }
            members[k, default: []].append((artist, tagged))
        }
    }

    var entries: [GenreEntry] = []
    for (k, group) in members where group.count >= minArtists {
        let all = group.flatMap(\.tracks)
        let newest = all.max { $0.savedAt < $1.savedAt }
        entries.append(GenreEntry(
            name: display[k] ?? k,
            artwork: newest?.artwork ?? "",
            trackCount: all.count,
            artistCount: group.count
        ))
    }
    return entries.sorted {
        $0.trackCount == $1.trackCount
            ? $0.name.lowercased() < $1.name.lowercased()
            : $0.trackCount > $1.trackCount
    }
}
