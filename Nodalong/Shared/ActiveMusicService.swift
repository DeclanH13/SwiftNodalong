import NodalongKit

/// Resolves which concrete `MusicService` conformer is authoritative right
/// now, based on `PlayerViewModel.activeService` — the single source of
/// truth for "which backend is connected" (see `ContentView`'s connect/
/// disconnect wiring).
///
/// Search, browse, and "is music connected" gates across the app were
/// originally written straight against the app's first (and only)
/// backend — `AppleMusicService` — from before Spotify playback existed.
/// Once Spotify became a real, working, and exclusively-connectable
/// service (see CLAUDE.md's Stage B + one-service-at-a-time decisions),
/// every one of those hardcoded call sites silently broke for a
/// Spotify-only account: Search returned nothing, and any screen gating
/// play/interact on `musicService.isAuthenticated` blocked the action
/// entirely, since that flag stays `false` when only Spotify is linked.
///
/// Callers hold both services via `@EnvironmentObject` (as before) and add
/// one computed property built on this function instead of hardcoding
/// `musicService` at each catalog/search/gate call site.
@MainActor
func activeMusicService(
    playerVM: PlayerViewModel,
    apple: AppleMusicService,
    spotify: SpotifyMusicService
) -> any MusicService {
    playerVM.activeService == .spotify ? spotify : apple
}

/// Persists the user's chosen linked music service (or `nil` to unlink),
/// then refreshes `authVM.profile` and updates `playerVM.activeService` so
/// every reactive UI surface (Profile's connected state, `shouldShowMusicLink`,
/// playback/search routing) picks up the change immediately.
///
/// This is the ONLY place `activeService` should be written from — a raw
/// service `isAuthenticated` flag (especially Apple Music's, which MusicKit
/// can never truly revoke per-app) is not a reliable signal for "the user
/// chose this service," so callers must invoke this explicitly from a real,
/// user-initiated connect/disconnect action rather than reacting passively
/// to an auth-state change.
@MainActor
func setActiveMusicService(
    _ service: MusicServiceType?,
    uid: String,
    playerVM: PlayerViewModel,
    authVM: FirebaseAuthViewModel
) async {
    try? await setActiveService(uid: uid, service: service)
    await authVM.refreshProfile()
    if let service {
        playerVM.activeService = service
    }
}
