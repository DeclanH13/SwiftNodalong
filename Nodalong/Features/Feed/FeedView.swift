import SwiftUI
import UIKit
import NodalongKit

/// The Following feed — the home tab.
struct FeedView: View {
    @EnvironmentObject private var feedVM:         FeedViewModel
    @EnvironmentObject private var playerVM:       PlayerViewModel
    @EnvironmentObject private var musicService:   AppleMusicService
    @EnvironmentObject private var spotifyService: SpotifyMusicService
    @Environment(FirebaseAuthViewModel.self) private var authVM
    @EnvironmentObject private var libraryVM:      LibraryViewModel
    @EnvironmentObject private var partyVM:        ListeningPartyViewModel
    /// Owns this tab's own `NavigationPath` (`router.feedPath`) — see
    /// `AppRouter`'s doc comment.
    @EnvironmentObject private var router:         AppRouter

    /// Whichever backend is actually connected — the play gate must check
    /// this, not hardcode Apple Music.
    private var activeService: any MusicService {
        activeMusicService(playerVM: playerVM, apple: musicService, spotify: spotifyService)
    }

    /// Live parties hosted by people this user follows (party discovery).
    @State private var liveParties: [ListeningParty] = []
    @State private var liveListeners: [LiveNowEntry] = []
    /// Driven by a re-tap of the Feed tab while already at the root.
    @State private var scrollPosition = ScrollPosition(edge: .top)
    /// Whether the tab-root header is currently scrolled away.

    var body: some View {
        // `@Bindable` is required to derive a `$` binding from an
        // `@Observable` object held in the environment.
        @Bindable var authVM = authVM

        NavigationStack(path: $router.feedPath) {
            VStack(spacing: 0) {
            Group {
                // The `!hasLoaded` clause covers the brief window on first
                // appearance before `.task` has run at all (isLoading is
                // still its default `false` then) — without it, that first
                // render would fall through to `emptyState` for a beat. With
                // stale-while-revalidate this branch is now only reached on
                // a genuine first-ever load (no cached snapshot) — a warm
                // launch renders real posts here instead.
                if feedVM.isLoading || (!feedVM.hasLoaded && feedVM.posts.isEmpty) {
                    feedSkeleton
                } else if feedVM.posts.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            // The profile avatar — genuine first-row content,
                            // not a floating overlay, so it scrolls away with
                            // the rest of the feed and returns at the top.
                            ProfileAvatarRow()

                            // Container merges into the page (bgBase) — mirrors
                            // Recent Tracks / Spotlight's container treatment.
                            // The individual TrackCard rows (bgCard) are what
                            // lift off the page now, not this wrapper. Still a
                            // LazyVStack inside — the background/clipShape size
                            // to its full logical content height, so lazy card
                            // instantiation is unaffected.
                            LazyVStack(spacing: 12) {
                                ForEach(feedVM.posts) { post in
                                    feedCard(post)
                                }
                            }
                            .trackListContainer()
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                        }
                    }
                    .scrollPosition($scrollPosition)
                    .onChange(of: router.scrollToTopRequests[.feed]) {
                        withAnimation(.easeInOut(duration: 0.3)) { scrollPosition.scrollTo(edge: .top) }
                    }
                    .refreshable {
                        await feedVM.refresh(myUid: authVM.currentUser?.uid)
                        if let uid = authVM.currentUser?.uid { await loadLiveParties(uid: uid) }
                    }
                    .safeAreaInset(edge: .bottom) {
                        if playerVM.nowPlaying != nil {
                            Color.clear.frame(height: 70)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 0) { partyBanner; listeningStrip }
            }
            }
            // Hoisted off `ScreenHeader` so the pop-gesture install survives
            // the header being collapsed away — see `SwipeBackGesture.swift`.
            .enablesInteractiveSwipeBack()
            // Warm the people whose cards are on screen — the username chip on
            // each card opens their profile. `prefetch` caps at 6 (each bundle
            // is ~5 billed reads) and skips the viewer.
            .task(id: feedVM.posts.prefix(8).map(\.uid)) {
                guard let me = authVM.currentUser?.uid else { return }
                var seen = Set<String>()
                let uids = feedVM.posts.prefix(8).map(\.uid).filter { seen.insert($0).inserted }
                SocialCache.shared.prefetch(uids: uids, viewerUid: me)
            }
            .screenBackground()
            .toolbar(.hidden, for: .navigationBar)
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
            .navigationDestination(for: ArtistResult.self) { ArtistDetailSearchView(artist: $0) }
            .navigationDestination(for: AlbumResult.self)  { AlbumDetailSearchView(album: $0) }
            .navigationDestination(for: Playlist.self)     { PlaylistDetailView(playlist: $0) }
            // Landed here from `router.dismissThenPush` — NowPlayingView's
            // artist/album tap, or PartyView's — since a push always targets
            // whichever tab happens to be selected, and Feed previously had
            // none of the registrations above at all.
            .navigationDestination(for: PendingArtistResolve.self) { pending in
                ResolvingArtistsView(name: pending.artist, cached: cachedPendingArtists(pending, playerVM: playerVM)) {
                    await resolvePendingArtists(for: pending, playerVM: playerVM, musicService: musicService, activeService: activeService)
                }
            }
            .navigationDestination(for: PendingAlbumResolve.self) { pending in
                ResolvingAlbumView(name: pending.albumName, artistName: pending.artist, artwork: pending.artwork,
                                   cached: cachedPendingAlbum(pending, playerVM: playerVM)) {
                    await resolvePendingAlbum(for: pending, playerVM: playerVM, musicService: musicService, activeService: activeService)
                }
            }
            .profileEntryPoint()
            // `.enablesInteractiveSwipeBack()` only — the profile avatar
            // itself now lives as the first row of the loaded feed's own
            // ScrollView, not floating over it. `showsBack: false` — a tab
            // root has nothing to pop to.
            .screenControls(showsBack: false)
        }
        .alert("Daily Limit Reached", isPresented: $authVM.spotlightLimitReached) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You can only spotlight \(maxSpotlights) tracks per day. Remove one to swap it out.")
        }
        .task {
            await feedVM.load(myUid: authVM.currentUser?.uid)
            if let uid = authVM.currentUser?.uid {
                await libraryVM.load(uid: uid)
                await loadLiveParties(uid: uid)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
        ) { _ in
            Task {
                await feedVM.refresh(myUid: authVM.currentUser?.uid)
                // `liveParties` (party-discovery — the "X is hosting" banner)
                // was previously fetched only once per app session, in the
                // initial `.task` — a party that ends while this device's
                // Feed has been sitting open/backgrounded (even for days)
                // would keep showing as "hosting" indefinitely, since nothing
                // ever re-fetched it. Refresh on every foreground return,
                // matching `feedVM.refresh`'s existing pattern.
                if let uid = authVM.currentUser?.uid { await loadLiveParties(uid: uid) }
            }
        }
    }

    /// One-line banner: return to your own live party, else the first live
    /// party a followed user is hosting (tap to join).
    @ViewBuilder
    private var partyBanner: some View {
        if partyVM.isActive {
            partyBannerButton(text: "Return to \(partyVM.party?.title ?? "your LP")") {
                partyVM.reopen()
            }
        } else if let p = liveParties.first(where: { $0.hostUid != authVM.currentUser?.uid }) {
            partyBannerButton(text: "\(p.hostUsername) is hosting “\(p.title)”") {
                if let me = authVM.profile { partyVM.joinAndEnter(p, me: me, playerVM: playerVM) }
            }
        }
    }

    /// Followed people playing right now, each with a Tune In button.
    @ViewBuilder
    private var listeningStrip: some View {
        if !liveListeners.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(liveListeners) { entry in
                        VStack(spacing: 4) {
                            AvatarView(emoji: entry.avatarEmoji, colorHex: entry.avatarColor, size: 40)
                            Text(entry.username).font(Font.nodalong.caption2)
                                .foregroundStyle(Color.nodalong.textSecondary).lineLimit(1)
                                .frame(width: 60)
                            if case .listening(_, let isPreview) = entry.kind {
                                TuneInButton(uid: entry.uid, username: entry.username,
                                             isPreviewPlayback: isPreview, compact: true)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
    }

    private func partyBannerButton(text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                NodalongMark(size: 18)
                Text(text).font(Font.nodalong.subheadlineSemibold).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right").font(Font.nodalong.captionBold)
            }
            .foregroundStyle(Color.nodalong.textOnAccent)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color.nodalong.purpleAccent)
        }
        .buttonStyle(.plain)
    }

    private func loadLiveParties(uid: String) async {
        // Routed through FollowingCache — HomeViewModel needs the same
        // following list + live-parties-by-host query around the same time
        // at launch; the cache collapses the duplicate reads.
        let following = await FollowingCache.shared.following(uid: uid).map(\.uid)
        liveParties = await FollowingCache.shared.liveParties(hostedBy: following)
        liveListeners = await LiveListenersLoader.load(
            followingUids: following, excluding: Set(liveParties.map(\.hostUid)))
    }

    @ViewBuilder
    private func feedCard(_ post: Post) -> some View {
        let isLiked = libraryVM.isInLibrary(catalogId: post.catalogId, uri: post.uri)

        TrackCard(
            title:          post.title,
            artist:         post.artist,
            album:          post.album,
            artwork:        post.artwork,
            layout:         .row,
            username:       post.username,
            avatarColor:    post.avatarColor,
            nods:           post.nods,
            isSpotlit:      post.isSpotlit,
            onPlay:         { playPost(post) },
            onToggleLike:   { likePost(post) },
            isLiked:        isLiked,
            onAddToQueue:   { playerVM.addToQueue(.from(post: post)) },
            addToPlaylistSong: .from(post: post),
            onTapUser:      { Task { await openProfile(post.uid) } }
        )
    }

    /// Fetches the full `UserProfile` for `uid` and pushes `UserProfileView`
    /// — `TrackCard`'s attribution chip only knows a uid, not a profile.
    private func openProfile(_ uid: String) async {
        guard let profile = await profileForNavigation(uid: uid, viewerUid: authVM.currentUser?.uid) else { return }
        router.push(profile, onto: .feed)
    }

    private func playPost(_ post: Post) {
        guard activeService.isAuthenticated else { return }
        Task { await playerVM.play(.from(post: post)) }
        if let uid = authVM.currentUser?.uid {
            Task { await feedVM.tryNod(post, nodderUid: uid) }
        }
    }

    private func likePost(_ post: Post) {
        guard let uid = authVM.currentUser?.uid else { return }
        let doc = LibraryTrackDoc(catalogId: post.catalogId, title: post.title,
                                  artist: post.artist, album: post.album,
                                  artwork: post.artwork, uri: post.uri,
                                  sourceService: post.sourceService,
                                  savedAt: Date().timeIntervalSince1970 * 1000)
        Task { await libraryVM.toggleLibrary(uid: uid, track: doc) }
    }

    /// Shown only on a genuine first-ever load (no cached snapshot yet).
    /// Matches the real list's card sizing and `bgBase` container so the
    /// swap to real content doesn't shift layout.
    private var feedSkeleton: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(0..<6, id: \.self) { _ in
                    ShimmerView()
                        .frame(height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                }
            }
            .trackListContainer()
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .scrollDisabled(true)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2")
                .font(.system(size: 48))
                .foregroundStyle(Color.nodalong.textSecondary)
            Text("Nothing here yet")
                .font(Font.nodalong.subheadline)
                .foregroundStyle(Color.nodalong.textSecondary)
            Text("Follow people via Search or Near Me to see their music here")
                .font(Font.nodalong.caption)
                .foregroundStyle(Color.nodalong.textSecondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if DEBUG
/// Two variants so you can compare the layout with and without the mini player.
///
/// **With mini player (default):** `withPreviewEnvironment()` injects
/// `PlayerViewModel.mockPreview` which already has a track loaded — the mini
/// player pill is visible at the bottom. Use Xcode's interactive canvas mode
/// (the cursor icon) to scroll the feed and verify the last card ends above
/// the pill.
///
/// **Without mini player:** swap in `.environmentObject(PlayerViewModel.mockPreviewEmpty)`
/// to confirm the feed fills all the way to the tab bar when nothing is playing.
#Preview("Feed – mini player visible") {
    FeedView().withPreviewEnvironment()
}

#Preview("Feed – no mini player") {
    FeedView()
        .withPreviewEnvironment()
        .environmentObject(PlayerViewModel.mockPreviewEmpty)
}
#endif
