#if DEBUG
import Foundation
import SwiftUI
import NodalongKit

/// Hardcoded fixtures used by SwiftUI `#Preview` blocks. Lives in the app target
/// so it ships only in DEBUG builds and never touches Firebase, MusicKit, or any
/// network code. Mock factories on view models build their preview state from
/// these values, so every screen renders consistent, realistic-looking data in
/// the Xcode canvas.
enum PreviewFixtures {

    // MARK: - Users

    static let myUid = "preview-uid-self"

    static let myProfile = UserProfile(
        uid: myUid,
        email: "you@example.com",
        username: "you",
        usernameLower: "you",
        bio: "Listening to everything, judging nothing.",
        avatarUrl: nil,
        avatarEmoji: "🦊",
        avatarColor: "#7C3AED",
        activeService: .appleMusic,
        geohash: "gcpvj0duz",
        lastActive: 1_750_000_000_000,
        spotlightTracks: [
            SpotlightTrack(
                trackId: "catalog-001",
                title: "Idea 1",
                artist: "Gilles Peterson",
                album: "Brownswood Bubblers",
                artwork: "",
                uri: "spotify:track:idea1",
                spotlitAt: 1_750_000_000_000,
                catalogId: "catalog-001",
                sourceService: .spotify
            )
        ],
        createdAt: 1_700_000_000_000,
        updatedAt: 1_750_000_000_000
    )

    static let friendProfile = UserProfile(
        uid: "preview-uid-friend",
        email: "friend@example.com",
        username: "alex",
        usernameLower: "alex",
        bio: "DJ, occasionally.",
        avatarUrl: nil,
        avatarEmoji: "🐻",
        avatarColor: "#F59E0B",
        activeService: .appleMusic,
        geohash: "gcpvj0due",
        lastActive: 1_750_000_000_000,
        spotlightTracks: [],
        createdAt: 1_700_000_000_000,
        updatedAt: 1_750_000_000_000
    )

    static let nearbyProfiles: [UserProfile] = [
        friendProfile,
        UserProfile(
            uid: "preview-uid-2", email: "b@example.com", username: "rio",
            usernameLower: "rio", bio: "", avatarEmoji: "🦁", avatarColor: "#10B981",
            activeService: .appleMusic, geohash: "gcpvj0dvk",
            lastActive: 1_750_000_000_000, spotlightTracks: [],
            createdAt: 1_700_000_000_000, updatedAt: 1_750_000_000_000
        ),
        UserProfile(
            uid: "preview-uid-3", email: "c@example.com", username: "kit",
            usernameLower: "kit", bio: "", avatarEmoji: "🐰", avatarColor: "#EF4444",
            activeService: .appleMusic, geohash: "gcpvj0dxn",
            lastActive: 1_750_000_000_000, spotlightTracks: [],
            createdAt: 1_700_000_000_000, updatedAt: 1_750_000_000_000
        ),
    ]

    // MARK: - Tracks

    static let song = Song(
        id: "preview-song-1",
        title: "Idea 1",
        artist: "Gilles Peterson",
        album: "Brownswood Bubblers Vol. 12",
        artwork: "",
        liked: false,
        nods: 7,
        trackId: "preview-song-1",
        uri: "spotify:track:preview1",
        userName: "alex",
        listenedAt: 1_750_000_000_000,
        catalogId: "catalog-001",
        sourceService: .spotify,
        isrc: "GBABC1234567",
        duration: 213_000,
        trackNumber: 3,
        albumReleaseDate: "2023-08-04"
    )

    static let songs: [Song] = [
        song,
        Song(
            id: "preview-song-2", title: "Sketch In E Flat",
            artist: "Surprise Chef", album: "Friendship",
            artwork: "", trackId: "preview-song-2",
            uri: "spotify:track:preview2",
            userName: "rio", listenedAt: 1_750_000_000_000,
            catalogId: "catalog-002", sourceService: .spotify,
            duration: 187_000
        ),
        Song(
            id: "preview-song-3", title: "Moonshine",
            artist: "Sault", album: "Untitled (Rise)",
            artwork: "", trackId: "preview-song-3",
            uri: "spotify:track:preview3",
            userName: "kit", listenedAt: 1_750_000_000_000,
            catalogId: "catalog-003", sourceService: .spotify,
            duration: 245_000
        ),
    ]

    static let libraryTracks: [LibraryTrackDoc] = [
        LibraryTrackDoc(
            catalogId: "catalog-001", title: "Idea 1", artist: "Gilles Peterson",
            album: "Brownswood Bubblers Vol. 12", artwork: "",
            uri: "spotify:track:preview1", sourceService: .spotify,
            isrc: "GBABC1234567", duration: 213_000, trackNumber: 3,
            albumReleaseDate: "2023-08-04", savedAt: 1_750_000_000_000
        ),
        LibraryTrackDoc(
            catalogId: "catalog-002", title: "Sketch In E Flat",
            artist: "Surprise Chef", album: "Friendship", artwork: "",
            uri: "spotify:track:preview2", sourceService: .spotify,
            duration: 187_000, savedAt: 1_750_000_000_000
        ),
        LibraryTrackDoc(
            catalogId: "catalog-003", title: "Moonshine", artist: "Sault",
            album: "Untitled (Rise)", artwork: "",
            uri: "spotify:track:preview3", sourceService: .spotify,
            duration: 245_000, savedAt: 1_750_000_000_000
        ),
    ]

    // MARK: - Catalog browse results

    static let artist = ArtistResult(
        id: "preview-artist-1",
        name: "Surprise Chef",
        imageUrl: "",
        genres: "instrumental, soul",
        followers: 84_000,
        sourceService: .spotify
    )

    static let album = AlbumResult(
        id: "preview-album-1",
        name: "Friendship",
        artistName: "Surprise Chef",
        artwork: "",
        releaseDate: "2024-09-13",
        totalTracks: 10,
        albumType: "album",
        sourceService: .spotify
    )

    // MARK: - Playlists

    static let playlists: [Playlist] = [
        Playlist(
            id: "preview-playlist-1", ownerUid: myUid, ownerUsername: "you",
            ownerAvatarEmoji: "🦊", ownerAvatarColor: "#7C3AED",
            title: "Late Night Drive", description: "windows down",
            coverArtwork: "", visibility: .friends, source: .manual,
            partyId: nil, contributorUids: [myUid], trackCount: 12,
            createdAt: 1_700_000_000_000, updatedAt: 1_750_000_000_000
        ),
        Playlist(
            id: "preview-playlist-2", ownerUid: myUid, ownerUsername: "you",
            ownerAvatarEmoji: "🦊", ownerAvatarColor: "#7C3AED",
            title: "alex's party · jul 4", description: nil,
            coverArtwork: "", visibility: .friends, source: .party,
            partyId: "preview-party-1",
            contributorUids: [myUid, "preview-uid-friend"], trackCount: 24,
            createdAt: 1_749_900_000_000, updatedAt: 1_749_980_000_000
        ),
    ]

    static let playlistTracks: [PlaylistTrack] = [
        PlaylistTrack(
            id: "pt-1", catalogId: "catalog-001", title: "Idea 1",
            artist: "Gilles Peterson", album: "Brownswood Bubblers Vol. 12",
            artwork: "", uri: "spotify:track:preview1", sourceService: .spotify,
            duration: 213_000, addedByUid: myUid, addedByUsername: "you",
            addedAt: 1_750_000_000_000, order: 1024
        ),
        PlaylistTrack(
            id: "pt-2", catalogId: "catalog-002", title: "Sketch In E Flat",
            artist: "Surprise Chef", album: "Friendship",
            artwork: "", uri: "spotify:track:preview2", sourceService: .spotify,
            duration: 187_000, addedByUid: myUid, addedByUsername: "you",
            addedAt: 1_750_000_000_000, order: 2048
        ),
    ]

    // MARK: - Party

    static let party = ListeningParty(
        id: "preview-party-1", hostUid: myUid, hostUsername: "you",
        hostAvatarEmoji: "🦊", hostAvatarColor: "#7C3AED",
        title: "friday night", status: .live, permission: .anyoneCanAdd,
        createdAt: 1_750_000_000_000
    )

    static let partyQueue: [PartyQueueTrack] = [
        PartyQueueTrack(
            id: "pq-1", catalogId: "catalog-001", title: "Idea 1",
            artist: "Gilles Peterson", album: "Brownswood Bubblers Vol. 12",
            artwork: "", uri: "spotify:track:preview1", sourceService: .spotify,
            duration: 213_000, addedByUid: myUid, addedByUsername: "you",
            addedAt: 1_750_000_000_000, order: 1024, played: true
        ),
        PartyQueueTrack(
            id: "pq-2", catalogId: "catalog-002", title: "Sketch In E Flat",
            artist: "Surprise Chef", album: "Friendship",
            artwork: "", uri: "spotify:track:preview2", sourceService: .spotify,
            duration: 187_000, addedByUid: "preview-uid-friend", addedByUsername: "alex",
            addedAt: 1_750_000_000_000, order: 2048, played: false
        ),
    ]

    static let partyParticipants: [PartyParticipant] = [
        PartyParticipant(id: myUid, username: "you", avatarEmoji: "🦊", avatarColor: "#7C3AED", joinedAt: 1_750_000_000_000),
        PartyParticipant(id: "preview-uid-friend", username: "alex", avatarEmoji: "🐻", avatarColor: "#F59E0B", joinedAt: 1_750_000_100_000),
    ]

    // MARK: - Posts (feed)

    static let posts: [Post] = [
        Post(
            id: "preview-post-1",
            uid: "preview-uid-friend", username: "alex",
            avatarEmoji: "🐻", avatarColor: "#F59E0B",
            catalogId: "catalog-001",
            title: "Idea 1", artist: "Gilles Peterson",
            album: "Brownswood Bubblers Vol. 12", artwork: "",
            uri: "spotify:track:preview1", sourceService: .appleMusic,
            nods: 12, isSpotlit: true, geohash: "gcpvj0due",
            createdAt: 1_750_000_000_000,
            sourceUid: "preview-uid-friend", trackId: "preview-song-1"
        ),
        Post(
            id: "preview-post-2",
            uid: "preview-uid-2", username: "rio",
            avatarEmoji: "🦁", avatarColor: "#10B981",
            catalogId: "catalog-002",
            title: "Sketch In E Flat", artist: "Surprise Chef",
            album: "Friendship", artwork: "",
            uri: "spotify:track:preview2", sourceService: .appleMusic,
            nods: 4, isSpotlit: false, geohash: "gcpvj0dvk",
            createdAt: 1_750_000_000_000,
            sourceUid: "preview-uid-2", trackId: "preview-song-2"
        ),
        Post(
            id: "preview-post-3",
            uid: "preview-uid-3", username: "kit",
            avatarEmoji: "🐰", avatarColor: "#EF4444",
            catalogId: "catalog-003",
            title: "Moonshine", artist: "Sault",
            album: "Untitled (Rise)", artwork: "",
            uri: "spotify:track:preview3", sourceService: .appleMusic,
            nods: 2, isSpotlit: false, geohash: "gcpvj0dxn",
            createdAt: 1_750_000_000_000,
            sourceUid: "preview-uid-3", trackId: "preview-song-3"
        ),
        Post(
            id: "preview-post-4",
            uid: "preview-uid-friend", username: "alex",
            avatarEmoji: "🐻", avatarColor: "#F59E0B",
            catalogId: "catalog-004",
            title: "Buggin' Out", artist: "A Tribe Called Quest",
            album: "The Low End Theory", artwork: "",
            uri: "spotify:track:preview4", sourceService: .appleMusic,
            nods: 8, isSpotlit: false, geohash: "gcpvj0due",
            createdAt: 1_749_990_000_000,
            sourceUid: "preview-uid-friend", trackId: "preview-song-4"
        ),
        Post(
            id: "preview-post-5",
            uid: "preview-uid-2", username: "rio",
            avatarEmoji: "🦁", avatarColor: "#10B981",
            catalogId: "catalog-005",
            title: "All Things Considered", artist: "Clipse",
            album: "Hell Hath No Fury", artwork: "",
            uri: "spotify:track:preview5", sourceService: .appleMusic,
            nods: 1, isSpotlit: true, geohash: "gcpvj0dvk",
            createdAt: 1_749_980_000_000,
            sourceUid: "preview-uid-2", trackId: "preview-song-5"
        ),
    ]
}

/// `true` when the current process is the Xcode preview agent. Used by view
/// models whose `init()` would otherwise touch Firebase, MusicKit, or system
/// audio — services that are unavailable inside the preview sandbox.
var isRunningInPreview: Bool {
    ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
}

extension View {
    /// Injects every `@EnvironmentObject` the app's feature views depend on
    /// with mock state. Lets `#Preview` blocks for any screen be a one-liner.
    func withPreviewEnvironment() -> some View {
        // One player instance so its `clock` (injected separately, for the
        // scrubber) is the same object the VM mutates.
        let player = PlayerViewModel.mockPreview
        return self
            .environment(FirebaseAuthViewModel.mockPreview)
            .environmentObject(AppleMusicService.mockPreview)
            .environmentObject(SpotifyMusicService.mockPreview)
            .environmentObject(player)
            .environmentObject(player.clock)
            .environmentObject(LibraryViewModel.mockPreview)
            .environmentObject(FeedViewModel.mockPreview)
            .environmentObject(ShelfViewModel.mockPreview)
            .environmentObject(NearMeViewModel.mockPreview)
            .environmentObject(SearchViewModel.mockPreview)
            .environmentObject(PlaylistsViewModel.mockPreview)
            .environmentObject(ListeningPartyViewModel.mockPreview)
            .environmentObject(HomeViewModel.mockPreview)
            .environmentObject(InboxViewModel.mockPreview)
            .environmentObject(TasteOverridesStore.mockPreview)
            .environmentObject(NowPlayingBroadcastService())
            .environmentObject(SyncFollowCoordinator())
            .environmentObject(LibrarySyncService())
            .environmentObject(LocationService())
            .environmentObject(PlaylistGenerator())
            .environmentObject(HomeLayoutPreferences.mockPreview)
            // Pre-existing gap: HomeView has required AppRouter since the
            // router migration but it was never registered here, so its
            // preview couldn't render. One line, so fixed in passing.
            .environmentObject(AppRouter())
    }
}
#endif
