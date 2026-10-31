import SwiftUI
import NodalongKit

/// Full-screen now-playing screen, presented as a `fullScreenCover` from
/// `MainTabView`.
///
/// Layout matches Spotify / Apple Music:
///   - Full-width square artwork (drag-down to dismiss)
///   - Title + shelf heart; artist name (tappable) + album name (tappable)
///   - Scrubber with elapsed / remaining time
///   - Transport row: ⏮ (dead) — ▶▶|| — ⏭ (dead)
///   - System volume slider (MPVolumeView)
///
/// Artist / album taps present the sheet INSTANTLY (a `Resolving*View` with
/// the already-known display data) rather than waiting on a network lookup
/// first — the resolve happens inside the sheet, matching the
/// navigate-before-resolve pattern Home's Jump Back In already uses. The
/// sheet (rather than a `NavigationStack` wrapping this view) keeps the
/// fragile `ScreenMetrics.bounds`-pinned layout untouched.
struct NowPlayingView: View {
    /// The full player's artwork size. A static so `PlayerViewModel` can
    /// warm exactly this rendition before the player is opened.
    @MainActor static var heroArtworkSide: CGFloat {
        min(ScreenMetrics.bounds.width - 48, ScreenMetrics.bounds.height * 0.42)
    }

    @EnvironmentObject private var playerVM:       PlayerViewModel
    @EnvironmentObject private var clock:          PlaybackClock
    @EnvironmentObject private var libraryVM:      LibraryViewModel
    @Environment(FirebaseAuthViewModel.self) private var authVM
    @EnvironmentObject private var partyVM:        ListeningPartyViewModel
    /// Dismisses this cover, then pushes the artist/album tap's destination
    /// onto whichever tab the user was on — see `AppRouter`'s doc comment
    /// for why this replaced the old nested `.sheet(item:)` (which cut the
    /// tab bar and mini player off entirely, since they live in
    /// `MainTabView`, below this cover). The actual artist/album resolve
    /// (which needed `musicService`/`spotifyService`) now happens inside
    /// whichever tab's `.navigationDestination` handles the push, not here.
    @EnvironmentObject private var router:         AppRouter

    /// Backs `artworkSection`'s square-vs-vinyl branch — same key
    /// `ProfileView`'s picker writes, so a change there applies immediately.
    /// Scene-phase safety for the spin itself lives inside
    /// `spinWhilePlaying(_:)` — nothing extra needed here.
    @AppStorage(albumArtworkStyleKey) private var albumArtworkStyleRaw = AlbumArtworkStyle.vinyl.rawValue

    // MARK: - Scrubber state

    @State private var isScrubbing  = false
    @State private var scrubProgress: Double = 0
    @State private var dragOffset:  CGFloat  = 0

    /// Drives the Up Next queue sheet.
    @State private var showQueue       = false

    private let dismissThreshold: CGFloat = 120

    private var displayProgress: Double {
        isScrubbing ? scrubProgress : clock.progress
    }

    var body: some View {
        // Pin the whole screen to the physical device bounds and ignore safe
        // area entirely, then re-apply ONLY the real device insets (read from
        // the key window, not from the SwiftUI environment).
        //
        // Why: this view is a `fullScreenCover` presented from a TabView that
        // used to carry a `.safeAreaInset(edge: .bottom) { BottomSection() }`
        // (now replaced by `.tabViewBottomAccessory` — see `MainTabView`).
        // That old inset leaked into the cover as a phantom ~120–200pt bottom
        // inset, which (a) shifted the content frame so leading-aligned text
        // rendered with its head off the left edge, (b) drew a hard boundary
        // line partway down, and (c) shoved the controls into the leaked
        // band. Locking to `ScreenMetrics.bounds` (née `UIScreen.main.bounds`
        // — replaced only to drop the deprecated singleton; same physical
        // screen, same value, in this single-scene app) + `.ignoresSafeArea()`
        // made the layout immune to whatever the environment reported — kept
        // as-is since it's still cheap insurance, even though the new bottom-
        // accessory API hasn't been confirmed on-device to leak the same way.
        let screen = ScreenMetrics.bounds
        let insets = deviceSafeAreaInsets

        return ZStack {
            background

            VStack(spacing: 0) {
                topBar
                // Two equal flexible spacers flank the artwork: it floats
                // centred in the free space above the control cluster, which
                // stays grouped near the bottom with fixed internal gaps.
                Spacer(minLength: 8)
                artworkSection
                Spacer(minLength: 8)
                trackInfo
                    .padding(.bottom, 16)
                if playerVM.followContext != nil {
                    // Radio / view-only: the broadcaster drives the timeline, so
                    // there's no scrubber/transport/volume — just a live label and
                    // a way to leave.
                    followSurface
                } else {
                    scrubber
                        .padding(.bottom, 18)
                    transportControls
                        .padding(.bottom, 16)
                    volumeSection
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, insets.top)
            .padding(.bottom, max(insets.bottom, 16))
            .frame(width: screen.width, height: screen.height)
        }
        .frame(width: screen.width, height: screen.height)
        .ignoresSafeArea()
        .playbackErrorAlert()
        .sheet(isPresented: $showQueue) {
            QueueView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    /// The device's true safe-area insets — see `ScreenMetrics.safeAreaInsets`
    /// for why this is read from the key window rather than the environment.
    /// Shared with `TrackActionsSheet`, which pins itself the same way.
    private var deviceSafeAreaInsets: UIEdgeInsets { ScreenMetrics.safeAreaInsets }

    // MARK: - Background

    private var background: some View {
        // Fills the screen-pinned ZStack. The parent already pins to
        // `ScreenMetrics.bounds` and ignores safe area, so the background needs
        // only to fill (`maxWidth/Height: .infinity`) — no own `ignoresSafeArea`.
        // The background is blurred at radius 48, so source detail is invisible.
        // Request a tiny (~60 pt) rendition instead of the full 600 px — cuts the
        // decode + blur cost by ~95 % with no visible difference.
        let blurURLString = ArtworkURL.sized(playerVM.nowPlaying?.artwork ?? "", points: 60)
        return Group {
            if blurURLString.isEmpty {
                Color.nodalong.bgBase
            } else {
                CachedArtworkImage(
                    urlString: blurURLString,
                    placeholder: { Color.nodalong.bgBase },
                    failure: { Color.nodalong.bgBase }
                )
                .blur(radius: 48)
                // A uniform top→bottom gradient instead of a flat black wash.
                // Masks the two-tone band a blurred cover can produce (bright
                // top / dark bottom) and darkens the lower half so the text
                // and controls keep contrast on every album.
                .overlay(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.40),
                            Color.nodalong.bgBase.opacity(0.90)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button { playerVM.isExpanded = false } label: {
                topBarGlyph("chevron.down")
            }
            .buttonStyle(.plain)

            Spacer()

            // Up Next queue — or, while a party is active, the Party screen
            // (dismiss this cover first, then present the party cover; a nested
            // cover would stack rather than swap).
            Button {
                if partyVM.isActive {
                    playerVM.isExpanded = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        partyVM.presenting = true
                    }
                } else {
                    showQueue = true
                }
            } label: {
                topBarGlyph(Icons.queue)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
    }

    /// A top-bar control on its own translucent backdrop.
    ///
    /// These sit over `background` — the current track's artwork, blurred —
    /// which is arbitrary user content, so **no fixed foreground colour can
    /// work**: these used to be `textPrimary` (dark ink in light mode), which
    /// vanished against a dark album cover, and any light colour would fail
    /// the same way against a pale one. The material backdrop supplies the
    /// contrast instead of the tint guessing at the artwork's luminance, and
    /// it adapts in both appearances.
    ///
    /// Same affordance the pushed-screen back button already uses — a glyph
    /// on a circular fill — so this reads as the app's existing language
    /// rather than a new one.
    /// Now just the shared `HeaderGlyph`. This treatment originated here (it
    /// was built so the chevron-down and queue glyphs stayed legible over
    /// arbitrary album art, which no fixed colour can do) and was extracted
    /// when the nav bar was removed app-wide, so every hand-rolled back
    /// button uses the same shape. Kept as a wrapper rather than replacing
    /// the two call sites, so the reason it exists stays documented here.
    private func topBarGlyph(_ systemName: String) -> some View {
        HeaderGlyph(systemName)
    }

    // MARK: - Artwork

    private var artworkSection: some View {
        // Near-full-width on tall phones, height-capped on short ones so the
        // control cluster always fits. `-48` matches the body's 24pt h-padding
        // ×2.  iPhone 15 → ~345pt, Pro Max → ~382pt, SE → height-capped ~280pt.
        let side = Self.heroArtworkSide
        let url = playerVM.nowPlaying?.artwork ?? ""

        // Branches on the artwork-style setting — unlike every other
        // `isTrack`/`isAlbum` site in the app, this one genuinely changes
        // SHAPE (rounded-square → circular) and adds a spin that didn't
        // exist before, so it can't just be a parameter flip inside
        // `ArtworkThumbnail`. The trailing `.shadow`/`.frame`/`.offset`/
        // `.gesture` chain below is applied identically regardless of which
        // branch renders, at the exact same position it's always been —
        // that's what protects the drag-to-dismiss gesture and this
        // screen's `ScreenMetrics.bounds`-pinned layout (see this file's
        // top doc comment for its own fragile-layout history) from any risk
        // from this change.
        return Group {
            if AlbumArtworkStyle(rawValue: albumArtworkStyleRaw) == .vinyl {
                VinylArtworkView(url: url, size: side)
                    .spinWhilePlaying(playerVM.isPlaying)
                    .clipShape(Circle())
                    .compositingGroup()
            } else {
                // Original static rendering — byte-identical to before this
                // change, including the artwork-size cap comment below.
                // Capped at the 600 px source (see ArtworkURL.sized) —
                // `side` × 3 would otherwise resolve to ~1035 px and decode
                // to a ~4 MB bitmap.
                let sizedString = ArtworkURL.sized(url, points: side)
                ZStack {
                    if sizedString.isEmpty {
                        Color.nodalong.bgCard
                    } else {
                        CachedArtworkImage(
                            urlString: sizedString,
                            placeholder: { ShimmerView() },
                            failure: { Color.nodalong.bgCard }
                        )
                    }
                }
                .frame(width: side, height: side)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
            }
        }
        .shadow(color: .black.opacity(0.55), radius: 32, y: 14)
        .frame(maxWidth: .infinity, alignment: .center)  // centre in the VStack
        .offset(y: dragOffset)
        .gesture(dragDownGesture)
    }

    // MARK: - Track info

    // NOTE: Must use `if let` (not `guard let` with explicit `return AnyView()`) —
    // explicit `return` statements inside a `@ViewBuilder` property bypass the
    // ViewBuilder transform and can produce a collapsed/empty view even when the
    // bound value is non-nil.
    @ViewBuilder
    private var trackInfo: some View {
        if let track = playerVM.nowPlaying {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    MarqueeText(
                        text:  track.title,
                        font:  Font.nodalong.title3Bold,
                        color: Color.nodalong.textPrimary,
                        repeats: true
                    )

                    // Artist — dismisses this cover, then pushes onto
                    // whichever tab the user was on (see `AppRouter`), which
                    // shows a provisional header instantly and resolves (incl.
                    // the multi-artist picker, if the track credits more than
                    // one) in the background. See `ResolvingArtistsView`.
                    Button {
                        // Already resolved to exactly one artist by the
                        // player's own prefetch → push the real page, not
                        // the resolving placeholder.
                        if let cached = playerVM.prefetchedArtistsForUri, cached.uri == track.uri,
                           cached.artists.count == 1 {
                            router.dismissThenPush(cached.artists[0], identity: .artist(name: track.artist)) {
                                playerVM.isExpanded = false
                            }
                        } else {
                            router.dismissThenPush(
                                PendingArtistResolve(
                                    trackTitle: track.title, artist: track.artist,
                                    catalogId: track.catalogId, isrc: track.isrc, uri: track.uri
                                ),
                                identity: .artist(name: track.artist)
                            ) { playerVM.isExpanded = false }
                        }
                    } label: {
                        MarqueeText(text: track.artist, font: Font.nodalong.subheadline, color: Color.nodalong.textPrimary.opacity(0.65), repeats: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    // Album — same dismiss-then-push, landing on whichever
                    // tab the user was on so the tab bar stays reachable.
                    if !track.album.isEmpty {
                        Button {
                            if let cached = playerVM.prefetchedAlbumForUri, cached.uri == track.uri {
                                router.dismissThenPush(cached.album, identity: .album(name: track.album, artist: track.artist)) {
                                    playerVM.isExpanded = false
                                }
                            } else {
                            router.dismissThenPush(
                                PendingAlbumResolve(
                                    albumName: track.album, artist: track.artist, artwork: track.artwork,
                                    catalogId: track.catalogId, isrc: track.isrc, uri: track.uri,
                                    trackTitle: track.title
                                ),
                                identity: .album(name: track.album, artist: track.artist)
                            ) { playerVM.isExpanded = false }
                            }
                        } label: {
                            MarqueeText(text: track.album, font: Font.nodalong.subheadline, color: Color.nodalong.textPrimary.opacity(0.45), repeats: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Hard right boundary for the text column — without it the column
                // can claim unbounded width and render with its leading edge off
                // the left of the screen (clipping the start of each line).
                Spacer(minLength: 12)

                // Spotlight lives here, not on the TrackCard row — it's a
                // deliberate "this is my pick today" action, and this screen
                // (the one place a track is genuinely being considered, not
                // scrolled past) is the more fitting home for it than a
                // dense Feed row. See `spotlightButton`'s own doc comment.
                spotlightButton(track: track)
                heartButton(track: track)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Heart button

    @ViewBuilder
    private func heartButton(track: NowPlayingTrack) -> some View {
        let isLiked = libraryVM.isInLibrary(catalogId: track.catalogId, uri: track.uri)
        Button {
            guard let uid = authVM.currentUser?.uid else { return }
            Task { await libraryVM.toggleLibrary(uid: uid, track: libraryDoc(track: track)) }
        } label: {
            Image(systemName: isLiked ? Icons.heart : Icons.heartOutline)
                .font(.system(size: 24))
                .foregroundStyle(isLiked ? Color.nodalong.purpleAccent : Color.nodalong.textPrimary.opacity(0.75))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Spotlight button

    /// Toggles today's spotlight for the current track (tapping an already-
    /// spotlit track un-spotlights it).
    ///
    /// Only two things disable it: the track is not already one of today's
    /// picks AND the daily cap of 3 is reached. A missing `catalogId` is NOT
    /// one of them — tracks started from Search, an album or Top Songs have
    /// none, and this star used to stay greyed out for all of them.
    /// `FirebaseAuthViewModel.toggleSpotlight` creates the catalog row at tap
    /// time instead.
    @ViewBuilder
    private func spotlightButton(track: NowPlayingTrack) -> some View {
        let song = spotlightSong(for: track)
        let isSpotlit = authVM.todaySpotlight(matching: song) != nil
        let isDisabled = !authVM.canSpotlight(song)

        Button {
            Task { await authVM.toggleSpotlight(song) }
        } label: {
            Image(systemName: isSpotlit ? Icons.star : "star")
                .font(.system(size: 24))
                .foregroundStyle(
                    isSpotlit  ? Color.nodalong.gold
                  : isDisabled ? Color.nodalong.textPrimary.opacity(0.25)
                  :              Color.nodalong.textPrimary.opacity(0.75)
                )
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    /// The full `Song` behind the Now Playing track — the queue's own item when
    /// it is the same track (it carries ISRC, genres, track number and so on),
    /// otherwise one rebuilt from what Now Playing knows (e.g. while tuned in
    /// to someone else's broadcast, when there is no local queue).
    private func spotlightSong(for track: NowPlayingTrack) -> Song {
        if let item = playerVM.currentItem?.song, item.uri == track.uri { return item }
        return Song(
            id: track.uri, title: track.title, artist: track.artist, album: track.album,
            artwork: track.artwork, trackId: track.uri, uri: track.uri,
            catalogId: track.catalogId, sourceService: playerVM.activeService,
            isrc: track.isrc, duration: Int(playerVM.currentDuration * 1000)
        )
    }

    /// Shared by `heartButton` (shelf save) and `spotlightButton` (spotlight
    /// add) — both write a `LibraryTrackDoc`, and `addToSpotlight` only
    /// reads its catalogId/title/artist/album/artwork/uri/sourceService, so
    /// one construction serves both rather than duplicating seven fields.
    private func libraryDoc(track: NowPlayingTrack) -> LibraryTrackDoc {
        LibraryTrackDoc(
            catalogId:   track.catalogId ?? "",
            title:       track.title,
            artist:      track.artist,
            album:       track.album,
            artwork:     track.artwork,
            uri:         track.uri,
            sourceService: playerVM.activeService,
            duration:    Int(playerVM.currentDuration * 1000),
            savedAt:     Date().timeIntervalSince1970 * 1000
        )
    }

    // MARK: - Follow (radio) surface

    /// Shown in place of the scrubber/transport/volume while this device is a
    /// pure sync-follower. The broadcaster owns the timeline; the only action is
    /// to leave.
    @ViewBuilder
    private var followSurface: some View {
        if let ctx = playerVM.followContext {
            VStack(spacing: 16) {
                // `Label(_:image:)` would render the mark at its own
                // intrinsic size (a custom asset ignores `.font`) — the
                // explicit `icon:` closure lets `NodalongMark` bound it.
                Label {
                    Text(ctx.label)
                } icon: {
                    NodalongMark(size: 16)
                }
                    .font(Font.nodalong.subheadlineSemibold)
                    .foregroundStyle(Color.nodalong.purpleAccent)

                Button {
                    playerVM.stopFollowing()
                    playerVM.isExpanded = false
                } label: {
                    Text("Leave")
                        .font(Font.nodalong.subheadlineSemibold)
                        .foregroundStyle(Color.nodalong.textPrimary)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .background(Color.nodalong.textPrimary.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Scrubber

    private var scrubber: some View {
        // No extra inset — inherits the body's 24pt h-padding so the slider
        // track and both time labels sit comfortably within the screen bounds.
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { displayProgress },
                    set: { scrubProgress = $0 }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing { playerVM.seek(to: scrubProgress) }
                }
            )
            .tint(.white)

            HStack {
                Text(formattedTime(displayProgress * clock.duration))
                    .monospacedDigit()
                    .font(Font.nodalong.caption2)
                    .foregroundStyle(Color.nodalong.textPrimary.opacity(0.5))
                Spacer()
                Text("-\(formattedTime((1 - displayProgress) * clock.duration))")
                    .monospacedDigit()
                    .font(Font.nodalong.caption2)
                    .foregroundStyle(Color.nodalong.textPrimary.opacity(0.5))
            }
        }
    }

    // MARK: - Transport controls

    private var transportControls: some View {
        HStack(spacing: 52) {
            // Previous — restarts the current track if >3s in, else steps back.
            // Always actionable, so always full-opacity.
            Button {
                Task { await playerVM.skipToPrevious() }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.nodalong.textPrimary.opacity(0.85))
            }
            .buttonStyle(.plain)

            // Play / pause
            Button {
                Task { await playerVM.togglePlayPause() }
            } label: {
                Image(systemName: playerVM.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.nodalong.textPrimary)
            }
            .buttonStyle(.plain)

            // Next — advances the queue; dims + disables when nothing is queued
            // after the current track.
            Button {
                Task { await playerVM.skipToNext() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.nodalong.textPrimary.opacity(playerVM.hasNext ? 0.85 : 0.3))
            }
            .buttonStyle(.plain)
            .disabled(!playerVM.hasNext)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Volume

    private var volumeSection: some View {
        // MPVolumeView is a UIKit view — it does not respect SwiftUI `.padding()`.
        // We give it an explicit width (55% of screen) so it doesn't overflow.
        // The speaker icons sit outside this fixed-width slider, kept by HStack.
        let sliderWidth = ScreenMetrics.bounds.width * 0.55
        return HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
                .font(Font.nodalong.caption)
                .foregroundStyle(Color.nodalong.textPrimary.opacity(0.5))
            SystemVolumeSlider()
                .frame(width: sliderWidth, height: 32)
            Image(systemName: "speaker.wave.3.fill")
                .font(Font.nodalong.caption)
                .foregroundStyle(Color.nodalong.textPrimary.opacity(0.5))
        }
    }

    // MARK: - Drag-to-dismiss

    private var dragDownGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard value.translation.height > 0 else { return }
                withAnimation(.interactiveSpring()) { dragOffset = value.translation.height }
            }
            .onEnded { value in
                if value.translation.height > dismissThreshold { playerVM.isExpanded = false }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { dragOffset = 0 }
            }
    }

    // MARK: - Helpers

    private func formattedTime(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

#if DEBUG
#Preview {
    NowPlayingView().withPreviewEnvironment()
}
#endif
