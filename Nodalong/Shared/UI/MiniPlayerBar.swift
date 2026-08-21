import SwiftUI

/// Persistent player bar — hosted in `MainTabView`'s `.tabViewBottomAccessory`.
///
/// Hidden when nothing is playing (`isEnabled:` on the accessory modifier,
/// not this view returning empty — see `MainTabView`'s doc comment). Tapping
/// the bar opens `NowPlayingView` in a full-screen cover. State comes from
/// `PlayerViewModel`.
///
/// Always renders as one floating full-width pill above the tab bar — 62 pt
/// height, 32 pt corner radius, solid `purpleDark` fill, soft drop shadow
/// (ported from the RN sibling's `Player.tsx` `pill` style). Used to also
/// merge into the tab bar row while scrolling (`.tabBarMinimizeBehavior
/// (.onScrollDown)` on `MainTabView`), swapping to a second, stripped-down
/// chrome for that `.inline` placement — reverted per direct product
/// decision after confirmed on-device visual glitches during that
/// system-driven placement transition (the spinning disc could briefly
/// escape its circular mask mid-transition, among other artifacts). Now
/// always one placement, one chrome — no more transition to glitch during.
///
/// **Artwork** is a circle that spins like a vinyl record while playing and
/// freezes in place when paused — literally a small vinyl disc (via
/// `ArtworkThumbnail(isTrack: true)`) when the user's `AlbumArtworkStyle`
/// setting is `.vinyl`, a plain circle-cropped photo otherwise (today's
/// original look, unchanged) — the spin mechanism itself is identical
/// either way and was NOT touched to add this; only the one
/// `ArtworkThumbnail` call gained `isTrack: true`.
///
/// **Broadcast button** (replaces the old dismiss ✕, per direct product
/// decision — the bar is no longer dismissable from here at all; the only
/// way to stop playback now is the transport controls themselves, or
/// `NowPlayingView`'s own "Leave" affordance for a sync-follow session).
/// Starts or reopens a listening party — the same `party.popper`/
/// `StartPartySheet` action that used to live in `FeedView`'s toolbar,
/// moved here since it's now reachable from every tab, not just Feed, and
/// makes more sense anchored to "what's currently playing" (a party
/// broadcasts the current track) than floating in a nav bar disconnected
/// from playback state. Hidden while this device is itself following
/// someone else's broadcast (`playerVM.followContext != nil`) — starting
/// your own party while tuned into someone else's doesn't make sense, and
/// that state already shows its own live-indicator icon in the transport
/// slot.
///
/// **"Start an LP" is presented from `MainTabView`'s stable root, NOT
/// from here**, bound to `partyVM.showStartPartySheet` rather than local
/// `@State` — confirmed via a real device console capture that this view,
/// hosted inside `.tabViewBottomAccessory`, gets torn down and rebuilt on
/// its own (visible continuously during normal use, not just around a tap
/// — the same accessory instability already noted above), which silently
/// resets local `@State` back to `false` moments after being set `true`.
/// That's what made the sheet flash open and immediately close — nothing
/// ever dismissed it, the state backing it just evaporated. Tapping
/// broadcast here only sets the flag on the externally-owned `partyVM`,
/// which survives this view's own churn; see `showStartPartySheet`'s own
/// doc comment on `ListeningPartyViewModel`.
struct MiniPlayerBar: View {
    @EnvironmentObject private var playerVM: PlayerViewModel
    @EnvironmentObject private var partyVM:  ListeningPartyViewModel

    /// The app's scene phase. The disc animation MUST be frozen whenever the
    /// scene isn't `.active`: this app declares `UIBackgroundModes: audio`, so
    /// while the screen is locked mid-playback the process keeps running and is
    /// NOT suspended — a `.repeatForever` Core Animation therefore keeps trying
    /// to commit/fence with the render server, which won't service it while
    /// locked. That wedges the CoreAnimation fence, and the next foreground
    /// `CA::Context::commit_transaction` blocks on a sync reply that times out —
    /// the "purple screen on reopen" (main thread parked in QuartzCore).
    @Environment(\.scenePhase) private var scenePhase

    /// Rotation is a pure function of wall-clock time, driven by
    /// `TimelineView(.animation(paused:))` rather than a discrete `Bool`
    /// toggle. A two-value (`0`/`360`) boolean can only ever freeze at one of
    /// those two literal angles — every pause, and every transient
    /// `scenePhase` blip away from `.active`, hard-snapped the disc back to 0°
    /// instead of holding wherever it visually was, which read as "spins
    /// inconsistently." `TimelineSchedule.animation(paused:)` freezes
    /// `context.date` in place while paused and resumes advancing from there,
    /// with no timer/Combine overhead.
    private func rotationAngle(at date: Date) -> Angle {
        let seconds = date.timeIntervalSinceReferenceDate
        return .degrees((seconds / 8.0 * 360).truncatingRemainder(dividingBy: 360))
    }

    var body: some View {
        if let track = playerVM.nowPlaying {
            // The whole pill is tappable (opens `NowPlayingView`), but the
            // play/pause and broadcast controls inside it need to override
            // that. This used to be `.onTapGesture` on the HStack below,
            // which is a known SwiftUI footgun when mixed with nested
            // `Button`s styled `.plain`: the ancestor's tap gesture can
            // ALSO fire alongside a nested button's own action, not just
            // instead of it. A `Button` wrapping the row, with the
            // play/pause and broadcast controls as genuinely NESTED
            // `Button`s inside it, is the reliable pattern instead — nested
            // buttons correctly claim priority over an ancestor `Button`'s
            // own action, unlike a plain `.onTapGesture`.
            Button {
                playerVM.isExpanded = true
            } label: {
            HStack(spacing: 12) {
                // Circular spinning artwork
                TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                        paused: !(playerVM.isPlaying && scenePhase == .active))) { context in
                    ArtworkThumbnail(url: track.artwork, size: 44, isTrack: true)
                        .clipShape(Circle())
                        .rotationEffect(rotationAngle(at: context.date))
                }
                    .frame(width: 44, height: 44)
                    // Redundant outer clip, on top of the inner one above —
                    // kept even though the `.inline` placement transition
                    // that originally motivated it is gone (no more
                    // scroll-triggered merge into the tab bar): a rotated
                    // circle staying within its own bounds is otherwise only
                    // guaranteed under normal uniform layout, and this is a
                    // cheap, harmless belt-and-suspenders guarantee that the
                    // render can never show content past this boundary.
                    .clipShape(Circle())
                    .overlay(
                        Circle().strokeBorder(Color.nodalong.textOnAccent.opacity(0.12), lineWidth: 1)
                    )
                    .compositingGroup()

                // `.frame(maxWidth: .infinity)` here (instead of a trailing
                // `Spacer()`) is what makes this column's ALLOCATED width
                // bounded and readable by `MarqueeText`'s own measurement —
                // it fills exactly the space a `Spacer()` used to leave
                // blank, so short titles look identical to before, but a
                // long one now has a concrete width to scroll within
                // instead of just truncating.
                VStack(alignment: .leading, spacing: 1) {
                    MarqueeText(
                        text:  track.title,
                        font:  Font.nodalong.subheadlineMedium,
                        color: Color.nodalong.textOnAccent,
                        repeats: true
                    )
                    Text(track.artist)
                        .font(Font.nodalong.caption)
                        .foregroundStyle(Color.nodalong.textOnAccent.opacity(0.65)).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if playerVM.followContext == nil {
                    // Play / pause
                    Button {
                        Task { await playerVM.togglePlayPause() }
                    } label: {
                        Image(systemName: playerVM.isPlaying ? "pause.fill" : Icons.play)
                            .font(Font.nodalong.title3).foregroundStyle(Color.nodalong.textOnAccent)
                            .frame(width: 36, height: 36)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)

                    // Broadcast — start (or reopen) a listening party. See
                    // this type's own doc comment for why this replaced the
                    // old dismiss (✕) here, why it's hidden while following
                    // someone else's broadcast, and why starting a party
                    // sets a flag on `partyVM` rather than local state.
                    Button {
                        if partyVM.isActive { partyVM.reopen() } else { partyVM.showStartPartySheet = true }
                    } label: {
                        NodalongMark(size: 30)
                            .foregroundStyle(partyVM.isActive ? Color.nodalong.purpleAccent : Color.nodalong.textOnAccent.opacity(0.75))
                            .frame(width: 36, height: 36)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                } else {
                    // Following (radio / view-only): no transport, just a
                    // live indicator — leaving is via `NowPlayingView`'s own
                    // "Leave" affordance, not from this bar.
                    NodalongMark(size: 30)
                        .foregroundStyle(Color.nodalong.purpleAccent)
                        .frame(width: 36, height: 36)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color.nodalong.purpleDark)
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .strokeBorder(Color.nodalong.textOnAccent.opacity(0.08), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.4), radius: 18, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            }
            .buttonStyle(.plain)
            .playbackErrorAlert()
        }
    }
}

#if DEBUG
#Preview {
    ZStack {
        Color.nodalong.bgBase.ignoresSafeArea()
        VStack {
            Spacer()
            MiniPlayerBar()
                .frame(height: 62)
                .padding(.horizontal, 12)
                .padding(.bottom, 96)
        }
    }
    .withPreviewEnvironment()
}
#endif
