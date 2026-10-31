import Foundation
import NodalongKit

/// Promotion helpers from in-app domain types (`Post`, `LibraryTrackDoc`,
/// `SpotlightTrack`) up to the unified `Song` model that the player and
/// `MusicService` accept. Centralised so call sites stay one-liners:
///
/// ```swift
/// await playerVM.play(.from(post: post))
/// ```
///
/// Lives in the app target rather than `NodalongKit` because these types
/// don't all share a single concept — this is glue, not a domain model.
///
/// `LibraryTrackDoc.from(song:)` at the bottom runs the other way, for the
/// write paths (save to Shelf, spotlight) that take a document rather than a
/// `Song`.
extension Song {
    /// Promote a feed `Post` to a playable `Song`.
    static func from(post: Post) -> Song {
        Song(
            id:               post.trackId ?? post.id,
            title:            post.title,
            artist:           post.artist,
            album:            post.album,
            artwork:          post.artwork,
            trackId:          post.trackId ?? post.id,
            uri:              post.uri,
            catalogId:        post.catalogId,
            sourceService:    post.sourceService
        )
    }

    /// Promote a saved-library document to a playable `Song`.
    static func from(libraryTrack t: LibraryTrackDoc) -> Song {
        Song(
            id:               t.catalogId,
            title:            t.title,
            artist:           t.artist,
            album:            t.album,
            artwork:          t.artwork,
            trackId:          t.catalogId,
            uri:              t.uri,
            catalogId:        t.catalogId,
            sourceService:    t.sourceService,
            isrc:             t.isrc,
            duration:         t.duration,
            trackNumber:      t.trackNumber,
            albumReleaseDate: t.albumReleaseDate
        )
    }

    /// Promote a playlist track to a playable `Song`.
    static func from(playlistTrack t: PlaylistTrack) -> Song {
        Song(
            id:               t.id.isEmpty ? t.catalogId : t.id,
            title:            t.title,
            artist:           t.artist,
            album:            t.album,
            artwork:          t.artwork,
            trackId:          t.catalogId,
            uri:              t.uri,
            catalogId:        t.catalogId,
            sourceService:    t.sourceService,
            isrc:             t.isrc,
            duration:         t.duration,
            trackNumber:      t.trackNumber,
            albumReleaseDate: t.albumReleaseDate
        )
    }

    /// Promote a party-queue track to a playable `Song`.
    static func from(partyQueueTrack t: PartyQueueTrack) -> Song {
        Song(
            id:               t.id.isEmpty ? t.catalogId : t.id,
            title:            t.title,
            artist:           t.artist,
            album:            t.album,
            artwork:          t.artwork,
            trackId:          t.catalogId,
            uri:              t.uri,
            catalogId:        t.catalogId,
            sourceService:    t.sourceService,
            isrc:             t.isrc,
            duration:         t.duration,
            trackNumber:      t.trackNumber,
            albumReleaseDate: t.albumReleaseDate
        )
    }

    /// Promote a spotlight entry to a playable `Song`.
    static func from(spotlight s: SpotlightTrack) -> Song {
        Song(
            id:               s.trackId,
            title:            s.title,
            artist:           s.artist,
            album:            s.album,
            artwork:          s.artwork,
            trackId:          s.trackId,
            uri:              s.uri,
            catalogId:        s.catalogId,
            sourceService:    s.sourceService ?? .appleMusic
        )
    }

    /// Promote a catalog row (`tracks/{catalogId}`) to a playable `Song`.
    ///
    /// Used by synced ("radio") playback, where all a follower has is a
    /// broadcaster's `catalogId` — it looks the row up via `CatalogCache` and
    /// promotes it here so `PlayerViewModel.resolve` can find the track (via the
    /// Apple Music uri / ISRC / title+artist cascade). The catalog id is the
    /// document key, not a field on `CatalogTrack`, so it's passed separately.
    static func from(catalogTrack t: CatalogTrack, catalogId: String) -> Song {
        Song(
            id:               catalogId,
            title:            t.title,
            artist:           t.artist,
            album:            t.album,
            artwork:          t.artwork,
            trackId:          t.appleMusicTrackId ?? catalogId,
            uri:              t.appleMusicUri ?? "",
            catalogId:        catalogId,
            sourceService:    .appleMusic,
            isrc:             t.isrc,
            duration:         t.duration,
            trackNumber:      t.trackNumber,
            albumReleaseDate: t.albumReleaseDate
        )
    }

    /// Promote a `SearchItem` (track result row) to a playable `Song`.
    static func from(searchItem i: SearchItem) -> Song {
        Song(
            id:               i.key,
            title:            i.title,
            artist:           i.artist,
            album:            i.album,
            artwork:          i.artwork,
            trackId:          String(i.key.split(separator: ":").last ?? Substring(i.key)),
            uri:              i.uri,
            catalogId:        i.catalogId,
            sourceService:    i.sourceService,
            isrc:             i.isrc,
            duration:         i.duration,
            trackNumber:      i.trackNumber,
            albumReleaseDate: i.albumReleaseDate,
            isExplicit:       i.isExplicit,
            isPlayable:       i.isPlayable,
            releaseDate:      i.releaseDate
        )
    }
}

/// Demote a `Song` back to a library document, for the save/spotlight write
/// paths — `toggleLibrary` and `addToSpotlight` both take a `LibraryTrackDoc`,
/// and four screens were building this same value inline to call them.
///
/// `savedAt` is stamped now: a doc built here is always about to be written.
extension LibraryTrackDoc {
    static func from(song s: Song) -> LibraryTrackDoc {
        LibraryTrackDoc(
            catalogId:        s.catalogId ?? "",
            title:            s.title,
            artist:           s.artist,
            album:            s.album,
            artwork:          s.artwork,
            uri:              s.uri,
            sourceService:    s.sourceService,
            isrc:             s.isrc,
            duration:         s.duration,
            trackNumber:      s.trackNumber,
            albumReleaseDate: s.albumReleaseDate,
            genres:           s.genres,
            isExplicit:       s.isExplicit,
            savedAt:          Date().timeIntervalSince1970 * 1000
        )
    }
}
