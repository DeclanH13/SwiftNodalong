public func isValidTrack(_ song: Song) -> Bool {
    !song.title.isEmpty && !song.artist.isEmpty && !song.artwork.isEmpty && !song.uri.isEmpty
}

public func isValidArtist(_ artist: ArtistResult) -> Bool {
    !artist.name.isEmpty && !artist.imageUrl.isEmpty
}

public func isValidAlbum(_ album: AlbumResult) -> Bool {
    !album.name.isEmpty && !album.artwork.isEmpty && !album.artistName.isEmpty && album.totalTracks > 0
}
