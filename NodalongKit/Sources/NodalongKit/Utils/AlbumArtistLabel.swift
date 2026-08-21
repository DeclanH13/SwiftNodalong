/// The label shown when an album's tracks are genuinely credited to more
/// than one distinct primary artist — a various-artists compilation, not a
/// normal album occasionally credited with a featured artist (which
/// `primaryArtist(_:)` already normalizes away before this is ever reached).
public let variousArtistsLabel = "Various Artists"

/// Determines the artist label to show for a group of tracks that share an
/// album, now that the grouping key (`groupByAlbum`/`recentAlbums`/
/// `friendsListeningAlbums`) is the album name alone — no artist component
/// — so a bucket can no longer assume every track shares one artist the way
/// it used to.
///
/// Returns `defaultLabel` (each caller's own existing "what would I have
/// shown" value) unchanged when every track's normalized primary artist
/// agrees — the overwhelming common case, completely unaffected, including
/// existing feat.-credit normalization. Returns `variousArtistsLabel` only
/// when they genuinely differ — confirmed bug: a various-artists
/// compilation ("HELP(2)") used to split into one spurious "single" tile
/// per distinct headline artist instead of showing as one album credited
/// to "Various Artists," matching how a real music catalog would label
/// such a release.
public func albumArtistLabel(defaultLabel: String, trackArtists: [String]) -> String {
    let primaries = Set(trackArtists.map { primaryArtist($0).lowercased() })
    return primaries.count <= 1 ? defaultLabel : variousArtistsLabel
}
