import SwiftUI
import NodalongKit

/// Bottom sheet shown when the user taps an avatar on the NearMe canvas.
///
/// Self-contained: takes only the `UserProfile` and loads the rest on
/// appear — follow state, follower count, and the user's recent listens.
/// Spotlight tracks come straight off the user profile (already loaded by
/// `NearMeViewModel`).
///
/// Sections (top → bottom):
/// 1. Drag handle
/// 2. Avatar + username + bio
/// 3. Follow / Following button (inline, no need to navigate to profile)
/// 4. Spotlight tracks — up to 3, gold-highlighted, playable
/// 5. Recent tracks — up to 5 most-recent listens, playable
/// 6. "View Profile" CTA (full profile screen for deeper browsing)
struct NearMeUserSheet: View {
    let user: UserProfile

    @Environment(FirebaseAuthViewModel.self) private var authVM
    @EnvironmentObject private var playerVM:       PlayerViewModel
    @EnvironmentObject private var musicService:   AppleMusicService
    @EnvironmentObject private var spotifyService: SpotifyMusicService
    @EnvironmentObject private var partyVM:        ListeningPartyViewModel
    @EnvironmentObject private var syncCoordinator: SyncFollowCoordinator
    /// Dismisses this sheet, then pushes onto whichever tab was selected —
    /// see `AppRouter`'s doc comment. This sheet used to push `UserProfile`
    /// via a plain `NavigationLink` onto its OWN throwaway `NavigationStack`
    /// (wrapped around it by `NearMeView`'s `.sheet(item:)` closure) —
    /// meaning "View Profile," and everything reachable from the profile
    /// after it (playlists, etc.), stayed trapped under that modal sheet,
    /// cutting off the tab bar/mini player exactly like the pre-`AppRouter`
    /// `NowPlayingView`/`PartyView` did.
    @EnvironmentObject private var router:          AppRouter
    @Environment(\.dismiss)        private var dismiss

    /// Whichever backend is actually connected — the play gate must check
    /// this, not hardcode Apple Music.
    private var activeService: any MusicService {
        activeMusicService(playerVM: playerVM, apple: musicService, spotify: spotifyService)
    }

    @State private var following     = false
    @State private var followLoading = false
    @State private var recentTracks: [Post] = []
    /// The passed-in `user.spotlightTracks` are slim event entries; enriched
    /// with catalog metadata in `loadData`.
    @State private var spotlights: [SpotlightTrack] = []

    /// Live "currently playing" presence (RTDB `users_live/{uid}/nowPlaying`)
    /// — a live listener scoped to this sheet's lifetime, torn down on
    /// disappear. `liveTrack` is the catalog-enriched metadata once a
    /// `catalogId` arrives.
    @State private var liveNowPlaying: UserNowPlaying?
    @State private var liveTrack: CatalogTrack?
    private let presence = UserPresenceService()
    /// Whether `user` is currently hosting a live party (host-only scope —
    /// see plan). One-shot load alongside follow state / recents.
    @State private var hostedParty: ListeningParty?

    /// `true` when the sheet is showing the current user's own avatar — we
    /// hide the follow button in that case.
    private var isOwnProfile: Bool {
        authVM.currentUser?.uid == user.uid
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                handle
                identitySection
                if !isOwnProfile { followButton }
                if liveNowPlaying?.isPlaying == true { nowPlayingSection }
                if let hostedParty { joinPartyBanner(hostedParty) }
                if !spotlights.isEmpty  { spotlightSection }
                if !recentTracks.isEmpty { recentSection    }
                viewProfileButton
            }
            .padding(.bottom, 32)
        }
        .background(Color.nodalong.bgBase)
        .task { await loadData() }
        .onDisappear { presence.detachAll() }
    }

    // MARK: - Live now playing / party

    @ViewBuilder
    private var nowPlayingSection: some View {
        if let track = liveTrack {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    ArtworkThumbnail(url: track.artwork, isTrack: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NOW PLAYING")
                            .font(Font.nodalong.caption2Bold)
                            .foregroundStyle(Color.nodalong.purpleAccent)
                        Text(track.title)
                            .font(Font.nodalong.subheadlineMedium)
                            .foregroundStyle(Color.nodalong.textPrimary)
                            .lineLimit(1)
                        Text(track.artist)
                            .font(Font.nodalong.caption)
                            .foregroundStyle(Color.nodalong.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                if !isOwnProfile { tuneInControl }
            }
            .padding(10)
            .background(Color.nodalong.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
            .padding(.horizontal, 24)
        }
    }

    /// "Tune In" — play the same track on this device, aligned to the other
    /// user's position (single-song). Requires an Apple Music subscription on
    /// BOTH sides: this device (each device streams the full track) and the
    /// broadcaster (a preview-mode broadcaster's own playback cycles every
    /// ~30s, which sync would just follow into a broken cycling loop).
    @ViewBuilder
    private var tuneInControl: some View {
        if !musicService.canPlayFullTracks {
            Text("Apple Music subscription required to tune in")
                .font(Font.nodalong.caption)
                .foregroundStyle(Color.nodalong.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if liveNowPlaying?.isPreviewPlayback == true {
            Text("Sync unavailable — \(user.username) isn't on Apple Music")
                .font(Font.nodalong.caption)
                .foregroundStyle(Color.nodalong.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Button {
                syncCoordinator.tuneIn(uid: user.uid, label: "Tuned in to \(user.username)")
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    NodalongMark(size: 18)
                    Text("Tune In").font(Font.nodalong.subheadlineSemibold)
                    Spacer()
                }
                .foregroundStyle(Color.nodalong.textOnAccent)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color.nodalong.purpleAccent)
                .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    /// Mirrors `FeedView.partyBannerButton`'s styling — same affordance, same
    /// destination (`ListeningPartyViewModel.joinAndEnter`, unchanged).
    private func joinPartyBanner(_ party: ListeningParty) -> some View {
        Button {
            guard let me = authVM.profile else { return }
            partyVM.joinAndEnter(party, me: me, playerVM: playerVM)
            dismiss()
        } label: {
            HStack(spacing: 8) {
                NodalongMark(size: 18)
                // `.frame(maxWidth: .infinity, alignment: .leading)` takes
                // over the trailing `Spacer()`'s old role (soaking up
                // leftover space) — MarqueeText needs a genuinely bounded
                // container to detect overflow; a plain Text ahead of a
                // Spacer still just claims its own natural width first.
                MarqueeText(text: "Join “\(party.title)”", font: Font.nodalong.subheadlineSemibold, color: Color.nodalong.textOnAccent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(Font.nodalong.captionBold)
            }
            .foregroundStyle(Color.nodalong.textOnAccent)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color.nodalong.purpleAccent)
            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
    }

    // MARK: - Sections

    private var handle: some View {
        RoundedRectangle(cornerRadius: Corner.container, style: .continuous)
            .fill(Color.nodalong.textSecondary)
            .frame(width: 36, height: 4)
            .padding(.top, 12)
    }

    private var identitySection: some View {
        VStack(spacing: 8) {
            // Procedural avatar — same `AvatarView` everywhere in the app,
            // here in the big "hero" size with `animated: true` so the
            // sheet shows the breathe/tilt motion. Spline was tried and
            // dropped (no simulator slice, expensive at scale, closed
            // asset ecosystem); see CLAUDE.md decisions log for the swap.
            AvatarView(
                emoji:    user.avatarEmoji,
                colorHex: user.avatarColor,
                size:     200,
                animated: true
            )
            Text(user.username)
                .font(Font.nodalong.title3Bold)
                .foregroundStyle(Color.nodalong.textPrimary)
            if !user.bio.isEmpty {
                Text(user.bio)
                    .font(Font.nodalong.subheadline)
                    .foregroundStyle(Color.nodalong.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }

    /// Inline follow / unfollow button. Optimistic — toggles state instantly
    /// and reverts on Firestore failure.
    private var followButton: some View {
        Button(action: toggleFollow) {
            Group {
                if followLoading {
                    ProgressView().tint(.white)
                } else {
                    Text(following ? "Following" : "Follow")
                        .font(Font.nodalong.subheadlineSemibold)
                        .foregroundStyle(following ? Color.nodalong.textPrimary : Color.nodalong.textOnAccent)
                }
            }
            .frame(width: 140, height: 36)
            .background(following ? Color.nodalong.bgCard : Color.nodalong.purpleMid)
            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Corner.container, style: .continuous)
                    .strokeBorder(following ? Color.nodalong.textSecondary : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// Spotlight tracks — gold-tinted to telegraph their "deliberate
    /// recommendation" status. Up to 3 (today's cap).
    private var spotlightSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Spotlight", icon: "star.fill", tint: Color.nodalong.gold)
            ForEach(spotlights, id: \.trackId) { track in
                spotlightRow(track)
            }
        }
        .padding(.horizontal, 24)
    }

    /// Recent listens — what shows up in the user's followers' Feed.
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Recent", icon: "clock.fill", tint: Color.nodalong.purpleAccent)
            ForEach(recentTracks.prefix(5)) { post in
                recentRow(post)
            }
        }
        .padding(.horizontal, 24)
    }

    /// Pushes to the full profile screen for deeper browsing (follow lists,
    /// historic spotlights, etc.) — dismisses this sheet first, then pushes
    /// onto the tab's own real navigation stack (`router.dismissThenPush`),
    /// so the profile (and anything reachable from it, like playlists)
    /// lands somewhere the tab bar/mini player stay visible, instead of
    /// trapped under this sheet's own throwaway stack.
    private var viewProfileButton: some View {
        Button {
            router.dismissThenPush(user) { dismiss() }
        } label: {
            Text("View Profile")
                .font(Font.nodalong.subheadlineSemibold)
                .foregroundStyle(Color.nodalong.textOnAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.nodalong.purpleMid)
                .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    // MARK: - Row builders

    private func sectionHeader(_ title: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(Font.nodalong.captionSemibold)
                .foregroundStyle(tint)
            Text(title)
                .font(Font.nodalong.subheadlineSemibold)
                .foregroundStyle(Color.nodalong.textPrimary)
        }
    }

    private func spotlightRow(_ track: SpotlightTrack) -> some View {
        HStack(spacing: 12) {
            ArtworkThumbnail(url: track.artwork, isTrack: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(Font.nodalong.subheadlineMedium)
                    .foregroundStyle(Color.nodalong.textPrimary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            playButton {
                Task { await playerVM.play(.from(spotlight: track)) }
                dismiss()
            }
        }
        .padding(10)
        .background(Color.nodalong.bgCard)
        .overlay(
            RoundedRectangle(cornerRadius: Corner.container, style: .continuous)
                .strokeBorder(Color.nodalong.gold.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
    }

    private func recentRow(_ post: Post) -> some View {
        HStack(spacing: 12) {
            ArtworkThumbnail(url: post.artwork, isTrack: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(post.title)
                    .font(Font.nodalong.subheadlineMedium)
                    .foregroundStyle(Color.nodalong.textPrimary)
                    .lineLimit(1)
                Text(post.artist)
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            playButton {
                Task { await playerVM.play(.from(post: post)) }
                dismiss()
            }
        }
        .padding(10)
        .background(Color.nodalong.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
    }

    /// Shared play-button used by spotlight + recent rows. Hidden when no
    /// music service is authorised so the row stays clean.
    @ViewBuilder
    private func playButton(action: @escaping () -> Void) -> some View {
        if activeService.isAuthenticated {
            Button(action: action) {
                Image(systemName: Icons.play)
                    .font(Font.nodalong.subheadline)
                    .foregroundStyle(Color.nodalong.textOnAccent)
                    .frame(width: 36, height: 36)
                    .background(Color.nodalong.purpleMid)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Data

    private func loadData() async {
        guard let myUid = authVM.currentUser?.uid else { return }
        async let followCheck = isFollowing(myUid: myUid, targetUid: user.uid)
        async let recents     = getYourMusicFeed(uid: user.uid)
        async let party       = getLivePartyHostedBy(uid: user.uid)
        following    = (try? await followCheck) ?? false
        recentTracks = (try? await recents)     ?? []
        hostedParty  = (try? await party)       ?? nil
        spotlights   = await enrichSpotlights(user.spotlightTracks)

        presence.observeNowPlaying(uid: user.uid) { np in
            liveNowPlaying = np
            guard let catalogId = np?.catalogId, !catalogId.isEmpty else {
                liveTrack = nil
                return
            }
            Task {
                let meta = await CatalogCache.shared.metadata(for: [catalogId])
                liveTrack = meta[catalogId]
            }
        }
    }

    /// Optimistic follow toggle — flip UI state, then Firestore. On error,
    /// revert. Same pattern as `UserProfileView.followButton`.
    private func toggleFollow() {
        guard !followLoading, let myUid = authVM.currentUser?.uid else { return }
        followLoading = true
        Task {
            if following {
                do {
                    try await unfollowUser(myUid: myUid, targetUid: user.uid)
                    following = false
                } catch {
                    // no-op on failure
                }
            } else {
                let myUsername = authVM.profile?.username ?? ""
                do {
                    try await followUser(myUid: myUid, myUsername: myUsername,
                                         targetUid: user.uid, targetUsername: user.username)
                    following = true
                } catch {
                    // no-op on failure
                }
            }
            followLoading = false
        }
    }
}
