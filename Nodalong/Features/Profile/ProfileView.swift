import SwiftUI
import MusicKit
import NodalongKit

/// The current user's own profile screen.
///
/// Shows username, avatar, bio, follower/following counts, recent tracks,
/// spotlight history, and Apple Music status (authorization + subscription).
/// Settings menu: edit profile, sign out, reconnect Apple Music. Tap a recent
/// track → play; tap a follower/following count → FollowListView.
struct ProfileView: View {
    @Environment(FirebaseAuthViewModel.self) private var authVM
    @EnvironmentObject private var musicService:  AppleMusicService
    @EnvironmentObject private var spotifyService: SpotifyMusicService
    @EnvironmentObject private var syncService:  LibrarySyncService
    @EnvironmentObject private var shelfVM:      ShelfViewModel
    @EnvironmentObject private var playerVM:     PlayerViewModel
    @EnvironmentObject private var libraryVM:    LibraryViewModel
    @EnvironmentObject private var playlistsVM:  PlaylistsViewModel

    /// Whichever backend is actually connected — the play gate must check
    /// this, not hardcode Apple Music.
    private var activeService: any MusicService {
        activeMusicService(playerVM: playerVM, apple: musicService, spotify: spotifyService)
    }

    /// Whether Apple Music / Spotify is the user's *linked* service, per the
    /// persisted `activeService` — NOT `musicService.isAuthenticated` /
    /// `spotifyService.isAuthenticated`. Apple Music's raw flag silently
    /// resurrects to `true` on every relaunch (MusicKit has no per-app
    /// revoke), so it can't be trusted as a "connected" signal for display
    /// or gating; the persisted, explicitly-written `activeService` is the
    /// only durable source of truth (see `setActiveMusicService`).
    private var isAppleLinked:   Bool { authVM.profile?.activeService == .appleMusic }
    private var isSpotifyLinked: Bool { authVM.profile?.activeService == .spotify }

    @State private var showEdit          = false
    @State private var followerCount     = 0
    @State private var followingCount    = 0
    @State private var recentTracks:    [Post]           = []
    /// `nil` while the initial fetch is in-flight (shows skeleton placeholder
    /// to prevent the "layout jump" when spotlight tracks push recents down).
    /// `[]` once loaded with no history. `[...]` once loaded with data.
    @State private var spotlightHistory: [SpotlightTrack]? = nil
    /// Owned locally rather than via `NavigationLink(value:)` — see
    /// `PlaylistsProfileSection`'s doc comment for why stacking a
    /// type-based push on top of `ProfileView`'s own boolean-based push
    /// (from `ProfileEntryPoint`) was unreliable.
    // Explicit module qualification — `MusicKit` (imported above) also
    // declares a `Playlist` type, and unlike the previous
    // `NavigationLink(value:)` call site (disambiguated by the array
    // element type flowing in from `PlaylistsViewModel`), a bare `Playlist`
    // annotation here has nothing to infer from.
    @State private var selectedPlaylist: NodalongKit.Playlist? = nil
    /// Guards against re-fetching on every tab re-visit within a session.
    @State private var hasLoaded = false

    /// Bound to the system `.musicSubscriptionOffer(...)` modifier. Flipping
    /// to `true` presents Apple's first-party Apple Music sign-up sheet.
    @State private var showSubscriptionOffer = false

    /// Backs `appearanceSection`'s picker — shares `appearanceModeKey` with
    /// `NodalongApp`, which reads the same key to drive
    /// `.preferredColorScheme(_:)`, so a change here applies immediately.
    @AppStorage(appearanceModeKey) private var appearanceModeRaw = AppearanceMode.system.rawValue

    /// Backs `albumArtworkSection`'s picker. Unlike `appearanceModeRaw`,
    /// nothing else needs to read this at the app root — every
    /// `ArtworkThumbnail(isAlbum: true)` instance reads the same key
    /// directly, so a change here reaches them immediately with no extra
    /// wiring.
    @AppStorage(albumArtworkStyleKey) private var albumArtworkStyleRaw = AlbumArtworkStyle.vinyl.rawValue

    /// Confirms before disconnecting Apple Music (tapping the "Connected"/
    /// "Preview" button) rather than disconnecting immediately.
    @State private var showDisconnectConfirm = false

    var body: some View {
        // `@Bindable` is required to derive a `$` binding from an
        // `@Observable` object held in the environment.
        @Bindable var authVM = authVM

        // NOTE: deliberately no owned NavigationStack here — `ProfileView`'s
        // only real (non-preview) call site is `ProfileEntryPoint`, which
        // already pushes it onto an existing host stack (Home/Feed/NearMe/
        // Shelf). Wrapping it in a second, nested NavigationStack meant
        // `.navigationDestination(for: FollowListTarget.self)` below was
        // declared on an inner stack nested inside another — pushing
        // Followers/Following from there hit SwiftUI's nested-stack
        // navigation bug (white screen, auto pop-back). The three
        // `.navigationDestination(for:)` modifiers below work identically
        // whether declared on an owned or an inherited stack.
        ScrollView {
            VStack(spacing: 24) {
                avatarSection
                statsSection
                spotlightSection
                PlaylistsProfileSection(onSelectPlaylist: { selectedPlaylist = $0 })
                recentTracksSection
                musicSection
                appearanceSection
                albumArtworkSection
                signOutButton
                // Breathing room between Sign Out and the mini player.
                // Matches the FeedView pattern — only added when something
                // is playing so the profile fills normally at rest.
                if playerVM.nowPlaying != nil {
                    Color.clear.frame(height: 70)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        // Pull-to-refresh on your own profile also re-syncs from
        // whichever service is connected first (not just re-reading
        // Firestore) — lets a user pull down to fetch tracks played
        // moments ago, on demand, rather than waiting for the next
        // foreground-return sync.
        .refreshable {
            if let uid = authVM.currentUser?.uid {
                if isAppleLinked {
                    await syncService.syncAndWait(uid: uid, service: musicService)
                } else if isSpotifyLinked {
                    await syncService.syncSpotifyAndWait(uid: uid, service: spotifyService)
                }
            }
            await refresh()
        }
        .background(Color.nodalong.bgBase)
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedPlaylist) { playlist in
            PlaylistDetailView(playlist: playlist)
        }
        // Both destinations a follow-list flow needs, registered together on
        // every stack that can host it.
        //
        // `FollowListTarget` is pushed with a plain `NavigationLink(value:)`,
        // NOT `.navigationDestination(item:)`. An item-based push re-presents
        // itself whenever something is pushed ON TOP of it (the bound item is
        // still non-nil), which is exactly the bug Round 9.9 hit with
        // `discographyGridTab` — and it's what made tapping a NAME inside a
        // follow list show a second copy of the follow list instead of that
        // person's profile.
        //
        // `UserProfile` has to be here too: `FollowListView`'s rows push one, so
        // without it a row tap has no destination on this stack. Every closure
        // below builds purely from the pushed value, so the duplicate
        // registrations across stacks are behaviourally identical — which is the
        // property that actually makes this safe, not uniqueness.
        .navigationDestination(for: FollowListTarget.self) { t in
            FollowListView(uid: t.uid, mode: t.mode, username: t.username)
        }
        .navigationDestination(for: UserProfile.self) { user in
            UserProfileView(user: user)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Edit") { showEdit = true }
                    .foregroundStyle(Color.nodalong.purpleAccent)
            }
        }
        .sheet(isPresented: $showEdit) {
            EditProfileView()
        }
        .alert("Daily Limit Reached", isPresented: $authVM.spotlightLimitReached) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You can only spotlight \(maxSpotlights) tracks per day. Remove one to swap it out.")
        }
        .task {
            guard !hasLoaded else { return }
            await refresh()
        }
        .onChange(of: syncService.lastSyncedAt) {
            Task { await refresh() }
        }
    }

    // MARK: - Sections

    private var avatarSection: some View {
        VStack(spacing: 12) {
            AvatarView(
                emoji:    authVM.profile?.avatarEmoji,
                colorHex: authVM.profile?.avatarColor,
                size:     96
            )
            Text(authVM.profile?.username ?? "")
                .font(Font.nodalong.title2Bold)
                .foregroundStyle(Color.nodalong.textPrimary)
            if let bio = authVM.profile?.bio, !bio.isEmpty {
                Text(bio)
                    .font(Font.nodalong.subheadline)
                    .foregroundStyle(Color.nodalong.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// Builds a fully-specified push value. See `FollowListTarget` — the
    /// uid has to travel WITH the value, not come from whichever screen's
    /// destination closure SwiftUI happens to pick.
    private func followListTarget(_ mode: FollowListMode) -> FollowListTarget {
        FollowListTarget(
            uid: authVM.currentUser?.uid ?? "",
            username: authVM.profile?.username ?? "",
            mode: mode
        )
    }

    private var statsSection: some View {
        HStack(spacing: 24) {
            NavigationLink(value: followListTarget(.followers)) {
                StatCell(value: "\(followerCount)", label: "Followers")
            }
            .buttonStyle(.plain)
            NavigationLink(value: followListTarget(.following)) {
                StatCell(value: "\(followingCount)", label: "Following")
            }
            .buttonStyle(.plain)
            StatCell(value: "\(shelfVM.tracks.count)", label: "Tracks")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color.nodalong.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
    }

    @ViewBuilder
    private var spotlightSection: some View {
        let days = buildSpotlightDays()
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Spotlight")
                    .font(Font.nodalong.headline)
                    .foregroundStyle(Color.nodalong.textPrimary)
                Spacer()
                let todayCount = authVM.profile?.spotlightTracks.count ?? 0
                Text("\(todayCount)/\(maxSpotlights) today")
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textSecondary)
            }

            if spotlightHistory == nil {
                // Still loading — reserve the same height as a single-track
                // carousel so recentTracksSection doesn't jump down when data arrives.
                RoundedRectangle(cornerRadius: Corner.container, style: .continuous)
                    .fill(Color.nodalong.bgCard.opacity(0.5))
                    .frame(height: 188)
                    .redacted(reason: .placeholder)
            } else if days.isEmpty {
                Text("Tap the star on feed cards or shelf tracks to spotlight them.")
                    .font(Font.nodalong.subheadline)
                    .foregroundStyle(Color.nodalong.textSecondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.nodalong.bgCard)
                    .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
            } else {
                SpotlightCarousel(
                    days: days,
                    onRemove: { trackId in
                        Task { await authVM.removeFromSpotlight(trackId: trackId) }
                    },
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

    /// Own-profile recent tracks — full callback set: tap to play, star to
    /// spotlight (subject to the 3/day cap), heart to add to shelf.
    /// Renders via the shared paged carousel so the layout matches
    /// `UserProfileView` exactly.
    @ViewBuilder
    private var recentTracksSection: some View {
        if !recentTracks.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recent Tracks")
                    .font(Font.nodalong.headline)
                    .foregroundStyle(Color.nodalong.textPrimary)

                RecentTracksCarousel(
                    posts:     recentTracks,
                    isSpotlit: { authVM.todaySpotlitIds.contains($0.catalogId) },
                    isLiked:   { libraryVM.isInLibrary(catalogId: $0.catalogId, uri: $0.uri) },
                    onPlay:    { post in
                        guard activeService.isAuthenticated else { return }
                        Task { await playerVM.play(.from(post: post)) }
                    },
                    onSpotlight: { post in
                        let isSpotlit = authVM.todaySpotlitIds.contains(post.catalogId)
                        Task {
                            if isSpotlit {
                                await authVM.removeFromSpotlight(trackId: post.catalogId)
                            } else {
                                let doc = LibraryTrackDoc(
                                    catalogId: post.catalogId, title: post.title,
                                    artist: post.artist, album: post.album,
                                    artwork: post.artwork, uri: post.uri,
                                    sourceService: post.sourceService,
                                    savedAt: Date().timeIntervalSince1970 * 1000
                                )
                                await authVM.addToSpotlight(doc)
                            }
                        }
                    },
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

    /// Apple Music status + subscription panel. Spotify support is currently
    /// suspended — see `AppleMusicIcon`'s call sites and `ContentView`'s
    /// launch-time migration for accounts previously linked to Spotify.
    private var musicSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Music Services")
                .font(Font.nodalong.headline)
                .foregroundStyle(Color.nodalong.textPrimary)

            appleMusicButton
        }
        // Bound system sheet for starting an Apple Music subscription.
        // Renders the Apple-styled offer UI; we don't manage the copy.
        .musicSubscriptionOffer(isPresented: $showSubscriptionOffer)
        .alert("Disconnect Apple Music?", isPresented: $showDisconnectConfirm) {
            Button("Disconnect", role: .destructive) { disconnectAppleMusic() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need to reconnect to keep playing music through Nodalong.")
        }
    }

    /// System / Light / Dark override, backed by `AppearanceMode` +
    /// `@AppStorage(appearanceModeKey)` — the same key `NodalongApp` reads
    /// to drive `.preferredColorScheme(_:)`, so picking a segment here takes
    /// effect immediately with no extra plumbing.
    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Appearance")
                .font(Font.nodalong.headline)
                .foregroundStyle(Color.nodalong.textPrimary)

            Picker("Appearance", selection: $appearanceModeRaw) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .padding(12)
            .background(Color.nodalong.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        }
    }

    /// Square / Vinyl artwork toggle, backed by `AlbumArtworkStyle` +
    /// `@AppStorage(albumArtworkStyleKey)` — every `ArtworkThumbnail(isAlbum:
    /// true)` (album carousels/headers/grids, the artist page's discography)
    /// AND `ArtworkThumbnail(isTrack: true)` (every track row app-wide —
    /// playlists, Top Songs, Liked, Feed, Search, Queue, Party, NearMe) read
    /// the same key directly, so picking a segment here takes effect
    /// immediately with no extra plumbing. Also drives the mini player's
    /// disc content and both players' main-artwork shape/spin (see
    /// `MiniPlayerBar`, `NowPlayingView.artworkSection`,
    /// `PartyView.nowPlayingHero`). Playlist covers and artist photos are
    /// unaffected — neither opts into `isAlbum`/`isTrack`. Property/enum/key
    /// names (`albumArtworkStyleRaw`/`AlbumArtworkStyle`/
    /// `albumArtworkStyleKey`) kept as originally named — purely internal,
    /// not worth a rename now that 25+ call sites reference them; only the
    /// user-facing label changed to reflect the broader scope.
    private var albumArtworkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Artwork Style")
                .font(Font.nodalong.headline)
                .foregroundStyle(Color.nodalong.textPrimary)

            Picker("Artwork Style", selection: $albumArtworkStyleRaw) {
                ForEach(AlbumArtworkStyle.allCases) { style in
                    Text(style.label).tag(style.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .padding(12)
            .background(Color.nodalong.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        }
    }

    private func connectAppleMusic() {
        Task {
            try? await musicService.authorize()
            guard musicService.isAuthenticated, let uid = authVM.currentUser?.uid else { return }
            await setActiveMusicService(.appleMusic, uid: uid, playerVM: playerVM, authVM: authVM)
        }
    }

    private func disconnectAppleMusic() {
        Task {
            try? await musicService.logout()
            if let uid = authVM.currentUser?.uid {
                await setActiveMusicService(nil, uid: uid, playerVM: playerVM, authVM: authVM)
            }
        }
    }

    // MARK: - Music section

    /// The single consolidated Apple Music button — cycles between "Connect
    /// Apple Music" (not linked), "Connected" (linked, active subscription),
    /// and "Preview" (linked, no active subscription), replacing what used to
    /// be a separate status row + subscription row + connect/disconnect pill.
    /// Tapping while linked asks to disconnect (`showDisconnectConfirm`)
    /// rather than disconnecting immediately.
    ///
    /// The denied-permission recovery ("Open Settings") stays a distinct
    /// affordance — a different action class (a system-permission recovery),
    /// not a connection-state toggle — so it isn't folded into this button.
    @ViewBuilder
    private var appleMusicButton: some View {
        if musicService.isDenied {
            VStack(spacing: 6) {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    actionLabel("Open Settings")
                }
                Text("Enable Apple Music in Settings → Nodalong → Media & Apple Music.")
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textSecondary)
                    .multilineTextAlignment(.center)
            }
        } else {
            VStack(spacing: 6) {
                Button {
                    if isAppleLinked {
                        showDisconnectConfirm = true
                    } else {
                        connectAppleMusic()
                    }
                } label: {
                    HStack(spacing: 8) {
                        AppleMusicIcon(size: 20)
                        Text(appleMusicButtonLabel)
                            .font(Font.nodalong.subheadlineMedium)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.nodalong.appleMusicRed)
                    .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                }

                if isAppleLinked && !musicService.canPlayFullTracks && musicService.canBecomeSubscriber {
                    Button {
                        showSubscriptionOffer = true
                    } label: {
                        Text("Subscribe to Apple Music")
                            .font(Font.nodalong.captionMedium)
                            .foregroundStyle(Color.nodalong.purpleAccent)
                    }
                }

                if isAppleLinked {
                    if syncService.isSyncing {
                        ProgressView().tint(Color.nodalong.textSecondary)
                    } else if let at = syncService.lastSyncedAt {
                        Text("Synced \(at.formatted(date: .omitted, time: .shortened))")
                            .font(Font.nodalong.caption2)
                            .foregroundStyle(Color.nodalong.textSecondary)
                    }
                }
            }
        }
    }

    /// "Connected" is shown optimistically as soon as `isAppleLinked` is true
    /// — including while `musicService.subscription` hasn't loaded yet —
    /// relabeling to "Preview" only once a subscription snapshot resolves
    /// with no active plan. Deliberately drops the old three-row design's
    /// transient "Checking subscription…" state to keep this one button to
    /// three clean labels.
    private var appleMusicButtonLabel: String {
        guard isAppleLinked else { return "Connect Apple Music" }
        guard musicService.subscription != nil else { return "Connected" }
        return musicService.canPlayFullTracks ? "Connected" : "Preview"
    }

    /// Common pill style used by the recovery/upsell buttons above.
    private func actionLabel(_ text: String) -> some View {
        Text(text)
            .font(Font.nodalong.subheadlineMedium)
            .foregroundStyle(Color.nodalong.purpleAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.nodalong.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
    }

    private var signOutButton: some View {
        Button {
            authVM.signOut()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: Icons.logOutOutline)
                Text("Sign Out")
            }
            .font(Font.nodalong.subheadlineMedium)
            .foregroundStyle(Color.nodalong.error)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.nodalong.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        }
    }

    // MARK: - Private

    /// Everything on this screen that's worth surviving a tab switch or a
    /// relaunch. `spotlightTracks` for TODAY are deliberately absent — those
    /// come from `authVM.profile`, which is already loaded at auth and
    /// renders instantly; it's the historic carousel that was cold.
    private struct ProfileSnapshot: Codable {
        var spotlightHistory: [SpotlightTrack]
        var recentTracks: [Post]
        var followerCount: Int
        var followingCount: Int
    }

    /// Stale-while-revalidate, same pattern Home and Feed already use via the
    /// shared `SnapshotStore` — Profile was the one screen with no cache at
    /// all, so every visit paid a cold network read and showed the spotlight
    /// skeleton before anything appeared.
    private func restoreSnapshot(uid: String) {
        guard spotlightHistory == nil,
              let snap = SnapshotStore.load(ProfileSnapshot.self, key: "profile", uid: uid)
        else { return }
        spotlightHistory = snap.spotlightHistory
        recentTracks     = snap.recentTracks
        followerCount    = snap.followerCount
        followingCount   = snap.followingCount
    }

    private func refresh() async {
        guard let uid = authVM.currentUser?.uid else { return }
        // Paint last session's content before any network call starts.
        restoreSnapshot(uid: uid)

        async let fCount = getFollowerCount(uid: uid)
        async let gCount = getFollowingCount(uid: uid)
        async let posts  = getYourMusicFeed(uid: uid)
        async let hist   = getSpotlightHistory(uid: uid)
        await playlistsVM.reload(uid: uid)

        let newFollowers = (try? await fCount) ?? 0
        let newFollowing = (try? await gCount) ?? 0
        let newPosts     = (try? await posts)  ?? []
        // Assign non-nil to stop showing the skeleton; empty array is fine.
        let newHistory   = (try? await hist)   ?? []

        // Guarded assignments — SwiftUI re-renders on every `@State` write
        // even when the value is identical, which is exactly what made the
        // refresh visible on a revisit where nothing had actually changed.
        if followerCount    != newFollowers { followerCount    = newFollowers }
        if followingCount   != newFollowing { followingCount   = newFollowing }
        if recentTracks     != newPosts     { recentTracks     = newPosts }
        if spotlightHistory != newHistory   { spotlightHistory = newHistory }
        hasLoaded = true

        // One tap away: the follower/following counts are right there on
        // screen, so resolve those lists now rather than when tapped.
        SocialCache.shared.prefetchFollowLists(uid: uid)

        SnapshotStore.save(
            ProfileSnapshot(
                spotlightHistory: newHistory,
                recentTracks: newPosts,
                followerCount: newFollowers,
                followingCount: newFollowing
            ),
            key: "profile", uid: uid
        )
    }

    private func buildSpotlightDays() -> [SpotlightDay] {
        let active   = authVM.profile?.spotlightTracks ?? []
        let todayKey = dateKey(epochMs: Date().timeIntervalSince1970 * 1000)
        // The embedded `spotlightTracks[]` field is only pruned to
        // "today only" as a side effect of the NEXT spotlight write
        // (`addToSpotlight` rebuilds it from date-filtered tracks before
        // persisting) — so if a day rolls over with no new spotlight yet,
        // Firestore still holds yesterday's entries verbatim. Filter by each
        // track's own date rather than trusting the field's contents.
        let activeToday = active.filter { dateKey(epochMs: $0.spotlitAt) == todayKey }

        var grouped: [String: [SpotlightTrack]] = [:]
        for track in spotlightHistory ?? [] {
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
}

// MARK: - Sub-components

private struct StatCell: View {
    let value: String
    let label: String
    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(Font.nodalong.title3Bold)
                .foregroundStyle(Color.nodalong.textPrimary)
            Text(label)
                .font(Font.nodalong.caption)
                .foregroundStyle(Color.nodalong.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}

#if DEBUG
#Preview("Profile – mini player visible") {
    NavigationStack { ProfileView() }.withPreviewEnvironment()
}

#Preview("Profile – no mini player") {
    NavigationStack { ProfileView() }
        .withPreviewEnvironment()
        .environmentObject(PlayerViewModel.mockPreviewEmpty)
}
#endif
