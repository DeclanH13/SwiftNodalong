import SwiftUI
import NodalongKit

/// Another user's profile, opened by tapping their avatar or username.
///
/// Read-only version of `ProfileView` plus a follow/unfollow button. Recent
/// tracks are playable and can be nodded; spotlight history is read-only.
struct UserProfileView: View {
    let user: UserProfile

    @Environment(FirebaseAuthViewModel.self) private var authVM
    @EnvironmentObject private var playerVM:       PlayerViewModel
    @EnvironmentObject private var musicService:   AppleMusicService
    @EnvironmentObject private var spotifyService: SpotifyMusicService
    @EnvironmentObject private var libraryVM:      LibraryViewModel

    /// Whichever backend is actually connected — the play gate must check
    /// this, not hardcode Apple Music.
    private var activeService: any MusicService {
        activeMusicService(playerVM: playerVM, apple: musicService, spotify: spotifyService)
    }

    @State private var following        = false
    @State private var followerCount    = 0
    @State private var followLoading    = false
    @State private var recentTracks:    [Post] = []
    @State private var playlists:       [Playlist] = []
    @State private var spotlightHistory: [SpotlightTrack] = []
    /// Enriched copy of the passed-in `user.spotlightTracks` (which may be slim
    /// depending on where `user` came from). Populated in `loadData`.
    @State private var activeSpotlights: [SpotlightTrack] = []

    private var isOwnProfile: Bool {
        authVM.currentUser?.uid == user.uid
    }

    /// CatalogIds `user` has spotlit today — drives the recent-tracks
    /// spotlight badge. Mirrors `FirebaseAuthViewModel.todaySpotlitIds`.
    private var todaySpotlitCatalogIds: Set<String> {
        let todayKey = dateKey(epochMs: Date().timeIntervalSince1970 * 1000)
        return Set(activeSpotlights
            .filter { dateKey(epochMs: $0.spotlitAt) == todayKey }
            .compactMap { $0.catalogId })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                avatarSection
                spotlightSection
                playlistsSection
                recentTracksSection

            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        .background(Color.nodalong.bgBase)
        .navigationTitle(user.username)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Playlist.self) { playlist in
            PlaylistDetailView(playlist: playlist)
        }
        .task { await loadData() }
    }

    // MARK: - Spotlight

    /// Builds the SpotlightDay collection from `user.spotlightTracks`
    /// (today's active set) + `spotlightHistory` (all past spotlights).
    /// Mirrors `ProfileView.buildSpotlightDays` but read-only.
    private func buildSpotlightDays() -> [SpotlightDay] {
        let active   = activeSpotlights
        let todayKey = dateKey(epochMs: Date().timeIntervalSince1970 * 1000)
        // The embedded `spotlightTracks[]` field is only pruned to
        // "today only" as a side effect of the profile owner's NEXT
        // spotlight write — if they haven't spotlit anything yet today,
        // Firestore still holds yesterday's entries verbatim. Filter by
        // each track's own date rather than trusting the field's contents
        // (this is what made yesterday's spotlights show under "Today" when
        // viewing someone who hasn't spotlit anything yet on the current day).
        let activeToday = active.filter { dateKey(epochMs: $0.spotlitAt) == todayKey }

        var grouped: [String: [SpotlightTrack]] = [:]
        for track in spotlightHistory {
            let key = dateKey(epochMs: track.spotlitAt)
            if key != todayKey {
                grouped[key, default: []].append(track)
            }
        }
        if !activeToday.isEmpty { grouped[todayKey] = activeToday }

        return grouped.keys.sorted().map { key in
            SpotlightDay(dateKey: key, tracks: grouped[key]!, isToday: key == todayKey)
        }
    }

    // MARK: - Sections

    private var avatarSection: some View {
        VStack(spacing: 12) {
            AvatarView(
                emoji:    user.avatarEmoji,
                colorHex: user.avatarColor,
                size:     96
            )
            Text(user.username)
                .font(Font.nodalong.title2Bold)
                .foregroundStyle(Color.nodalong.textPrimary)

            NavigationLink(value: FollowListTarget(
                uid: user.uid, username: user.username, mode: .followers
            )) {
                Text("\(followerCount) follower\(followerCount == 1 ? "" : "s")")
                    .font(Font.nodalong.subheadline)
                    .foregroundStyle(Color.nodalong.textSecondary)
            }
            .buttonStyle(.plain)

            if !user.bio.isEmpty {
                Text(user.bio)
                    .font(Font.nodalong.subheadline)
                    .foregroundStyle(Color.nodalong.textSecondary)
                    .multilineTextAlignment(.center)
            }

            if !isOwnProfile {
                followButton
            }
        }
    }

    private var followButton: some View {
        Button {
            guard !followLoading, let myUid = authVM.currentUser?.uid else { return }
            followLoading = true
            Task {
                if following {
                    try? await unfollowUser(myUid: myUid, targetUid: user.uid)
                    followerCount = max(0, followerCount - 1)
                    following = false
                } else {
                    let myUsername = authVM.profile?.username ?? ""
                    try? await followUser(myUid: myUid, myUsername: myUsername,
                                         targetUid: user.uid, targetUsername: user.username)
                    followerCount += 1
                    following = true
                }
                followLoading = false
            }
        } label: {
            Group {
                if followLoading {
                    ProgressView().tint(.white)
                } else {
                    Text(following ? "Following" : "Follow")
                        .font(Font.nodalong.subheadlineSemibold)
                        .foregroundStyle(following ? Color.nodalong.textPrimary : Color.nodalong.textOnAccent)
                }
            }
            .frame(width: 120, height: 36)
            .background(following ? Color.nodalong.bgCard : Color.nodalong.purpleMid)
            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Corner.container, style: .continuous)
                    .strokeBorder(following ? Color.nodalong.textSecondary : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// Swipeable historic spotlight carousel — same component as on the
    /// user's own profile, but **read-only** (no `onRemove` callback so the
    /// star never becomes an "un-spotlight" button).
    @ViewBuilder
    private var spotlightSection: some View {
        let days = buildSpotlightDays()
        VStack(alignment: .leading, spacing: 12) {
            Text("Spotlight")
                .font(Font.nodalong.headline)
                .foregroundStyle(Color.nodalong.textPrimary)

            if days.isEmpty {
                Text("\(user.username) hasn't spotlit any tracks yet.")
                    .font(Font.nodalong.subheadline)
                    .foregroundStyle(Color.nodalong.textSecondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.nodalong.bgCard)
                    .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
            } else {
                SpotlightCarousel(
                    days: days,
                    onPlay: { track in
                        guard activeService.isAuthenticated else { return }
                        Task { await playerVM.play(.from(spotlight: track)) }
                    },
                    onAddToQueue: { track in
                        playerVM.addToQueue(.from(spotlight: track))
                    }
                )
            }
        }
    }

    /// Read-only horizontal rail of this user's playlists (private ones are
    /// filtered out in `loadData`). Tapping a tile opens the shared, read-only
    /// `PlaylistDetailView` (owner-only edit affordances hide for non-owners).
    @ViewBuilder
    private var playlistsSection: some View {
        if !playlists.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Playlists")
                    .font(Font.nodalong.headline)
                    .foregroundStyle(Color.nodalong.textPrimary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(playlists) { playlist in
                            NavigationLink(value: playlist) {
                                PlaylistTile(playlist: playlist).frame(width: 132)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    /// Other-user recent tracks — same paged carousel as own profile, but
    /// with the spotlight callback disabled (`onSpotlight: nil`) so the
    /// star button on each card doesn't appear.
    @ViewBuilder
    private var recentTracksSection: some View {
        if !recentTracks.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recent Tracks")
                    .font(Font.nodalong.headline)
                    .foregroundStyle(Color.nodalong.textPrimary)

                RecentTracksCarousel(
                    posts:     recentTracks,
                    isSpotlit: { todaySpotlitCatalogIds.contains($0.catalogId) },
                    isLiked:   { libraryVM.isInLibrary(catalogId: $0.catalogId, uri: $0.uri) },
                    onPlay:    { post in
                        guard activeService.isAuthenticated else { return }
                        Task { await playerVM.play(.from(post: post)) }
                    },
                    onSpotlight: nil,
                    onLike: { post in
                        guard let uid = authVM.currentUser?.uid else { return }
                        let doc = LibraryTrackDoc(
                            catalogId: post.catalogId, title: post.title,
                            artist: post.artist, album: post.album,
                            artwork: post.artwork, uri: post.uri,
                            sourceService: post.sourceService,
                            savedAt: Date().timeIntervalSince1970 * 1000
                        )
                        Task { await libraryVM.toggleLibrary(uid: uid, track: doc) }
                    },
                    onAddToQueue: { post in
                        playerVM.addToQueue(.from(post: post))
                    }
                )
            }
        }
    }

    // MARK: - Private

    /// Parallel fetch of everything needed for the screen — follow status,
    /// follower count, recent listens, full spotlight history.
    private func loadData() async {
        guard let myUid = authVM.currentUser?.uid else { return }

        // Warm read first — usually already populated by browse-time prefetch
        // from wherever the user arrived (Search results, NearMe, a follow
        // list). Identity (avatar/username/bio) was already instant because
        // the pushed `UserProfile` carries it; this is what used to arrive
        // late and make the spotlight carousel and recents rail pop in.
        if let warm = await SocialCache.shared.cachedBundle(uid: user.uid) {
            apply(warm)
        }

        // Independent of the bundle — runs concurrently with it.
        async let spotlights = enrichSpotlights(user.spotlightTracks)

        // Cold miss fetches; an in-flight prefetch is JOINED, not duplicated.
        apply(await SocialCache.shared.bundle(uid: user.uid, viewerUid: myUid))
        activeSpotlights = await spotlights

        // Their follower/following list is one tap from here.
        SocialCache.shared.prefetchFollowLists(uid: user.uid)
    }

    /// Guarded assignments — SwiftUI re-renders on every `@State` write even
    /// when the value is identical, which is what makes a refresh visible on
    /// a revisit where nothing actually changed. Same convention as
    /// `ProfileView.refresh()`.
    private func apply(_ b: ProfileBundle) {
        if following        != b.isFollowing      { following        = b.isFollowing }
        if followerCount    != b.followerCount    { followerCount    = b.followerCount }
        if recentTracks     != b.recentTracks     { recentTracks     = b.recentTracks }
        if spotlightHistory != b.spotlightHistory { spotlightHistory = b.spotlightHistory }
        if playlists        != b.playlists        { playlists        = b.playlists }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        UserProfileView(user: PreviewFixtures.friendProfile)
    }
    .withPreviewEnvironment()
}
#endif
