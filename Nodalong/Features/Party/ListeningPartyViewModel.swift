import Foundation
import UIKit
import Combine
import FirebaseFirestore
import NodalongKit

/// Drives one listening-party session — the app's **first real-time surface**.
///
/// Owns two Firestore snapshot listeners (party doc + queue) and the RTDB live
/// layer (`PartyLiveService`: presence + now-playing). Everything is torn down
/// in `leave()`, which the party screen calls on `.onDisappear`.
///
/// Listener lifecycle note: unlike the NearMe 60fps *timer* (which had to stop
/// on background to avoid the jetsam CPU watchdog), these are **event-driven**
/// Firestore/RTDB listeners — cheap when idle — and a DJ **host legitimately
/// keeps hosting while backgrounded** (the app has `UIBackgroundModes: audio`).
/// So we detach on explicit leave / screen dismissal, NOT on scene-phase
/// background. Presence still auto-clears on a real disconnect via RTDB
/// `onDisconnect`.
@MainActor
final class ListeningPartyViewModel: ObservableObject {
    @Published private(set) var party: ListeningParty?
    @Published private(set) var queue: [PartyQueueTrack] = []
    @Published private(set) var participants: [PartyParticipant] = []
    @Published private(set) var remoteNowPlaying: PartyNowPlaying?
    /// How the LOCAL participant is listening. Guests default to `.inRoom`
    /// (watch the DJ); switching to `.sync` plays the host's track on this device.
    /// The host is always the source, so this stays `.inRoom` for them.
    @Published private(set) var myListenMode: PartyListenMode = .inRoom
    @Published private(set) var isActive = false
    /// Whether the full-screen party UI is shown. The *session* (`isActive`)
    /// outlives this — dismissing the cover minimizes the party, it doesn't
    /// leave it; re-open from the Feed banner.
    @Published var presenting = false
    /// Whether the "Start an LP" form is shown. Deliberately lives here
    /// (an externally-owned, persistent object) rather than as local
    /// `@State` on `MiniPlayerBar` — confirmed via a real device console
    /// capture that `MiniPlayerBar`, hosted inside `.tabViewBottomAccessory`,
    /// gets torn down and rebuilt on its own (visible continuously, not just
    /// around a tap — a known instability of that API, see this app's own
    /// prior notes on it), which silently resets local `@State` back to
    /// `false` moments after being set `true`. That's what made the sheet
    /// flash open and immediately close: nothing ever explicitly dismissed
    /// it, the state backing it just evaporated. `MainTabView`'s own root
    /// (not the accessory) presents the sheet bound to THIS flag instead,
    /// mirroring the same pattern already used for `NowPlayingView`'s and
    /// `PartyView`'s own covers — both live on that same stable root for
    /// exactly this reason.
    @Published var showStartPartySheet = false
    @Published var errorMessage: String?
    /// Brief "Added to party queue" confirmation, mirroring
    /// `PlayerViewModel.queueToast`. Rendered by `QueueToastOverlay`.
    @Published private(set) var queueToast: String?
    /// Set when a party ends and its queue is frozen into a playlist — drives
    /// the "Party ended" summary in `PartyView`. Nil while a party is live.
    @Published private(set) var endedPlaylist: Playlist?

    private let live = PartyLiveService()
    private var partyListener: ListenerRegistration?
    private var queueListener: ListenerRegistration?
    private var me: UserProfile?
    /// Host-only subscriptions bridging `playerVM`'s playback state into the
    /// RTDB broadcast + local-queue reconcile. Deliberately owned by THIS VM
    /// (session lifetime, `enter()`→`leave()`/`endPartyAndFreeze()`) rather than
    /// by `PartyView`'s `.onChange` — the host can minimize the party screen and
    /// keep hosting in the background (see class doc above), and a View-scoped
    /// trigger would silently stop firing the moment that happens.
    private var cancellables = Set<AnyCancellable>()
    /// The player this session is bridged to (set in `enter`). Used by the host
    /// to sample playback position for sync broadcasts.
    private weak var playerVM: PlayerViewModel?
    /// Last catalog id the host broadcast — lets `hostBroadcast` send position 0
    /// on a track change (the `nowPlaying`-change sink fires before the new
    /// track's position resets, so sampling then would send the *previous*
    /// track's end position) and the live position on same-track updates.
    private var lastBroadcastCatalogId: String?
    /// Host-only ~12s keepalive that re-broadcasts the current position while
    /// playing — bounds staleness for a late-joining sync-listener and catches
    /// host seeks. Only ticks while playing; torn down on leave/end.
    private var hostKeepaliveTimer: Timer?
    private static let hostKeepaliveInterval: TimeInterval = 12
    /// While syncing, watches the player's follow state so that if it ends from
    /// elsewhere (e.g. the mini-player's Leave), this participant's mode falls
    /// back to `.inRoom` — keeping presence/counts and the player consistent.
    private var syncFollowCancellable: AnyCancellable?

    var myUid: String? { me?.uid }
    var isHost: Bool { party.map { $0.hostUid == me?.uid } ?? false }
    var liveAvailable: Bool { live.isAvailable }

    /// Whether the current user may add tracks (host always; others only when
    /// the party permits open adds).
    var canAddToQueue: Bool {
        guard let party else { return false }
        return isHost || party.permission == .anyoneCanAdd
    }

    /// The enriched queue track matching the host's now-playing pointer — what
    /// remote participants render as "Now playing".
    var displayedNowPlaying: PartyQueueTrack? {
        guard let cid = remoteNowPlaying?.catalogId else { return nil }
        return queue.first { $0.catalogId == cid }
    }

    /// Queue as playable songs (host feeds these to `PlayerViewModel`).
    var playableSongs: [Song] { queue.map { Song.from(partyQueueTrack: $0) } }

    /// How many participants are playing in sync vs just watching — shown in the
    /// party header ("N in sync • M in the room").
    var syncListenerCount: Int { participants.filter { $0.mode == .sync }.count }
    var inRoomCount: Int { participants.filter { $0.mode == .inRoom }.count }

    /// The queue filtered to not-yet-played tracks — what "Up Next" actually
    /// shows. History (already-played tracks, including the currently-playing
    /// one — see `hostBroadcast`, which marks a track played the moment it
    /// starts) is omitted from the live view; it's preserved regardless in the
    /// frozen playlist on end.
    var upcomingQueue: [PartyQueueTrack] { queue.filter { !$0.played } }

    // MARK: - Session lifecycle

    /// Host: create a new party and enter it (presenting the UI).
    func createAndEnter(title: String, permission: PartyPermission, me: UserProfile, playerVM: PlayerViewModel) async {
        // Defense in depth: end any of my own still-`.live` parties first (the
        // launch-time cleanup in `ContentView` is the primary fix, this just
        // covers a same-session double-start / a race before that ran).
        await endOrphanedLiveParties(hostUid: me.uid)
        do {
            let id = try await createParty(
                hostUid: me.uid, hostUsername: me.username,
                hostAvatarEmoji: me.avatarEmoji, hostAvatarColor: me.avatarColor,
                title: title.isEmpty ? "\(me.username)'s LP" : title,
                permission: permission
            )
            // Carry over whatever's already loaded/playing locally — must run
            // BEFORE `enter()` wires the queue-listener → `reconcileQueue`
            // bridge, or the party's first snapshot is empty and playback
            // keeps being driven by the stale pre-party local queue. Best
            // effort: a seed failure shouldn't block starting the party; the
            // host can still add tracks manually afterward, same as today.
            if let current = playerVM.currentItem?.song {
                let songs = [current] + playerVM.upNext.map(\.song)
                do {
                    try await seedPartyQueue(partyId: id, songs: songs, hostUid: me.uid, hostUsername: me.username)
                } catch {
                    print("[Nodalong.Party] seedPartyQueue failed for party \(id): \(error)")
                }
            }
            if let party = try await getParty(id: id) {
                enter(party: party, me: me, playerVM: playerVM)
                presenting = true
            }
        } catch {
            errorMessage = "Couldn't start the LP."
        }
    }

    /// Guest: join an existing live party (friend-gating enforced by the caller).
    func joinAndEnter(_ party: ListeningParty, me: UserProfile, playerVM: PlayerViewModel) {
        enter(party: party, me: me, playerVM: playerVM)
        presenting = true
    }

    /// Re-open the UI for the session already in progress.
    func reopen() { if isActive { presenting = true } }

    /// Attaches all listeners + presence for `party`. Idempotent.
    ///
    /// When entering as the host, also bridges `playerVM`'s playback state into
    /// the RTDB now-playing broadcast and the local-queue reconcile — gated at
    /// SETUP time (not just inside the handlers) so a guest's `enter()` never
    /// touches their own unrelated local playback at all.
    func enter(party: ListeningParty, me: UserProfile, playerVM: PlayerViewModel) {
        guard !isActive else { return }
        self.me = me
        self.party = party
        self.playerVM = playerVM
        isActive = true

        partyListener = listenToParty(partyId: party.id) { [weak self] p in
            Task { @MainActor in self?.party = p ?? self?.party }
        }
        queueListener = listenToPartyQueue(partyId: party.id) { [weak self] q in
            Task { @MainActor in self?.queue = q }
        }

        // Host records its authority in the live node so RTDB rules can gate
        // host-only now-playing writes.
        if party.hostUid == me.uid {
            live.setHost(partyId: party.id, hostUid: me.uid)

            Publishers.CombineLatest(playerVM.$nowPlaying, playerVM.$isPlaying)
                .sink { [weak self] nowPlaying, isPlaying in
                    self?.hostBroadcast(catalogId: nowPlaying?.catalogId, isPlaying: isPlaying)
                }
                .store(in: &cancellables)

            $queue
                .sink { [weak playerVM] queue in
                    playerVM?.reconcileQueue(with: queue.map { Song.from(partyQueueTrack: $0) })
                }
                .store(in: &cancellables)

            hostKeepaliveTimer = Timer.scheduledTimer(withTimeInterval: Self.hostKeepaliveInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let pvm = self.playerVM, pvm.isPlaying else { return }
                    self.hostBroadcast(catalogId: pvm.nowPlaying?.catalogId, isPlaying: true)
                }
            }
        }
        live.joinPresence(partyId: party.id, participant: PartyParticipant(
            id: me.uid, username: me.username,
            avatarEmoji: me.avatarEmoji, avatarColor: me.avatarColor,
            joinedAt: Date().timeIntervalSince1970 * 1000
        ))
        live.observePresence(partyId: party.id) { [weak self] ps in
            Task { @MainActor in self?.participants = ps }
        }
        live.observeNowPlaying(partyId: party.id) { [weak self] np in
            Task { @MainActor in
                self?.remoteNowPlaying = np
                self?.feedSyncUpdate()   // no-op unless the local participant is syncing
            }
        }
    }

    /// Detaches every listener/handle and removes presence. Safe to call twice.
    func leave() {
        guard isActive else { return }
        partyListener?.remove(); partyListener = nil
        queueListener?.remove(); queueListener = nil
        live.leavePresence()
        live.detachAll()
        cancellables.removeAll()
        hostKeepaliveTimer?.invalidate(); hostKeepaliveTimer = nil
        lastBroadcastCatalogId = nil
        syncFollowCancellable?.cancel(); syncFollowCancellable = nil
        if myListenMode == .sync { playerVM?.stopFollowing() }
        myListenMode = .inRoom
        isActive = false
        presenting = false
        party = nil
        queue = []
        participants = []
        remoteNowPlaying = nil
    }

    // MARK: - Actions

    func addToQueue(_ song: Song) {
        guard let party, canAddToQueue, let me else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            do {
                try await addToPartyQueue(
                    partyId: party.id, song: song,
                    addedByUid: me.uid, addedByUsername: me.username
                )
                flashQueueToast(song.title)
            } catch {
                errorMessage = "Couldn't add to the queue."
            }
        }
    }

    private func flashQueueToast(_ title: String) {
        queueToast = title
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            queueToast = nil
        }
    }

    func removeFromQueue(_ track: PartyQueueTrack) {
        guard let party, isHost else { return }
        Task { try? await removeFromPartyQueue(partyId: party.id, trackDocId: track.id) }
    }

    /// Host reorders the party queue (drag-to-reorder in `PartyView`, over the
    /// unplayed-only `upcomingQueue` — "Up Next" only shows/edits those, so
    /// `offsets`/`destination` are relative to THAT filtered subsequence, not
    /// the full `queue`). Computes the new `order` from the adjacent UNPLAYED
    /// neighbours — still a globally-correct position, since a midpoint between
    /// two tracks' order values sorts correctly regardless of what other
    /// (played, earlier-order) tracks exist elsewhere in the space. Single
    /// Firestore write; the snapshot listener is the final word. Host-gated.
    func moveQueueTrack(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard isHost, let party else { return }
        var unplayed = upcomingQueue
        guard let src = offsets.first, unplayed.indices.contains(src) else { return }
        let moving = unplayed[src]
        unplayed.remove(at: src)
        let insertAt = min(max(destination > src ? destination - 1 : destination, 0), unplayed.count)
        unplayed.insert(moving, at: insertAt)

        let before = insertAt > 0 ? unplayed[insertAt - 1].order : nil
        let after  = insertAt < unplayed.count - 1 ? unplayed[insertAt + 1].order : nil
        let newOrder = PlaylistOrder.midpoint(before: before, after: after)

        // Optimistic reflect into the full `queue` (which `upcomingQueue`
        // re-derives from) so the UI updates immediately.
        if let idx = queue.firstIndex(where: { $0.id == moving.id }) {
            queue[idx].order = newOrder
        }
        Task {
            try? await reorderPartyQueueTrack(
                partyId: party.id, trackDocId: moving.id, before: before, after: after
            )
        }
    }

    // MARK: - Listen mode (in-room vs sync)

    /// Guest action: switch between watching (in the room) and playing in sync.
    /// The host is always the source, so this no-ops for the host. Writes the
    /// mode to presence (so the counts update for everyone) and starts/stops the
    /// local follow engine.
    func setListenMode(_ mode: PartyListenMode) {
        guard !isHost, myListenMode != mode, let party else { return }
        myListenMode = mode
        live.updateListenMode(mode)
        if mode == .sync {
            playerVM?.beginFollowing(label: "Tuned in to \(party.hostUsername)", mode: .station)
            // Reconcile back to in-room if the follow ends from elsewhere (Leave).
            // `dropFirst` ignores the just-set non-nil context.
            syncFollowCancellable = playerVM?.$followContext
                .dropFirst()
                .sink { [weak self] ctx in if ctx == nil { self?.setListenMode(.inRoom) } }
            feedSyncUpdate()
        } else {
            syncFollowCancellable?.cancel(); syncFollowCancellable = nil
            playerVM?.stopFollowing()
        }
    }

    /// Pushes the host's now-playing pointer into the local player's follow
    /// engine (station mode). Called on each host broadcast while syncing.
    private func feedSyncUpdate() {
        guard myListenMode == .sync, !isHost,
              let np = remoteNowPlaying, !np.catalogId.isEmpty, let playerVM else { return }
        // A host who's dropped to the preview fallback (e.g. lost their
        // subscription mid-party) would cycle every ~30s — sync would follow
        // that cycling rather than a real track. Fall back to in-room instead
        // of feeding a broken timeline.
        guard !np.isPreviewPlayback else { setListenMode(.inRoom); return }
        let timeline = SyncTimeline(
            catalogId: np.catalogId, positionMs: np.positionMs ?? 0,
            isPlaying: np.isPlaying, serverUpdatedAt: np.updatedAt
        )
        let target = timeline.targetPositionMs(serverNowMs: ServerClock.shared.serverNowMs())
        let catalogId = np.catalogId
        let isPlaying = np.isPlaying
        Task {
            let song = await songForCatalog(catalogId)
            await playerVM.applyFollowTimeline(
                catalogId: catalogId, targetPositionMs: target,
                isPlaying: isPlaying, song: song
            )
        }
    }

    /// Resolves a catalog id to a playable `Song` — prefers the already-enriched
    /// party queue (the host plays from it), falling back to the catalog cache.
    private func songForCatalog(_ catalogId: String) async -> Song? {
        if let track = queue.first(where: { $0.catalogId == catalogId }) {
            return Song.from(partyQueueTrack: track)
        }
        let meta = await CatalogCache.shared.metadata(for: [catalogId])
        return meta[catalogId].map { Song.from(catalogTrack: $0, catalogId: catalogId) }
    }

    /// Host bridge: broadcast the current track (position + play-state, on a
    /// server clock, so remote listeners can play it in sync) and mark it played.
    /// Called from the host's `nowPlaying`/`isPlaying` sink and the keepalive.
    func hostBroadcast(catalogId: String?, isPlaying: Bool) {
        guard isHost, let party, let catalogId, !catalogId.isEmpty else { return }
        // On a track change, the position sample would be the *previous* track's
        // end (the sink fires before the new track's position resets), so send 0;
        // on a same-track update sample the live position.
        let positionMs = (catalogId != lastBroadcastCatalogId) ? 0 : (playerVM?.currentPositionMs ?? 0)
        lastBroadcastCatalogId = catalogId
        live.writeNowPlaying(partyId: party.id, PartyNowPlaying(
            catalogId: catalogId, positionMs: positionMs,
            isPlaying: isPlaying, updatedAt: ServerClock.shared.serverNowMs(),
            isPreviewPlayback: playerVM?.isPreviewPlayback ?? false
        ))
        if let track = queue.first(where: { $0.catalogId == catalogId && !$0.played }) {
            Task { try? await markPartyQueueTrackPlayed(partyId: party.id, trackDocId: track.id) }
        }
    }

    /// Host ends the party: freeze the queue into a playlist, tear down the live
    /// layer, and set `endedPlaylist` so `PartyView` can show the "party ended"
    /// summary (the cover stays up until the host taps Done → `dismissEndedSummary`).
    /// Returns the frozen playlist id (nil if the queue was empty or the freeze
    /// failed — the latter surfaced via `errorMessage`, not swallowed silently).
    @discardableResult
    func endPartyAndFreeze() async -> String? {
        guard isHost, let party else { return nil }
        var playlistId: String? = nil
        do {
            playlistId = try await endParty(party)
        } catch {
            errorMessage = "Couldn't save the LP playlist."
            print("[Nodalong.Party] endParty failed: \(error)")
        }
        // The party is over — detach listeners + presence + clear live state, but
        // keep `party` and set `endedPlaylist` so the summary can render.
        partyListener?.remove(); partyListener = nil
        queueListener?.remove(); queueListener = nil
        live.leavePresence()
        live.detachAll()
        cancellables.removeAll()
        hostKeepaliveTimer?.invalidate(); hostKeepaliveTimer = nil
        lastBroadcastCatalogId = nil
        live.clearLive(partyId: party.id)
        isActive = false
        if let pid = playlistId {
            endedPlaylist = try? await getPlaylist(id: pid)
        }
        return playlistId
    }

    /// Dismisses the "party ended" summary and fully closes the party UI.
    func dismissEndedSummary() {
        endedPlaylist = nil
        presenting = false
        party = nil
        queue = []
        participants = []
        remoteNowPlaying = nil
    }

    #if DEBUG
    static var mockPreview: ListeningPartyViewModel {
        let vm = ListeningPartyViewModel()
        vm.party = PreviewFixtures.party
        vm.queue = PreviewFixtures.partyQueue
        vm.participants = PreviewFixtures.partyParticipants
        vm.isActive = true
        return vm
    }
    #endif
}
