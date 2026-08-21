import Foundation
import UIKit
import MediaPlayer
import AVFoundation
import MusicKit
import NodalongKit

/// Lightweight data shape pushed to the MiniPlayerBar / NowPlayingView. The
/// VM unwraps a `NodalongKit.Song` into this struct so the UI doesn't depend
/// on the larger model.
struct NowPlayingTrack: Sendable, Equatable {
    let title:     String
    let artist:    String
    /// Album title — shown on the full-screen player and used to resolve
    /// an `AlbumResult` for navigation.
    let album:     String
    let artwork:   String
    let uri:       String
    /// Apple Music catalog ID — used to check / update the shelf like state.
    let catalogId: String?
    /// International Standard Recording Code, when known — used as a
    /// fallback anchor when resolving the track's real album/artist
    /// relationships for Now Playing's album/artist taps (a library-matched
    /// recently-played track's `catalogId` can be a library-scoped id, not a
    /// real catalog id, so this is the next-best anchor).
    let isrc: String?

    /// Explicit init (rather than relying on the synthesized memberwise one)
    /// so `isrc` can default to `nil` for call sites that don't have it yet,
    /// without touching them.
    init(
        title: String,
        artist: String,
        album: String,
        artwork: String,
        uri: String,
        catalogId: String?,
        isrc: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artwork = artwork
        self.uri = uri
        self.catalogId = catalogId
        self.isrc = isrc
    }
}

/// Holds the rapidly-changing playback position, kept **separate** from
/// `PlayerViewModel`.
///
/// Why its own object: the progress timer writes 2–10 times a second while a
/// track plays. If `progress` lived on `PlayerViewModel` (a plain
/// `ObservableObject`, which has no per-property change granularity), every one
/// of those writes would fire `objectWillChange` and re-render *every* view that
/// reads any part of `playerVM` — Feed, Profile, etc. — twice a second,
/// hitching scroll. Isolating it here means only the views that actually show
/// progress (the full-screen scrubber) re-render on each tick.
@MainActor
final class PlaybackClock: ObservableObject {
    /// Normalised playback position, 0–1.
    @Published var progress: Double = 0
    /// Current track length in seconds.
    @Published var duration: TimeInterval = 0
}

/// How a sync-follower ("radio" listener) tracks its broadcaster's timeline.
enum FollowMode: Equatable, Sendable {
    /// Follow track-to-track continuously until the follower leaves (party sync).
    case station
    /// Sync only the current track; end the session when it changes or finishes
    /// (NearMe "tune in").
    case singleTrack
}

/// Identifies an active sync-follow ("radio") session. When set on
/// `PlayerViewModel`, this device is a **pure receiver** — the broadcaster drives
/// the timeline and the follower's own transport controls are hidden (see the
/// "radio / view-only" product decision).
struct FollowContext: Equatable, Sendable {
    /// e.g. "Tuned in to alex" — shown in place of transport controls.
    var label: String
    var mode: FollowMode
    /// Catalog id of the track currently being followed (`""` until the first
    /// timeline update loads a track).
    var catalogId: String
}

/// Tracks what's currently playing and drives `MiniPlayerBar` + `NowPlayingView`.
///
/// Dual-mode playback:
/// - **Subscribers** play full tracks via `ApplicationMusicPlayer.shared`.
///   iOS handles the audio session, lock-screen metadata, and Control Center
///   automatically — no manual `MPNowPlayingInfoCenter` writes needed.
/// - **Non-subscribers** fall back to 30-second preview URLs via `AVPlayer`.
///   For that path we still write `MPNowPlayingInfoCenter` manually so the
///   lock screen shows track info.
///
/// Cross-service resolution: input `Song` may be Apple-Music-sourced
/// (`song.uri` is a `MusicItemID`), Spotify-sourced from a legacy post (use
/// ISRC bridge), or a fresh search result. `resolve(_:)` tries each in order.
@MainActor
final class PlayerViewModel: ObservableObject {
    /// `didSet` (not a SwiftUI `.task` on some view) is deliberate — an
    /// earlier version prefetched from `MiniPlayerBar.task(id: track.uri)`,
    /// which turned out to restart every time the system tore down and
    /// recreated that view during its own scroll-driven `.inline`/`.expanded`
    /// placement transitions (a real, observed, on-device failure — dozens
    /// of real re-resolves per second, thrashing `resolveDetailedSong`'s
    /// single-entry memo between whatever two tracks happened to be
    /// involved). `PlayerViewModel` itself has a stable, app-wide lifecycle
    /// no view teardown can disturb, so hooking the actual state mutation
    /// point is the only way to fire this exactly once per genuine track
    /// change, regardless of how many views are watching or being recreated.
    @Published private(set) var nowPlaying: NowPlayingTrack? = nil {
        didSet {
            guard nowPlaying?.uri != oldValue?.uri else { return }
            prefetchDetailsForCurrentTrack()
        }
    }
    @Published private(set) var isPlaying      = false
    /// Speculative artist/album resolve for the currently-playing track — see
    /// `MiniPlayerBar`'s prefetch `.task`, which is what populates these.
    /// `NowPlayingView`'s own tap handlers check here first, keyed on the
    /// track's `uri`, so a resolve for a PREVIOUS track (still present for a
    /// moment while the new one's own prefetch is in flight) can never be
    /// mistaken for the current one's answer.
    @Published private(set) var prefetchedAlbumForUri:   (uri: String, album: AlbumResult)? = nil
    @Published private(set) var prefetchedArtistsForUri: (uri: String, artists: [ArtistResult])? = nil

    func setPrefetchedAlbum(_ album: AlbumResult?, forUri uri: String) {
        guard let album else { return }
        prefetchedAlbumForUri = (uri, album)
    }

    func setPrefetchedArtists(_ artists: [ArtistResult], forUri uri: String) {
        guard !artists.isEmpty else { return }
        prefetchedArtistsForUri = (uri, artists)
    }

    /// Fires exactly once per genuine track change (see `nowPlaying`'s
    /// `didSet`) — speculatively resolves the CURRENT track's real
    /// album/artist so `NowPlayingView`'s tap handlers usually find an
    /// already-populated `prefetchedAlbumForUri`/`prefetchedArtistsForUri`
    /// instead of paying the ~260ms–1.2s resolve cascade cold.
    private func prefetchDetailsForCurrentTrack() {
        guard activeService == .appleMusic, let track = nowPlaying, let service = musicService else { return }
        let uri = track.uri
        Task { [weak self] in
            if let album = await service.resolveAlbum(
                catalogTrackId: track.catalogId, isrc: track.isrc, title: track.album, artist: track.artist,
                trackTitle: track.title
            ) {
                self?.setPrefetchedAlbum(album, forUri: uri)
            }
        }
        Task { [weak self] in
            let artists = await service.resolveArtists(
                catalogTrackId: track.catalogId, isrc: track.isrc, title: track.title, artist: track.artist
            )
            self?.setPrefetchedArtists(artists, forUri: uri)
        }
    }
    /// Whether the full-screen `NowPlayingView` is presented. Drives the
    /// progress-timer cadence: the full player has a scrubber that wants ~10 Hz,
    /// but the mini bar shows no progress at all, so when collapsed we poll at a
    /// lazy 2 Hz. (Progress now lives on `clock`, so ticks only re-render the
    /// scrubber — but a slower collapsed cadence still saves needless work.)
    /// Restarts the timer on change.
    @Published var isExpanded = false {
        didSet {
            guard oldValue != isExpanded, progressTimer != nil else { return }
            startProgressTimer()
        }
    }
    /// High-frequency progress + duration live in a separate observable so the
    /// progress timer doesn't re-render the whole `playerVM` view tree. Only
    /// `NowPlayingView` observes this directly (injected into the environment).
    let clock = PlaybackClock()

    /// Normalised playback position (0–1). Forwards to `clock` — mutating it
    /// notifies `clock`'s observers, NOT `playerVM`'s.
    var progress: Double {
        get { clock.progress }
        set { clock.progress = newValue }
    }
    /// Total duration of the current track in seconds. Exposed so
    /// `NowPlayingView` can show real elapsed / remaining times.
    var currentDuration: TimeInterval {
        get { clock.duration }
        set { clock.duration = newValue }
    }

    // MARK: - Queue

    /// The full ordered queue, **including** the currently-playing item at
    /// `currentIndex`. This is the single source of truth for playback order —
    /// only one track is ever loaded into the underlying player at a time, so
    /// "Up Next" lives entirely here and reorder/remove are pure array edits.
    @Published private(set) var queue: [QueueItem] = []
    /// Index of the now-playing entry within `queue`.
    @Published private(set) var currentIndex: Int = 0

    /// The entry currently playing, if any.
    var currentItem: QueueItem? {
        queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
    }
    /// Entries after the current one — what the Up Next list shows.
    var upNext: [QueueItem] {
        hasNext ? Array(queue[(currentIndex + 1)...]) : []
    }
    /// `true` when there's a track after the current one.
    var hasNext: Bool { currentIndex + 1 < queue.count }
    /// `true` when there's a track before the current one.
    var hasPrevious: Bool { currentIndex > 0 }

    /// Set when the resolved track has no playable subscription rendition and
    /// no preview URL either. UI can present a "track unavailable" alert.
    @Published var trackUnavailable: Bool = false

    // MARK: - Active service (Stage B: Spotify playback)

    /// Which backend `playCurrent()`/`togglePlayPause()`/`seek()` route
    /// through. Kept in sync with `authVM.profile?.activeService` by
    /// `ContentView`. Defaults to `.appleMusic` — the existing, unchanged
    /// path for every user who hasn't linked Spotify.
    @Published var activeService: MusicServiceType = .appleMusic
    /// Set once via `configure(spotifyService:)`. `weak` — `PlayerViewModel`
    /// doesn't own this service's lifecycle, `NodalongApp` does.
    private weak var spotifyService: SpotifyMusicService?
    /// Set once via `configure(musicService:)` — backs the currently-playing
    /// track prefetch (see `nowPlaying`'s `didSet`). `weak` for the same
    /// reason as `spotifyService`.
    private weak var musicService: AppleMusicService?
    /// Persistent (not per-track) message for when nothing can play at all
    /// right now — e.g. no active Spotify Connect device anywhere. Distinct
    /// from `trackUnavailable`, which means "skip this one track and try the
    /// next"; this means "nothing will play until the user acts outside the
    /// app," so the UI should show it without triggering a skip.
    @Published var spotifyPlaybackError: String? = nil
    /// `true` from the moment a Spotify play attempt fails with
    /// `.noActiveDevice` until the next foreground return consumes it (or a
    /// fresh play attempt starts). Deliberately **separate** from
    /// `spotifyPlaybackError`: that flag drives the alert's `isPresented`
    /// binding, which SwiftUI clears the instant ANY alert button is
    /// tapped (including "Open Spotify") — so it can't also mean "there's
    /// still a pending retry to attempt" once the user has dismissed the
    /// alert. See `retryAfterSpotifyDeviceRecovery()`.
    @Published private(set) var awaitingSpotifyDeviceRetry: Bool = false
    /// The most recent underlying failure reason from either playback path
    /// (e.g. a Spotify HTTP error's description), shown appended to the
    /// generic "Track unavailable" alert so a user can read/report the real
    /// cause without needing an attached debugger — this surfaced a real gap
    /// on first on-device test, where the alert just said "Check your Apple
    /// Music access" even while Spotify was the active, failing service.
    @Published var lastPlaybackErrorDetail: String? = nil
    /// Polls `GET /me/player` while Spotify is the active service and
    /// something is playing — Spotify's Web API has no push/callback
    /// mechanism, so this is the only way to detect progress/end-of-track.
    private var spotifyPollTimer: Timer?

    /// One-time post-init wiring — `PlayerViewModel` is constructed with no
    /// dependencies (so it stays a simple `@StateObject` default value), so
    /// this is how it learns about `SpotifyMusicService`. Called once from
    /// `ContentView`'s existing cross-cutting wiring.
    func configure(spotifyService: SpotifyMusicService) {
        self.spotifyService = spotifyService
    }

    func configure(musicService: AppleMusicService) {
        self.musicService = musicService
    }

    /// Track title shown in the queue toast. Cleared after 1.5 s.
    @Published private(set) var queueToast: String? = nil
    /// Distinguishes what `queueToast` currently reports so `QueueToastOverlay`
    /// can choose the label/icon: `.added` (a track was queued) vs `.skipped`
    /// (a track was auto-skipped because it couldn't be resolved/played).
    enum QueueToastKind { case added, skipped }
    @Published private(set) var queueToastKind: QueueToastKind = .added

    /// True once a listening-party reconcile has taken ownership of the queue.
    /// Lets the party UI hide "Play Queue" (reconcile drives updates from then
    /// on) and is cleared by any explicit `play(_:)` / `play(_:startingAt:)` /
    /// `dismiss()` — all of which represent leaving the "party is the queue" model.
    /// `@Published` so the party UI reacts when it flips (changes rarely).
    @Published private(set) var isPartyDriven = false
    /// Latest party-queue snapshot received while a `skipUnplayableAndAdvance`
    /// retry chain was in flight — drained once the chain settles so a
    /// mid-recursion queue/index mutation can't corrupt it, without silently
    /// dropping the update (Firestore listeners only fire on real changes).
    private var pendingReconcile: [NodalongKit.Song]?

    // MARK: - Sync follow (radio)

    /// Non-nil while this device is following a broadcaster's timeline (a party
    /// host, or a nearby user tuned into via NearMe). Drives the UI to hide
    /// transport controls and show a "Tuned in — Leave" surface. Set/cleared only
    /// via `beginFollowing` / `stopFollowing`; timeline updates arrive via
    /// `applyFollowTimeline`, fed by a bridge that owns the RTDB read + `ServerClock`.
    @Published private(set) var followContext: FollowContext?
    /// Only re-seek a follower when it drifts past this from the target — small
    /// enough to stay well inside the ~10–20s tolerance, large enough that we
    /// don't jab the player with audible micro-seeks on every keepalive.
    private static let followDriftThresholdMs = 2500

    /// Current playback position in milliseconds, derived from the published
    /// progress/duration so it's backend-agnostic. Sampled by broadcasters to
    /// stamp their `SyncTimeline`.
    var currentPositionMs: Int { Int(progress * currentDuration * 1000) }
    /// `true` while playing a 30-second preview (non-subscriber fallback).
    /// Broadcasters expose this on their now-playing payload so followers can
    /// tell a track's full-length sync apart from a doomed 30s-cycling one —
    /// see `SyncTimeline`/`applyFollowTimeline`'s "block sync against a
    /// preview-mode broadcaster" gate.
    var isPreviewPlayback: Bool { isPreviewMode }

    private var previewPlayer: AVPlayer?
    private var progressTimer: Timer?
    private var isPreviewMode: Bool = false
    /// End-of-item observer for the preview `AVPlayer`, removed on teardown.
    private var previewEndObserver: NSObjectProtocol?
    /// Guards `handleTrackEnd()` against re-entry while an advance is in flight
    /// (the progress timer can fire several times before `playCurrent` resets
    /// progress to 0).
    private var isAdvancing = false
    /// `true` while `playCurrent()` is resolving + establishing a track. Stops
    /// the end-of-track edge detector from mistaking the brief `.paused` state
    /// during track hand-off for a finished track and advancing prematurely.
    private var isLoadingTrack = false
    /// `true` when a remote (Control Center / headphone) pause arrives while a
    /// track transition is already in flight (`isLoadingTrack == true`) — e.g.
    /// the user pauses right as the current track naturally ends and the
    /// auto-advance to the next queued track has already started resolving.
    /// `togglePlayPause()` can't safely call `player.pause()` in that window
    /// (the player may not have the next track loaded yet — a no-op that
    /// would otherwise leave `isPlaying == false` published while the new
    /// track's `player.play()` goes on to genuinely start audio moments
    /// later, unconditionally, since nothing in `playCurrent()`'s success
    /// path re-asserts `isPlaying` after that point). Recording the intent
    /// here and applying it once the new track actually finishes loading
    /// (see `playCurrent()`) guarantees the published state can never diverge
    /// from the real audio state, at the cost of the pause occasionally
    /// landing on the next track rather than the one that was ending —
    /// deliberate tradeoff, confirmed with the user over the alternative of
    /// trying to abort the in-flight advance.
    private var pendingPauseIntent = false
    /// `true` once the current item has actually been handed to a playback
    /// backend this session. After a cold-launch `restoreQueue()` the queue +
    /// now-playing surface are repopulated but **nothing is loaded into the
    /// player**, so the first play must go through `playCurrent()` to resolve +
    /// enqueue the track rather than calling `player.play()` on an empty queue.
    private var playerLoaded = false
    private let queueKey      = "nodalong.queue"
    private let queueIndexKey = "nodalong.queueIndex"
    /// Last observed `ApplicationMusicPlayer` status — used to detect the
    /// `.playing → .paused/.stopped` edge that signals end-of-track. A
    /// progress-threshold check (>= 0.985) is unreliable because MusicKit
    /// resets `playbackTime` to 0 the moment a single-entry queue finishes,
    /// so the heuristic never fires.
    private var lastPlaybackStatus: MusicKit.MusicPlayer.PlaybackStatus = .playing
    /// When a deliberate pause last happened, per `markExplicitPause()` below —
    /// checked by the end-of-track edge detector's 200ms confirmation so a
    /// remote (Control Center / headphone) pause can't be misread as the
    /// track ending. NOT MainActor-isolated: `MPRemoteCommandCenter` may
    /// invoke its command targets on a background thread, and this must be
    /// stamped synchronously from that callback — BEFORE the `Task { @MainActor
    /// in ... }` hop that runs `togglePlayPause()`. That hop's own scheduling
    /// latency (worse under system load, or right as the device locks) is the
    /// actual race the edge detector is vulnerable to; a stamp placed only
    /// inside `togglePlayPause()` would be gated behind the identical delay
    /// and would catch nothing.
    nonisolated(unsafe) private var _lastExplicitPauseAt: Date?
    private let explicitPauseLock = NSLock()
    private var lastExplicitPauseAt: Date? {
        get { explicitPauseLock.lock(); defer { explicitPauseLock.unlock() }; return _lastExplicitPauseAt }
        set { explicitPauseLock.lock(); defer { explicitPauseLock.unlock() }; _lastExplicitPauseAt = newValue }
    }
    /// Callable from any thread — see `lastExplicitPauseAt`'s doc comment.
    nonisolated private func markExplicitPause() {
        explicitPauseLock.lock(); _lastExplicitPauseAt = Date(); explicitPauseLock.unlock()
    }
    private static let explicitPauseGraceWindow: TimeInterval = 2.0
    /// The last `player.playbackTime` observed while `state.playbackStatus`
    /// was genuinely `.playing`, updated every progress-timer tick. Confirmed
    /// via on-device diagnostic logging (2/2 real Control Center pauses) that
    /// `MPRemoteCommandCenter.pauseCommand`'s registered target NEVER fires
    /// for `ApplicationMusicPlayer` — something in MusicKit's own built-in
    /// Control Center integration pauses the player directly, invisible to
    /// our own remote-command registration, so `lastExplicitPauseAt` never
    /// gets stamped for a Control Center pause and the old wall-clock grace
    /// window is structurally unable to help there (it depends on our own
    /// handler firing at all). This is the real, evidence-based signal that
    /// works regardless: how close the track actually was to its end the
    /// instant it stopped. See its use in `startProgressTimer()`.
    private var lastKnownElapsedWhilePlaying: TimeInterval = 0
    /// How close to a track's real duration counts as "it actually finished"
    /// rather than "something paused it early" — generous enough to absorb
    /// one tick interval's staleness (up to `progressInterval`, currently
    /// ≤0.5s) plus a track's final fade/silence before MusicKit reports the
    /// stop.
    private static let endOfTrackTolerance: TimeInterval = 3.0
    /// The Spotify URI Nodalong most recently told Spotify to play — lets
    /// `pollSpotifyPlaybackState()` detect when Spotify's actual current
    /// track diverges from what Nodalong expects (i.e. Spotify's own Next/
    /// Previous was used, via Control Center, headphones, or the real
    /// Spotify app).
    private var spotifyPlayingTrackUri: String?
    /// The Spotify URI + `QueueItem.id` most recently pushed to Spotify's
    /// native queue via `syncSpotifyNativeQueue()`. Needed to map a detected
    /// track change back to the right `QueueItem` — can't just search
    /// `queue` by raw `Song.uri`, since a queue item's own URI may be an
    /// Apple Music URI even when it's being played via Spotify (a
    /// cross-service resolve).
    private var spotifyQueuedNextUri: String?
    private var spotifyQueuedNextItemId: UUID?
    /// The next track's resolved `MusicKit.Song`, kept warm while the current
    /// track plays so advancing skips the (network) `resolve` round-trip — the
    /// dominant audible gap between tracks. Keyed by `uri`; a reorder/remove that
    /// changes the next track just yields a cache miss and falls back to a live
    /// resolve. See `prefetchNext()` / `resolveUsingCache(_:)`.
    private var prefetchedNext: (uri: String, song: MusicKit.Song)?
    /// The `QueueItem.id`s currently mirrored into MusicKit's own native
    /// queue as the previous/next entries around whatever's playing — lets
    /// repeat calls to `syncNativeQueueNeighbors()` no-op cheaply when
    /// neither has changed. `nil` means nothing is mirrored on that side
    /// (a queue boundary). See `syncNativeQueueNeighbors()`'s doc comment
    /// for why this exists: Control Center's next/previous were confirmed
    /// (via on-device diagnostic logging) to bypass our own registered
    /// `MPRemoteCommandCenter` targets entirely and be handled internally by
    /// MusicKit, which otherwise has nothing beyond the single current track
    /// to move to.
    private var mirroredPreviousItemId: UUID?
    private var mirroredNextItemId: UUID?

    /// When the app entered background — used by
    /// `observeScenePhaseForStaleConnection()` to detect a long-idle period
    /// on return, after which `ApplicationMusicPlayer`'s connection to the
    /// system media-player process can go stale.
    private var backgroundedAt: Date?
    /// How long backgrounded before treating the player as possibly stale.
    /// Below this, a quick app-switch-and-back is left alone (no forced
    /// restart-from-zero).
    private static let staleAfterBackgroundInterval: TimeInterval = 5 * 60

    init() {
        // Skip audio-session activation and remote-command registration inside
        // the Xcode preview agent — those APIs are unavailable in the sandbox.
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" {
            setupRemoteCommands()
            restoreQueue()
            observeScenePhaseForStaleConnection()
        }
    }

    /// After a long background period, `ApplicationMusicPlayer`'s connection
    /// to the system media-player process can go stale — confirmed
    /// on-device: a bare resume there (`togglePlayPause()`) hung the whole
    /// app requiring a force-quit. Marks the player as needing a fresh load
    /// so the next resume routes through the already timeout-guarded
    /// `playCurrent()` (re-resolves + re-queues from scratch) instead of a
    /// bare resume call — reuses `togglePlayPause()`'s existing
    /// `!playerLoaded` check, no new branching needed there.
    ///
    /// Trade-off: a resume after a long background period restarts the
    /// current track from the beginning rather than its paused position —
    /// judged worth it against the alternative (a frozen app).
    private func observeScenePhaseForStaleConnection() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.backgroundedAt = Date() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let backgroundedAt = self.backgroundedAt else { return }
                self.backgroundedAt = nil
                guard Date().timeIntervalSince(backgroundedAt) > Self.staleAfterBackgroundInterval else { return }
                self.playerLoaded = false
            }
        }
    }

    // MARK: - Public playback API

    /// Play a track. Resolves the input `song` to an Apple Music catalog
    /// entry and then takes one of two playback paths:
    ///
    /// 1. **Subscriber path** — full streamed playback via
    ///    `ApplicationMusicPlayer.shared`. iOS handles Control Center,
    ///    lock-screen metadata, audio session.
    /// 2. **Preview path (fallback)** — 30-second `previewAssets` URL via
    ///    `AVPlayer`. Triggered automatically when full playback throws
    ///    (the typical cause is no active Apple Music subscription).
    ///    `MPNowPlayingInfoCenter` is populated manually because MusicKit
    ///    only populates it for `ApplicationMusicPlayer`.
    ///
    /// Sets `trackUnavailable = true` only when **both** paths fail (e.g.
    /// the resolver couldn't find the track at all, or there are no preview
    /// assets). The PlaybackErrorAlert ViewModifier picks that up and shows
    /// a "Subscribe to Apple Music" sheet.
    func play(_ song: NodalongKit.Song) async {
        // Tap-to-play resets the queue to just this track (explicit-queue model)
        // — leaving any active party's "queue is the party" model.
        isPartyDriven = false
        queue = [QueueItem(song: song)]
        currentIndex = 0
        persistQueue()
        await playCurrent()
    }

    /// Plays a track within an ordered list (album, playlist, artist Top Songs):
    /// loads the whole list as the queue with `index` as the current entry, so
    /// ⏮ reaches earlier tracks and later tracks auto-advance.
    ///
    /// Used by list contexts where the user expects the rest of the list to keep
    /// playing. Single-track surfaces (Feed, profile carousels, Near Me, flat
    /// search results) keep calling `play(_ song:)`, which resets to one track.
    func play(_ songs: [NodalongKit.Song], startingAt index: Int) async {
        guard songs.indices.contains(index) else { return }
        // Explicit list load resets the party-driven flag; the party bootstrap
        // re-establishes it by calling `reconcileQueue` immediately after.
        isPartyDriven = false
        queue = songs.map { QueueItem(song: $0) }
        currentIndex = index
        persistQueue()
        await playCurrent()
    }

    private struct PlaybackTimeoutError: Error {}

    /// Races `operation` against a plain timer — if `operation` hasn't
    /// completed within `seconds`, throws instead of hanging forever.
    /// Doesn't force-cancel a genuinely stuck system call (MusicKit's XPC
    /// layer doesn't reliably respond to Task cancellation), it just lets
    /// our own code stop waiting and treat it as a failure — the abandoned
    /// call is harmless if it eventually completes on its own. Used to
    /// guard `ApplicationMusicPlayer.play()`, which has been observed to
    /// hang indefinitely (rather than throw) when its XPC connection to the
    /// system media-player process is stale (e.g. after the app has been
    /// idle for days) — without this, a hang left `isLoadingTrack` stuck
    /// `true` and the UI showing "playing" with no sound and no error.
    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw PlaybackTimeoutError()
            }
            guard let result = try await group.next() else { throw PlaybackTimeoutError() }
            group.cancelAll()
            return result
        }
    }

    /// Plays `queue[currentIndex]`. Shared by tap-to-play, auto-advance, skip,
    /// and jump-to-item. Resolves the song to an Apple Music catalog entry, then
    /// takes the subscriber (`ApplicationMusicPlayer`) path, falling back to a
    /// 30-second `AVPlayer` preview.
    private func playCurrent(attempt: Int = 1) async {
        if activeService == .spotify, spotifyService != nil {
            await playCurrentViaSpotify(attempt: attempt)
            return
        }
        guard let song = currentItem?.song else { return }
        isLoadingTrack = true
        defer { isLoadingTrack = false }
        stopPreviewPlayer()
        trackUnavailable = false
        spotifyPlaybackError = nil
        lastPlaybackErrorDetail = nil

        nowPlaying = NowPlayingTrack(
            title:     song.title,
            artist:    song.artist,
            album:     song.album,
            artwork:   song.artwork,
            uri:       song.uri,
            catalogId: song.catalogId,
            isrc:      song.isrc
        )
        progress  = 0
        isPlaying = true
        lastExplicitPauseAt = nil
        // A pending pause from a PREVIOUS track's transition must never leak
        // forward onto this one, which may have started for an unrelated
        // reason (e.g. the user tapping a different song directly).
        pendingPauseIntent = false
        // Same reasoning for the end-of-track detector's reference point —
        // a stale reading from the previous track must not leak forward.
        lastKnownElapsedWhilePlaying = 0
        // `player.queue = [musicKitSong]` below wipes any previously mirrored
        // native neighbors, so our bookkeeping of what's mirrored must reset
        // too — `syncNativeQueueNeighbors()` will re-seed a fresh window.
        mirroredPreviousItemId = nil
        mirroredNextItemId = nil

        let musicKitSong: MusicKit.Song
        do {
            musicKitSong = try await resolveUsingCache(song)
        } catch {
            // Couldn't even find the track in the Apple Music catalog — skip it
            // and try the next queued track rather than halting the session.
            debugLog("[Nodalong.Player] resolve(\(song.title) by \(song.artist)) failed: \(error)")
            isPlaying = false
            lastPlaybackErrorDetail = "\(error)"
            await skipUnplayableAndAdvance(failedTitle: song.title, attempt: attempt)
            return
        }

        do {
            // First try: full subscriber playback. MusicKit handles
            // everything (audio session, lock screen, Control Center).
            isPreviewMode      = false
            currentDuration    = musicKitSong.duration ?? 210
            lastPlaybackStatus = .playing  // arm the edge detector for this track
            let player = ApplicationMusicPlayer.shared
            player.queue = [musicKitSong]
            try await withTimeout(seconds: 8) { try await player.play() }
            // Reset progress after play() resolves so that any stale
            // playbackTime from the previous track doesn't show briefly as
            // a wrong thumb position on the first timer tick.
            progress = 0
            playerLoaded = true
            // A remote pause that arrived while THIS track was still loading
            // (see `pendingPauseIntent`'s doc comment) couldn't be safely
            // applied at the time — the player didn't have this track queued
            // yet. Apply it now, immediately, so the published state never
            // diverges from the real audio: this track just started, but the
            // user asked to pause before it did.
            if pendingPauseIntent {
                pendingPauseIntent = false
                player.pause()
                isPlaying = false
                lastPlaybackStatus = .paused
                lastExplicitPauseAt = Date()
            }
            startProgressTimer()
            prefetchNext()   // warm the next track's resolution while this plays
            await syncNativeQueueNeighbors()
        } catch {
            // Fall back to preview playback. Most common cause:
            // ApplicationMusicPlayer throws because the user isn't
            // subscribed. Logged so the user can confirm the cause via the
            // Xcode console when debugging.
            debugLog("[Nodalong.Player] ApplicationMusicPlayer.play(\(musicKitSong.title)) failed: \(error)")
            do {
                try await playPreview(of: musicKitSong)
            } catch {
                // No preview assets either — skip this track and try the next.
                debugLog("[Nodalong.Player] playPreview(\(musicKitSong.title)) failed: \(error)")
                isPlaying = false
                lastPlaybackErrorDetail = "\(error)"
                await skipUnplayableAndAdvance(failedTitle: musicKitSong.title, attempt: attempt)
            }
        }
    }

    /// Spotify branch of `playCurrent()` — resolves + plays via
    /// `SpotifyMusicService`'s remote-control primitives (an already-active
    /// Spotify Connect device, not in-process audio). No `MPNowPlayingInfoCenter`
    /// write and no `activateAudioSessionIfNeeded()` call here: the real
    /// Spotify app is the one actually outputting audio, so it — not
    /// Nodalong — owns the OS Control Center/lock-screen surface under this
    /// architecture (see the Stage B plan's Context section).
    ///
    /// **Tried claiming the surface anyway on 2026-07-14, per explicit user
    /// request** (Control Center Next was routing to the real Spotify app
    /// instead of Nodalong's queue) — reverted the same day after an
    /// on-device test showed it actively breaks Spotify playback, not just
    /// "doesn't help": activating Nodalong's own `.playback` `AVAudioSession`
    /// while the real Spotify app already had an active session sent it an
    /// interruption, which paused Spotify's real playback and dropped it off
    /// Spotify's own active-device list — Control Center Next then did
    /// nothing (nothing was playing to advance), and reopening the app hit
    /// `SpotifyServiceError.noActiveDevice` ("Nothing to play — open Spotify
    /// on a device"). Do not re-attempt this without first confirming iOS
    /// has some way to claim a Now Playing session WITHOUT taking over the
    /// active audio route from whichever app/device is genuinely outputting
    /// sound — nothing found so far suggests one exists for this
    /// architecture (pure Web API remote control, not an embedded SDK with
    /// its own in-process audio).
    private func playCurrentViaSpotify(attempt: Int = 1) async {
        guard let song = currentItem?.song, let spotifyService else { return }
        isLoadingTrack = true
        defer { isLoadingTrack = false }
        stopPreviewPlayer()
        spotifyPollTimer?.invalidate()
        spotifyPollTimer = nil
        trackUnavailable = false
        spotifyPlaybackError = nil
        awaitingSpotifyDeviceRetry = false
        lastPlaybackErrorDetail = nil
        isPreviewMode = false

        nowPlaying = NowPlayingTrack(
            title:     song.title,
            artist:    song.artist,
            album:     song.album,
            artwork:   song.artwork,
            uri:       song.uri,
            catalogId: song.catalogId,
            isrc:      song.isrc
        )
        progress  = 0
        isPlaying = true
        // Seed a real duration synchronously (song.duration is stored in ms)
        // so the interpolated scrubber (startProgressTimer's Spotify branch)
        // has something real before the first 3s poll returns.
        if let ms = song.duration, ms > 0 {
            currentDuration = TimeInterval(ms) / 1000
        }

        do {
            spotifyPlayingTrackUri = try await spotifyService.playReturningResolvedUri(song)
            playerLoaded = true
            startSpotifyPollTimer()
            startProgressTimer()
            syncSpotifyNativeQueue()
        } catch let error as SpotifyServiceError where isNoActiveDevice(error) {
            // Every remaining track has the same problem — don't skip-and-advance
            // through the whole queue burning the same error each time.
            debugLog("[Nodalong.Player] Spotify play(\(song.title)) failed: no active device")
            isPlaying = false
            spotifyPlaybackError = error.errorDescription
            awaitingSpotifyDeviceRetry = true
            stopBackends()
        } catch {
            debugLog("[Nodalong.Player] Spotify play(\(song.title)) failed: \(error)")
            isPlaying = false
            lastPlaybackErrorDetail = (error as? SpotifyServiceError)?.errorDescription ?? "\(error)"
            await skipUnplayableAndAdvance(failedTitle: song.title, attempt: attempt)
        }
    }

    private func isNoActiveDevice(_ error: SpotifyServiceError) -> Bool {
        if case .noActiveDevice = error { return true }
        return false
    }

    /// Retries the currently-loaded track once, if the last Spotify play
    /// attempt failed with `.noActiveDevice`. Called from `ContentView`'s
    /// existing foreground-return handler — matches the confirmed on-device
    /// recovery pattern (fail → open the real Spotify app → return to
    /// Nodalong → it just works) without requiring a second manual tap on
    /// play. Self-limiting: consumes `awaitingSpotifyDeviceRetry` up front,
    /// so a foreground return with nothing pending is a no-op, and a retry
    /// that fails again re-arms the flag via the same catch branch that set
    /// it the first time (see `playCurrentViaSpotify`) rather than looping
    /// here.
    func retryAfterSpotifyDeviceRecovery() async {
        guard awaitingSpotifyDeviceRetry, activeService == .spotify, currentItem != nil else { return }
        awaitingSpotifyDeviceRetry = false
        await playCurrent()
    }

    /// Polls `GET /me/player` every ~3s while Spotify is active and playing —
    /// coarser than the MusicKit poll (0.1–0.5s), since Spotify's Web API has
    /// no finer-grained push mechanism. Detects end-of-track when playback
    /// has stopped with progress at/near the track's duration, routing into
    /// the same `handleTrackEnd()` advance-or-stop path the MusicKit poll uses.
    private func startSpotifyPollTimer() {
        spotifyPollTimer?.invalidate()
        spotifyPollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.pollSpotifyPlaybackState() }
        }
    }

    private func pollSpotifyPlaybackState() async {
        guard isPlaying, activeService == .spotify, !isLoadingTrack, let spotifyService else { return }
        guard let state = try? await spotifyService.fetchPlaybackState() else { return }

        // Detect Spotify's native Next being used out-of-band (Control
        // Center, headphones, or the real Spotify app) — only detectable
        // for the one track we ourselves pre-queued via
        // `syncSpotifyNativeQueue()` (see its doc comment for why matching
        // by raw `Song.uri` against `queue` isn't reliable in general).
        if let trackUri = state.trackUri,
           trackUri != spotifyPlayingTrackUri,
           trackUri == spotifyQueuedNextUri,
           let matchedId = spotifyQueuedNextItemId,
           let matchedIndex = queue.firstIndex(where: { $0.id == matchedId }) {
            currentIndex = matchedIndex
            spotifyPlayingTrackUri = trackUri
            let song = queue[matchedIndex].song
            nowPlaying = NowPlayingTrack(
                title:     song.title,
                artist:    song.artist,
                album:     song.album,
                artwork:   song.artwork,
                uri:       song.uri,
                catalogId: song.catalogId,
                isrc:      song.isrc
            )
            persistQueue()
            syncSpotifyNativeQueue()   // pre-queue whatever's next now
        }

        if state.durationMs > 0 {
            currentDuration = TimeInterval(state.durationMs) / 1000
            progress = min(1.0, Double(state.progressMs) / Double(state.durationMs))
        }
        guard !state.isPlaying else { return }
        let nearEnd = state.durationMs > 0 && state.progressMs >= state.durationMs - 1500
        if nearEnd {
            spotifyPollTimer?.invalidate()
            spotifyPollTimer = nil
            await handleTrackEnd()
        } else {
            // Paused externally (e.g. the user paused in the real Spotify
            // app) — just reflect the state, don't advance.
            isPlaying = false
        }
    }

    /// Best-effort: pushes `upNext.first` into Spotify's own native queue
    /// (`SpotifyMusicService.addToNativeQueue`) so Control Center/headphone
    /// Next plays the track Nodalong actually expects next. Spotify's Web
    /// API only supports appending — no reorder/remove/clear — so this can
    /// only ever mirror the single immediate-next track, not the whole
    /// queue (see `addToNativeQueue`'s doc comment). No-ops outside Spotify,
    /// when there's nothing next, or when the next track hasn't changed
    /// since the last call. Safe to call unconditionally from every queue
    /// mutation (mirrors `persistQueue()`'s call sites) — cheap when it has
    /// nothing new to do.
    private func syncSpotifyNativeQueue() {
        guard activeService == .spotify, let spotifyService else { return }
        guard let next = upNext.first else {
            spotifyQueuedNextUri = nil
            spotifyQueuedNextItemId = nil
            return
        }
        guard next.id != spotifyQueuedNextItemId else { return }
        Task {
            do {
                let uri = try await spotifyService.resolveTrackUri(for: next.song)
                try await spotifyService.addToNativeQueue(uri: uri)
                spotifyQueuedNextUri = uri
                spotifyQueuedNextItemId = next.id
            } catch {
                debugLog("[Nodalong.Player] syncSpotifyNativeQueue failed: \(error)")
            }
        }
    }

    /// Matches a native MusicKit queue entry's underlying song against one of
    /// our own `Song`s. A queue entry's ID never matches a `Song`'s own ID
    /// (MusicKit's own documented behavior, to allow the same track to
    /// appear more than once in a queue), so this compares by ISRC first,
    /// falling back to title+artist — the same cascade `resolve(_:)` already
    /// uses elsewhere in this file.
    private func matches(_ entry: MusicKit.ApplicationMusicPlayer.Queue.Entry?, _ song: NodalongKit.Song) -> Bool {
        guard case .song(let entrySong) = entry?.item else { return false }
        if let isrc = song.isrc, let entryIsrc = entrySong.isrc, !isrc.isEmpty {
            return isrc == entryIsrc
        }
        return entrySong.title == song.title && entrySong.artistName == song.artist
    }

    /// Mirrors the immediate previous/next tracks around the current position
    /// into MusicKit's own native queue, so Control Center's next/previous —
    /// confirmed via on-device diagnostic logging to bypass our own
    /// registered `MPRemoteCommandCenter` targets entirely and be handled by
    /// MusicKit internally — have real entries of ours to move between,
    /// instead of just restarting the current track (MusicKit's own fallback
    /// when there's nothing else in its native queue). Cheap no-op when
    /// neither neighbor has changed since the last call. Safe to call
    /// unconditionally from every queue mutation.
    private func syncNativeQueueNeighbors() async {
        guard activeService != .spotify, !isPreviewMode, playerLoaded else { return }
        let player = ApplicationMusicPlayer.shared

        let nextItem = upNext.first
        if nextItem?.id != mirroredNextItemId {
            if let nextItem {
                do {
                    let musicKitSong = try await resolve(nextItem.song)
                    try await player.queue.insert(musicKitSong, position: .afterCurrentEntry)
                    mirroredNextItemId = nextItem.id
                } catch {
                    debugLog("[Nodalong.Player] syncNativeQueueNeighbors (next) failed: \(error)")
                }
            } else {
                mirroredNextItemId = nil
            }
        }

        // PREVIOUS-neighbour mirroring REMOVED — it was the cause of the
        // playback freeze.
        //
        // It could not use MusicKit's sanctioned insertion API the way the
        // next-neighbour branch above does, because
        // `MusicPlayer.Queue.EntryInsertionPosition` only offers
        // `.afterCurrentEntry` and `.tail` — there is no "before current".
        // The workaround was to reach into `player.queue.entries` and mutate
        // that array directly, which corrupts the queue's internal state:
        // subsequent player access then blocks forever in
        // `-[MPMusicPlayerController playbackState]` →
        // `_establishConnectionIfNeeded` → a synchronous XPC wait on
        // `mediaplayerd` that never returns (confirmed by a main-thread
        // backtrace captured during a real freeze). Because that call is
        // synchronous and on the main thread, the whole app locks up with no
        // recovery — the reported "no sound, nothing responds" symptom.
        //
        // Diagnostically confirmed: freezes occur only with a multi-item
        // queue (album / Top Charts), never with a single-item queue (Feed
        // taps, where nothing is mirrored); and disabling mirroring entirely
        // eliminated them. Only this branch does raw `entries` mutation, so
        // it is the half that goes.
        //
        // Cost: Control Center's PREVIOUS restarts the current track instead
        // of stepping back. Control Center's NEXT still advances properly
        // (the branch above uses the real API and is retained). This also
        // matches Apple Music's own behaviour, where previous restarts the
        // current track unless you're within the first few seconds.
        mirroredPreviousItemId = nil
    }

    // MARK: - Queue operations

    /// Append a track to the end of the queue. If nothing is loaded yet, starts
    /// playing it immediately. Fires haptic feedback and shows a brief toast.
    func addToQueue(_ song: NodalongKit.Song) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        queue.append(QueueItem(song: song))
        if nowPlaying == nil {
            currentIndex = queue.count - 1
            Task { await playCurrent() }
        }
        persistQueue()
        syncSpotifyNativeQueue()
        Task { await syncNativeQueueNeighbors() }
        // Pre-resolve the next track while the current one plays so a later skip
        // (especially a backgrounded lock-screen skip) starts audio instantly and
        // doesn't stall on a network resolve.
        prefetchNext()
        flashQueueToast(song.title)
    }

    private func flashQueueToast(_ title: String, kind: QueueToastKind = .added) {
        queueToast = title
        queueToastKind = kind
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            queueToast = nil
        }
    }

    /// Advance to the next queued track, or stop (keeping the now-playing
    /// surface) when the queue is exhausted.
    func skipToNext() async {
        guard hasNext else {
            isPlaying = false
            stopBackends()
            return
        }
        currentIndex += 1
        lastPlaybackStatus = .playing  // re-arm before playCurrent arms it again
        persistQueue()
        await playCurrent()
    }

    /// Restart the current track if more than 3 s in (or there's nothing before
    /// it), otherwise step back one entry — matches Apple Music.
    func skipToPrevious() async {
        if progress * currentDuration > 3 || !hasPrevious {
            seek(to: 0)
            return
        }
        currentIndex -= 1
        lastPlaybackStatus = .playing
        persistQueue()
        await playCurrent()
    }

    /// Jump straight to a queue entry (tapping a row in Up Next).
    func playQueueItem(_ item: QueueItem) async {
        guard let idx = queue.firstIndex(of: item) else { return }
        currentIndex = idx
        lastPlaybackStatus = .playing
        persistQueue()
        await playCurrent()
    }

    /// Reorder within the Up Next region. Offsets are relative to `upNext`.
    /// Reimplements `move(fromOffsets:toOffset:)` with plain `Array` ops so the
    /// VM needn't import SwiftUI.
    func moveUpNext(fromOffsets source: IndexSet, toOffset destination: Int) {
        let base = currentIndex + 1
        guard base <= queue.count else { return }
        var up = Array(queue[base...])
        let moving = source.sorted().map { up[$0] }
        for i in source.sorted(by: >) { up.remove(at: i) }
        let insertAt = destination - source.filter { $0 < destination }.count
        up.insert(contentsOf: moving, at: min(max(insertAt, 0), up.count))
        queue.replaceSubrange(base..., with: up)
        persistQueue()
        syncSpotifyNativeQueue()
        Task { await syncNativeQueueNeighbors() }
    }

    /// Remove entries from the Up Next region. Offsets are relative to `upNext`.
    func removeUpNext(atOffsets offsets: IndexSet) {
        let base = currentIndex + 1
        for offset in offsets.sorted(by: >) {
            let absolute = base + offset
            if queue.indices.contains(absolute) { queue.remove(at: absolute) }
        }
        persistQueue()
        syncSpotifyNativeQueue()
        Task { await syncNativeQueueNeighbors() }
    }

    /// Fired when the current track finishes — advances, or stops at the end of
    /// the queue. Guarded against the progress timer re-firing it.
    private func handleTrackEnd() async {
        guard !isAdvancing else { return }
        // A sync-follower has no queue of its own. In single-song tune-in the
        // session ends when the song does; a station just idles here until the
        // broadcaster's next-track update arrives (which loads it fresh).
        if let ctx = followContext {
            if ctx.mode == .singleTrack {
                stopFollowing()
            } else {
                isPlaying = false
                progress  = 1.0
                stopBackends()
            }
            return
        }
        isAdvancing = true
        defer { isAdvancing = false }
        if hasNext {
            currentIndex += 1
            persistQueue()
            await playCurrent()
        } else {
            isPlaying = false
            progress  = 1.0
            stopBackends()
        }
    }

    // MARK: - Sync follow engine (radio)

    /// Enters follow mode. The device becomes a pure receiver (transport hidden);
    /// the actual track load happens on the first `applyFollowTimeline`.
    func beginFollowing(label: String, mode: FollowMode) {
        followContext = FollowContext(label: label, mode: mode, catalogId: "")
    }

    /// Applies a broadcaster timeline update. `targetPositionMs` is the position
    /// already extrapolated to *now* by the caller (which owns `ServerClock`), so
    /// this stays free of any clock/RTDB concern. `song` is the resolved playable
    /// for `catalogId` (nil if the caller couldn't resolve it yet — we retry on
    /// the next update rather than committing to an unloadable track).
    func applyFollowTimeline(catalogId: String, targetPositionMs: Int, isPlaying: Bool, song: NodalongKit.Song?) async {
        guard let ctx = followContext else { return }

        if catalogId != ctx.catalogId {
            // Broadcaster changed track — or this is the first (seed) update.
            if ctx.mode == .singleTrack && !ctx.catalogId.isEmpty {
                stopFollowing()   // their song ended/changed → single-song tune-in is over
                return
            }
            guard let song else { return }   // not resolved yet; ctx.catalogId unchanged, retry next update
            followContext?.catalogId = catalogId
            await loadFollowTrack(song, seekMs: targetPositionMs, isPlaying: isPlaying)
        } else {
            // Same track — correct drift and mirror the broadcaster's play/pause.
            if isPlaying {
                if abs(currentPositionMs - targetPositionMs) > Self.followDriftThresholdMs {
                    seekToMs(targetPositionMs)
                }
                if !self.isPlaying { await resumeFollow() }
            } else if self.isPlaying {
                pauseFollow()
            }
        }
    }

    /// Leaves follow mode and stops playback (returns the player to idle — it does
    /// not resume whatever was playing solo before).
    func stopFollowing() {
        guard followContext != nil else { return }
        followContext = nil
        stopBackends()          // pauses the active backend + kills the timers
        isPlaying    = false
        progress     = 0
        nowPlaying   = nil
        queue        = []
        currentIndex = 0
        playerLoaded = false
        isPreviewMode = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Loads a single track for follow mode and aligns to `seekMs`. Reuses the
    /// full `playCurrent()` resolve/play path (subscriber → preview fallback);
    /// the `followContext` guard in `handleTrackEnd` keeps its queue machinery
    /// from auto-advancing.
    private func loadFollowTrack(_ song: NodalongKit.Song, seekMs: Int, isPlaying: Bool) async {
        isPartyDriven = false
        queue = [QueueItem(song: song)]
        currentIndex = 0
        await playCurrent()
        guard followContext != nil else { return }   // user left mid-load
        seekToMs(seekMs)
        if !isPlaying { pauseFollow() }
    }

    private func pauseFollow() {
        guard isPlaying else { return }
        if isPreviewMode { previewPlayer?.pause() } else { ApplicationMusicPlayer.shared.pause() }
        isPlaying = false
        lastPlaybackStatus = .paused
    }

    private func resumeFollow() async {
        guard !isPlaying else { return }
        if isPreviewMode {
            previewPlayer?.play()
        } else {
            try? await withTimeout(seconds: 8) { try await ApplicationMusicPlayer.shared.play() }
        }
        isPlaying = true
        lastPlaybackStatus = .playing
    }

    // MARK: - Party queue reconcile

    /// Reconciles the local queue's UPCOMING portion to match `songs` (the full
    /// listening-party queue, in order), preserving the CURRENTLY-PLAYING track
    /// untouched. Keeps host playback in lockstep with the party's live Firestore
    /// queue (adds, removes, reorders) without interrupting the current song.
    ///
    /// Anchors on `song.id` — for party-sourced songs that's the stable Firestore
    /// queue-doc id (`Song.from(partyQueueTrack:)` sets `id` to the doc id), so a
    /// track queued twice (same catalogId, different doc ids) anchors on the
    /// correct occurrence. Only ever called with party songs (host-side).
    func reconcileQueue(with songs: [NodalongKit.Song]) {
        guard let current = currentItem else { return }          // nothing loaded → no-op
        guard !isAdvancing else { pendingReconcile = songs; return } // defer during a skip/retry chain
        guard let anchor = songs.firstIndex(where: { $0.id == current.song.id }) else {
            // Currently-playing track isn't in the party queue anymore — leave
            // local playback alone; a later snapshot may restore alignment.
            return
        }
        isPartyDriven = true   // reconcile owns the queue now (set even on a no-op pass)
        let newUpNext = Array(songs[(anchor + 1)...])
        // Short-circuit when the upcoming order is unchanged — avoids @Published
        // churn on every played-flag flip / track boundary.
        if newUpNext.map(\.id) == upNext.map(\.song.id) { return }
        queue = [current] + newUpNext.map { QueueItem(song: $0) }
        currentIndex = 0
        persistQueue()
        syncSpotifyNativeQueue()
        Task { await syncNativeQueueNeighbors() }
        prefetchNext()
    }

    /// Applies a party reconcile that arrived while a skip/retry chain was in
    /// flight (stashed by `reconcileQueue`).
    private func drainPendingReconcile() {
        guard let songs = pendingReconcile else { return }
        pendingReconcile = nil
        reconcileQueue(with: songs)
    }

    /// Called when `playCurrent()` can't resolve or play the current item.
    /// Advances past the broken track and retries rather than halting the whole
    /// session on one bad song. Bounded by `attempt < queue.count` so a fully
    /// unplayable queue terminates (falling back to `trackUnavailable`) instead
    /// of looping. Reuses `isAdvancing` — the same guard `handleTrackEnd()` uses
    /// — so a timer-driven end-of-track edge can't race a skip.
    private func skipUnplayableAndAdvance(failedTitle: String, attempt: Int) async {
        guard !isAdvancing else { return }
        isAdvancing = true
        flashQueueToast(failedTitle, kind: .skipped)
        guard attempt < queue.count, hasNext else {
            // Tried every entry (or nothing left) — give up, matching today's
            // terminal behavior.
            isPlaying = false
            trackUnavailable = true
            stopBackends()
            isAdvancing = false
            drainPendingReconcile()
            return
        }
        currentIndex += 1
        persistQueue()
        isAdvancing = false        // release before recursing so a further failure can re-enter
        drainPendingReconcile()    // apply any party update that arrived mid-chain
        await playCurrent(attempt: attempt + 1)
    }

    /// Pause whichever backend is active and stop the progress timer, without
    /// clearing the now-playing surface.
    private func stopBackends() {
        progressTimer?.invalidate()
        progressTimer = nil
        spotifyPollTimer?.invalidate()
        spotifyPollTimer = nil
        if activeService == .spotify {
            Task { [weak spotifyService] in try? await spotifyService?.pause() }
        } else if isPreviewMode {
            previewPlayer?.pause()
        } else {
            ApplicationMusicPlayer.shared.pause()
        }
    }

    /// Plays the first available 30-second preview asset via `AVPlayer`.
    /// Used as a fallback when `ApplicationMusicPlayer` can't stream the
    /// full track (almost always: no Apple Music subscription).
    ///
    /// Preview URLs come from `Song.previewAssets`. We try the progressive
    /// `url` first, then `hlsURL` as a backup. Both are 30-second AAC clips
    /// served by Apple's CDN; AVPlayer handles either.
    ///
    /// Unlike full playback, the system doesn't populate
    /// `MPNowPlayingInfoCenter` for `AVPlayer` — we do it manually here so
    /// the lock screen still shows the right track.
    private func playPreview(of musicKitSong: MusicKit.Song) async throws {
        guard let previewURL = musicKitSong.previewAssets?.first?.url
                            ?? musicKitSong.previewAssets?.first?.hlsURL
        else {
            throw AppleMusicServiceError.trackNotFound
        }
        // The AVPlayer path needs an active audio session; activate it now
        // (in the foreground, at real playback) rather than at launch.
        activateAudioSessionIfNeeded()
        isPreviewMode   = true
        currentDuration = 30
        let item   = AVPlayerItem(url: previewURL)
        let player = AVPlayer(playerItem: item)
        previewPlayer = player
        // AVPlayer DOES deliver an end-of-item notification — use it to advance
        // the queue precisely when the 30s preview finishes.
        previewEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.handleTrackEnd() }
        }
        player.play()
        playerLoaded = true
        startProgressTimer()
        prefetchNext()   // warm the next track's resolution while this plays
        if let track = nowPlaying {
            updateNowPlayingInfo(track, duration: currentDuration)
        }
    }

    /// Pause/resume the current track. Routes to the right player based on
    /// which path is active.
    func togglePlayPause() async {
        // First play after a cold-launch restore: nothing is loaded into the
        // player yet, so resolve + enqueue the persisted track via playCurrent()
        // rather than calling play() on an empty player queue (which no-ops).
        if !isPlaying, !playerLoaded, currentItem != nil {
            await playCurrent()
            return
        }

        if activeService == .spotify, let spotifyService {
            do {
                if isPlaying {
                    try await spotifyService.pause()
                    isPlaying = false
                } else {
                    try await spotifyService.resume()
                    isPlaying = true
                }
            } catch {
                debugLog("[Nodalong.Player] Spotify togglePlayPause failed: \(error)")
            }
            return
        }

        if isPreviewMode {
            if isPlaying {
                previewPlayer?.pause()
            } else {
                previewPlayer?.play()
            }
            isPlaying.toggle()
            updateNowPlayingPlaybackState()
        } else {
            let player = ApplicationMusicPlayer.shared
            if isPlaying {
                if isLoadingTrack {
                    // A track transition is already in flight (e.g. the
                    // current track just naturally ended and the auto-advance
                    // to the next queued track is mid-resolve) — the player
                    // may not have the next track loaded yet, so pausing here
                    // would be a no-op that `playCurrent()`'s upcoming
                    // `player.play()` call would silently override moments
                    // later, leaving `isPlaying == false` published while
                    // real audio keeps going. Defer instead — `playCurrent()`
                    // applies this the instant the new track actually starts.
                    // See `pendingPauseIntent`'s doc comment.
                    pendingPauseIntent = true
                } else {
                    player.pause()
                    isPlaying = false
                    // Disarm the edge detector so the .playing→.paused transition
                    // from this explicit pause doesn't trigger an advance.
                    lastPlaybackStatus = .paused
                    lastExplicitPauseAt = Date()
                }
            } else {
                do {
                    try await withTimeout(seconds: 8) { try await player.play() }
                    isPlaying = true
                    lastPlaybackStatus = .playing
                    lastExplicitPauseAt = nil
                } catch {
                    // A stale/invalidated ApplicationMusicPlayer connection
                    // (e.g. after the app sat backgrounded for a long time)
                    // can make a bare resume hang or fail even though the
                    // track is still loaded — re-resolving and re-queuing
                    // from scratch via `playCurrent()` gives it a real
                    // second chance instead of silently staying paused.
                    debugLog("[Nodalong.Player] togglePlayPause resume failed: \(error)")
                    await playCurrent()
                }
            }
        }
    }


    /// Stop playback entirely and clear the now-playing surface.
    func dismiss() {
        nowPlaying = nil
        isPlaying  = false
        isExpanded = false
        progress   = 0
        queue        = []
        currentIndex = 0
        playerLoaded = false
        isPartyDriven = false
        UserDefaults.standard.removeObject(forKey: queueKey)
        stopPreviewPlayer()
        progressTimer?.invalidate()
        progressTimer = nil
        spotifyPollTimer?.invalidate()
        spotifyPollTimer = nil
        spotifyPlaybackError = nil
        if activeService == .spotify {
            Task { [weak spotifyService] in try? await spotifyService?.pause() }
        } else if !isPreviewMode {
            ApplicationMusicPlayer.shared.pause()
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        isPreviewMode = false
    }

    // MARK: - Resolution

    /// Resolves `song`, using the warm `prefetchedNext` cache when it matches so
    /// an auto-advance skips the network round-trip. Falls back to a live
    /// `resolve` on a cache miss.
    private func resolveUsingCache(_ song: NodalongKit.Song) async throws -> MusicKit.Song {
        if let cached = prefetchedNext, cached.uri == song.uri {
            prefetchedNext = nil
            return cached.song
        }
        return try await resolve(song)
    }

    /// Resolves the next queued track in the background and stores it in
    /// `prefetchedNext`, so when the current track ends the advance is instant
    /// (no network resolve). No-op when the next track is already cached or the
    /// queue has no upcoming entry.
    private func prefetchNext() {
        guard let next = upNext.first?.song else {
            prefetchedNext = nil
            return
        }
        guard prefetchedNext?.uri != next.uri else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let resolved = try? await self.resolve(next) else { return }
            // Only keep it if `next` is still the upcoming track (the user may
            // have reordered/skipped while we resolved).
            if self.upNext.first?.song.uri == next.uri {
                self.prefetchedNext = (next.uri, resolved)
            }
        }
    }

    /// Maps a generic `Song` to a playable MusicKit Song. Tries native Apple
    /// Music ID (when `sourceService == .appleMusic`) first, then ISRC, then
    /// a title + artist text search.
    private func resolve(_ song: NodalongKit.Song) async throws -> MusicKit.Song {
        // 1. Direct id lookup — only for *catalog* IDs. Library/relationship IDs
        // (the `i.`-prefixed ones MusicKit returns from library + recently-played
        // syncs) are NOT catalog IDs, so a catalog lookup always 404s on them.
        // Skip straight to the ISRC / text-search fallback for those, which
        // resolves cleanly without the wasted round-trip + console noise.
        if song.sourceService == .appleMusic, !song.uri.isEmpty, !song.uri.hasPrefix("i.") {
            do {
                let req = MusicCatalogResourceRequest<MusicKit.Song>(
                    matching: \.id, equalTo: MusicItemID(song.uri)
                )
                if let hit = try await req.response().items.first {
                    debugLog("[Nodalong.Resolve] resolved '\(song.title)' via direct id (\(song.uri))")
                    return hit
                }
            } catch {
                debugLog("[Nodalong.Resolve] id lookup failed (\(song.uri)): \(error)")
            }
        }

        // 2. ISRC bridge — works across services. An ISRC can match several
        // catalog releases (original album, deluxe reissue, "Greatest Hits"
        // compilation) — prefer whichever candidate's album matches
        // `song.album` (when known) instead of blindly taking the first
        // result. See `NodalongKit`'s `ReleaseMatching.swift`.
        if let isrc = song.isrc, !isrc.isEmpty {
            do {
                let req = MusicCatalogResourceRequest<MusicKit.Song>(
                    matching: \.isrc, equalTo: isrc
                )
                let items = try await req.response().items
                if !items.isEmpty {
                    let idx = bestReleaseIndex(albumNames: items.map { $0.albumTitle ?? "" }, expectedAlbum: song.album) ?? 0
                    debugLog("[Nodalong.Resolve] resolved '\(song.title)' via ISRC (\(isrc))")
                    return items[idx]
                }
            } catch {
                debugLog("[Nodalong.Resolve] ISRC lookup failed (\(isrc)): \(error)")
            }
        }

        // 3. Title + artist text search as last-resort — same release
        // preference applied across the top few matches.
        do {
            var search = MusicCatalogSearchRequest(
                term: "\(song.title) \(song.artist)",
                types: [MusicKit.Song.self]
            )
            search.limit = 5
            let songs = try await search.response().songs
            if !songs.isEmpty {
                let idx = bestReleaseIndex(albumNames: songs.map { $0.albumTitle ?? "" }, expectedAlbum: song.album) ?? 0
                debugLog("[Nodalong.Resolve] resolved '\(song.title)' via text search")
                return songs[idx]
            }
            debugLog("[Nodalong.Resolve] text search returned 0 results for '\(song.title) \(song.artist)'")
        } catch {
            debugLog("[Nodalong.Resolve] text search failed: \(error)")
        }

        throw AppleMusicServiceError.trackNotFound
    }

    // MARK: - Queue persistence

    /// Writes the current queue + index to UserDefaults so it survives
    /// app termination (iOS can kill background apps once audio stops).
    func persistQueue() {
        // Chokepoint for every queue / currentIndex mutation — keep the
        // lock-screen next/prev enablement in sync here.
        updateRemoteCommandState()
        guard let data = try? JSONEncoder().encode(queue) else { return }
        UserDefaults.standard.set(data, forKey: queueKey)
        UserDefaults.standard.set(currentIndex, forKey: queueIndexKey)
    }

    /// Restores a previously persisted queue on launch. Populates the
    /// now-playing surface (paused) so the mini player reappears — the
    /// user taps play to resume, matching Spotify / Apple Music behaviour.
    private func restoreQueue() {
        guard let data  = UserDefaults.standard.data(forKey: queueKey),
              let items = try? JSONDecoder().decode([QueueItem].self, from: data),
              !items.isEmpty else { return }
        queue        = items
        currentIndex = UserDefaults.standard.integer(forKey: queueIndexKey)
        updateRemoteCommandState()
        // Restored into our model only — nothing is loaded into the player yet,
        // so the first play must route through `playCurrent()`.
        playerLoaded = false
        if let song = currentItem?.song {
            nowPlaying = NowPlayingTrack(
                title:     song.title,
                artist:    song.artist,
                album:     song.album,
                artwork:   song.artwork,
                uri:       song.uri,
                catalogId: song.catalogId,
                isrc:      song.isrc
            )
        }
    }

    // MARK: - Preview-mode helpers

    private func stopPreviewPlayer() {
        if let obs = previewEndObserver {
            NotificationCenter.default.removeObserver(obs)
            previewEndObserver = nil
        }
        previewPlayer?.pause()
        previewPlayer = nil
        progressTimer?.invalidate()
        progressTimer = nil
    }

    /// Poll interval for the progress timer. 10 Hz while the full player (and
    /// its scrubber) is visible; a lazy 2 Hz when collapsed to the mini bar,
    /// which shows no progress UI. Even at 2 Hz the end-of-track edge detector
    /// still catches a finished track within half a second, so background
    /// auto-advance keeps working.
    private var progressInterval: TimeInterval { isExpanded ? 0.1 : 0.5 }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: progressInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isPreviewMode {
                    guard self.isPlaying else { return }
                    // Advance the bar by the poll interval; the true end is
                    // delivered by AVPlayerItemDidPlayToEndTime → handleTrackEnd().
                    self.progress = min(1.0, self.progress + self.progressInterval / self.currentDuration)
                } else if self.activeService == .spotify {
                    guard self.isPlaying else { return }
                    // Spotify's Web API has no push mechanism — the ~3s poll
                    // in `pollSpotifyPlaybackState()` is too coarse to drive a
                    // smooth scrubber directly (it visibly steps rather than
                    // sweeps). Interpolate locally between polls, same
                    // formula as the preview branch above; the poll keeps
                    // running independently to hard-resync `progress`/
                    // `currentDuration` from the server and to detect
                    // end-of-track / an externally-triggered pause.
                    if self.currentDuration > 0 {
                        self.progress = min(1.0, self.progress + self.progressInterval / self.currentDuration)
                    }
                } else {
                    // ApplicationMusicPlayer: read the actual position.
                    //
                    // Deliberately does NOT gate on `self.isPlaying` the way the
                    // branches above do. Confirmed on-device (both directions)
                    // that MusicKit's own Control Center integration can pause
                    // OR resume `ApplicationMusicPlayer` independent of our own
                    // code — e.g. tapping Control Center's "next" with nothing
                    // queued after the current track restarts it via an
                    // OS-level fallback we never see. If polling stopped the
                    // moment we believed we were paused, we'd have no way to
                    // ever notice such a resume, and would stay stuck showing
                    // "paused" while real audio played — exactly the mismatch
                    // reported on-device. Polling must always watch reality and
                    // reconcile in EITHER direction, not just react to our own
                    // pause detection.
                    let player = ApplicationMusicPlayer.shared
                    let status = player.state.playbackStatus

                    if status == .playing {
                        let elapsed = player.playbackTime
                        self.progress = self.currentDuration > 0
                            ? min(1.0, elapsed / self.currentDuration)
                            : 0
                        // Keep the last elapsed reading from a tick where the
                        // player was CONFIRMED still playing — used below to
                        // tell a genuine end-of-track apart from an early
                        // pause. See its doc comment.
                        self.lastKnownElapsedWhilePlaying = elapsed
                        if !self.isPlaying {
                            // Something resumed playback without going through
                            // our own code — reconcile rather than silently
                            // staying stuck "paused" while audio actually plays.
                            self.isPlaying = true
                        }
                    }

                    // MusicKit's own native next/previous (bypassing our
                    // registered `MPRemoteCommandCenter` targets entirely —
                    // confirmed via diagnostic logging) can move
                    // `currentEntry` to a mirrored neighbor with NO
                    // playbackStatus edge we'd otherwise notice (no stop,
                    // just a different track continuing to play). Compare
                    // against what we expect; a mismatch that matches one of
                    // our own mirrored previous/next entries means Control
                    // Center's next/previous actually had somewhere real to
                    // go — see `syncNativeQueueNeighbors()`.
                    if let currentEntry = player.queue.currentEntry,
                       let currentSong = self.currentItem?.song,
                       !self.matches(currentEntry, currentSong) {
                        if let next = self.upNext.first, self.matches(currentEntry, next.song) {
                            self.currentIndex += 1
                        } else if self.hasPrevious, self.matches(currentEntry, self.queue[self.currentIndex - 1].song) {
                            self.currentIndex -= 1
                        }
                        if let song = self.currentItem?.song {
                            self.nowPlaying = NowPlayingTrack(
                                title: song.title, artist: song.artist, album: song.album,
                                artwork: song.artwork, uri: song.uri, catalogId: song.catalogId,
                                isrc: song.isrc
                            )
                            self.currentDuration = currentEntry.item.flatMap {
                                if case .song(let s) = $0 { return s.duration }
                                return nil
                            } ?? self.currentDuration
                            self.persistQueue()
                            Task { await self.syncNativeQueueNeighbors() }
                        }
                    }

                    // MusicKit has no end-of-track callback for ApplicationMusicPlayer.
                    // Detect end-of-track via a status edge: .playing → .paused/.stopped.
                    // A progress threshold (>= 0.985) is NOT used because MusicKit resets
                    // playbackTime to 0 the moment the single-entry queue finishes, making
                    // progress = 0 at the exact moment we need to act.
                    let justStopped = self.lastPlaybackStatus == .playing
                                      && (status == .paused || status == .stopped)
                    self.lastPlaybackStatus = status
                    if justStopped {
                        let elapsedAtStop = self.lastKnownElapsedWhilePlaying
                        // Confirm after 200ms before advancing. Lock/unlock and
                        // foreground transitions can cause transient .paused blips
                        // that recover within ~100ms. A genuine end-of-track stays
                        // stopped; user-explicit pause sets isPlaying=false so the
                        // guard below exits early in either false-positive case.
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            guard let self,
                                  self.isPlaying,
                                  !self.isPreviewMode,
                                  !self.isLoadingTrack else { return }
                            // THE PRIMARY CHECK: does this look like the track
                            // actually reached its end? Confirmed via on-device
                            // diagnostic logging that Control Center's pause
                            // button pauses `ApplicationMusicPlayer` through
                            // MusicKit's own built-in integration, WITHOUT ever
                            // invoking our registered `pauseCommand` target —
                            // so `lastExplicitPauseAt` (below) never gets
                            // stamped for that path, and a wall-clock guess is
                            // structurally unable to help. Comparing how much
                            // of the track was actually left when it stopped is
                            // the reliable signal: a pause with real time
                            // remaining is never a natural completion,
                            // regardless of what triggered it.
                            let remaining = self.currentDuration - elapsedAtStop
                            guard remaining <= Self.endOfTrackTolerance else {
                                // Stopped well before the end — a genuine pause
                                // (Control Center, lock screen, or an
                                // interruption), not the queue naturally
                                // advancing. Reflect the real, already-paused
                                // state on the CURRENT track rather than
                                // skipping to the next one.
                                self.isPlaying = false
                                self.lastPlaybackStatus = .paused
                                return
                            }
                            // Looks like a genuine end. Still keep the existing
                            // `lastExplicitPauseAt` check as defense-in-depth for
                            // the separate case of an IN-APP pause tap (which DOES
                            // go through `togglePlayPause()` directly, unlike
                            // Control Center) racing an already-in-flight advance
                            // from a different track.
                            if let pausedAt = self.lastExplicitPauseAt,
                               Date().timeIntervalSince(pausedAt) < Self.explicitPauseGraceWindow {
                                return
                            }
                            let confirmed = ApplicationMusicPlayer.shared.state.playbackStatus
                            guard confirmed == .paused || confirmed == .stopped else { return }
                            await self.handleTrackEnd()
                        }
                    }
                }
            }
        }
    }

    /// Seek to a normalised position (0–1) in the current track.
    /// Moves both the underlying player and the published `progress` value
    /// so the scrubber stays in sync.
    func seek(to normalised: Double) {
        let clamped = max(0, min(1, normalised))
        progress = clamped
        let targetSeconds = currentDuration * clamped
        if activeService == .spotify, let spotifyService {
            let positionMs = Int(targetSeconds * 1000)
            Task { try? await spotifyService.seekSpotify(toPositionMs: positionMs) }
            return
        }
        if isPreviewMode {
            let time = CMTime(seconds: targetSeconds, preferredTimescale: 1000)
            previewPlayer?.seek(to: time)
        } else {
            ApplicationMusicPlayer.shared.playbackTime = targetSeconds
        }
    }

    /// Seek to an absolute position in milliseconds — the sync-follow sibling of
    /// the normalised `seek(to:)`. No-ops until the duration is known.
    func seekToMs(_ ms: Int) {
        guard currentDuration > 0 else { return }
        seek(to: Double(ms) / 1000 / currentDuration)
    }

    // MARK: - Audio session + Now Playing Info (preview-mode only)

    /// Whether the audio session has been activated this session. Activation is
    /// deferred out of the launch path (see `activateAudioSessionIfNeeded`).
    private var audioSessionActive = false

    /// Activates the shared audio session on demand — called the first time the
    /// `AVPlayer` preview path actually plays. Deliberately NOT called at launch:
    /// activating from the background (a background-locked relaunch of a
    /// background-audio app) can block the main thread and froze the app on a
    /// blank launch screen.
    private func activateAudioSessionIfNeeded() {
        guard !audioSessionActive else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            audioSessionActive = true
        } catch {
            debugLog("[Nodalong.Player] audio session activation failed: \(error)")
        }
    }

    private func setupRemoteCommands() {
        // Register remote-command targets only. The audio *category* is set in
        // `AppDelegate` at launch; the session is *activated* lazily at first
        // playback (`activateAudioSessionIfNeeded`) so launch never blocks on it.
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in await self?.togglePlayPause() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            // Stamp synchronously, on whatever thread the OS invoked this on —
            // BEFORE the MainActor hop below, whose scheduling latency is the
            // actual race the end-of-track edge detector is vulnerable to.
            // See `lastExplicitPauseAt`'s doc comment.
            self?.markExplicitPause()
            Task { @MainActor in await self?.togglePlayPause() }
            return .success
        }
        // Route lock-screen / Control-Center next & previous through OUR queue.
        //
        // Without these, the system next button acts on `ApplicationMusicPlayer`'s
        // single-entry queue — it just *ends* the current track, stopping audio.
        // While locked, an audio app that stops playing is suspended within
        // seconds, so the background advance to the next queued track never
        // finishes and the app gets killed (the "purple screen on reopen").
        // Driving `skipToNext`/`skipToPrevious` here keeps audio continuous, so
        // the background-audio assertion is never lost.
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.hasNext else { return .noSuchContent }
            Task { @MainActor in await self.skipToNext() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .noSuchContent }
            Task { @MainActor in await self.skipToPrevious() }
            return .success
        }
        updateRemoteCommandState()
    }

    /// Enables/disables the lock-screen next/previous buttons to match the queue.
    /// Called from `persistQueue()` (the chokepoint every queue/index mutation
    /// flows through) plus `restoreQueue()`.
    private func updateRemoteCommandState() {
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled     = hasNext
        center.previousTrackCommand.isEnabled = true   // ⏮ always acts (restart or step back)
    }

    private func updateNowPlayingInfo(_ track: NowPlayingTrack, duration: TimeInterval, elapsed: TimeInterval = 0) {
        let info: [String: Any] = [
            MPMediaItemPropertyTitle:                    track.title,
            MPMediaItemPropertyArtist:                   track.artist,
            MPMediaItemPropertyPlaybackDuration:         duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate:         1.0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        // Lock-screen artwork only needs ~300pt; avoid decoding the full 600×600.
        guard let url = URL(string: ArtworkURL.sized(track.artwork, points: 300)) else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let image = UIImage(data: data) else { return }
            Task { @MainActor in
                var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                updated[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
            }
        }.resume()
    }

    private func updateNowPlayingPlaybackState() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    #if DEBUG
    fileprivate func applyMockPreviewState(
        track: NowPlayingTrack,
        isPlaying: Bool,
        progress: Double,
        queue: [QueueItem] = [],
        currentIndex: Int = 0
    ) {
        self.nowPlaying      = track
        self.isPlaying       = isPlaying
        self.progress        = progress
        self.currentDuration = 210  // 3.5 min stub for previews
        self.queue           = queue
        self.currentIndex    = currentIndex
    }
    #endif
}

#if DEBUG
extension PlayerViewModel {
    /// Player VM with a fixture now-playing track loaded so MiniPlayerBar and
    /// NowPlayingView render content in previews. No audio session activated.
    static var mockPreview: PlayerViewModel {
        let vm = PlayerViewModel()
        vm.applyMockPreviewState(
            track: NowPlayingTrack(
                title:     PreviewFixtures.song.title,
                artist:    PreviewFixtures.song.artist,
                album:     PreviewFixtures.song.album,
                artwork:   PreviewFixtures.song.artwork,
                uri:       PreviewFixtures.song.uri,
                catalogId: PreviewFixtures.song.catalogId
            ),
            isPlaying: true,
            progress:  0.34,
            queue:     [QueueItem(song: PreviewFixtures.song)],
            currentIndex: 0
        )
        return vm
    }

    /// Player VM with a multi-track queue loaded — for previewing `QueueView`'s
    /// Up Next list (current track + two upcoming).
    static var mockPreviewWithQueue: PlayerViewModel {
        let vm = PlayerViewModel()
        let first = PreviewFixtures.songs[0]
        vm.applyMockPreviewState(
            track: NowPlayingTrack(
                title:     first.title,
                artist:    first.artist,
                album:     first.album,
                artwork:   first.artwork,
                uri:       first.uri,
                catalogId: first.catalogId
            ),
            isPlaying: true,
            progress:  0.2,
            queue:     PreviewFixtures.songs.map { QueueItem(song: $0) },
            currentIndex: 0
        )
        return vm
    }

    /// Empty player VM (no track loaded) — useful for previewing screens that
    /// must look correct before any playback has started.
    static var mockPreviewEmpty: PlayerViewModel {
        PlayerViewModel()
    }

    /// Player VM with `trackUnavailable = true` — lets `PlaybackErrorAlert`
    /// preview the alert in its triggered state.
    static var mockPreviewError: PlayerViewModel {
        let vm = PlayerViewModel()
        vm.trackUnavailable = true
        return vm
    }
}
#endif
