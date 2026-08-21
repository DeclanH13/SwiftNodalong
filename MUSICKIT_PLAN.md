# MusicKit Integration Plan

The Apple Music port is functional but minimal — it matches enough of the RN feature set to demo. This document maps the path from "minimal port" to **full feature parity with the React Native version, plus Apple-Music-only wins**, in prioritised phases.

The `MusicService` protocol stays as the public seam — every MusicKit-specific call hides behind it, so a future second backend (Spotify, YouTube Music, whatever) is a new conforming class away. Don't merge MusicKit-specific calls into views.

---

## Current state

### What works today

| Capability | Where | Notes |
|---|---|---|
| Apple Music authorisation | `AppleMusicService.authorize()` | System prompt via onboarding screen + Profile recovery |
| Catalog search (artists, albums, songs) | `AppleMusicService.searchAll(_:maxPerType:)` | Powers SearchView |
| Track lookup by ISRC | `AppleMusicService.searchByIsrc(_:)` | Cross-service bridge for legacy data |
| Track lookup by title + artist | `AppleMusicService.searchByTitleArtist(...)` | Fallback when ISRC missing |
| Artist albums (discography) | `AppleMusicService.getArtistAlbums(artistId:)` | Powers ArtistDetailSearchView |
| Album tracklist | `AppleMusicService.getAlbumTracks(...)` | Powers AlbumDetailSearchView |
| Saved library (100 most-recent) | `AppleMusicService.getSavedTracks()` | Hard-coded limit |
| Recently played | `AppleMusicService.getRecentlyPlayed()` | Single page |
| Playback | `PlayerViewModel.play(_:)` → `ApplicationMusicPlayer.shared` | Subscribers only |
| Cross-service track resolution | `PlayerViewModel.resolve(_:)` | URI → ISRC → text fallback |

### What's missing for RN parity

1. **Subscription gating UX.** Non-subscribers see play buttons that fail with "track unavailable." RN was the same on Spotify (premium required), but the UX should at minimum *tell* the user.
2. **30-second preview playback** for non-subscribers. Earlier attempt blocked on `MusicKit.Song.previews` API — needs more investigation.
3. **Library sync depth.** RN syncs the *entire* library across pages. We sync the most recent 100.
4. **Recently-played history depth.** Single page; no pagination.
5. **Open-in-Apple-Music deep links.** RN had "Open in Spotify" — equivalent would be `music://music.apple.com/...` URLs to launch the Music.app.
6. **Subscription status in UI.** Currently no surface anywhere shows "you're not subscribed."

### What's Apple-Music-only and worth grabbing

- **Personalised recommendations** — `MusicPersonalRecommendation` exposes "Made For You" content.
- **Charts** — `MusicCatalogChartsRequest` for trending/top songs by genre/city.
- **Rich metadata** — explicit indicator, audio quality (Lossless/Spatial), copyright. Currently unused.
- **Lyrics & timed lyrics** — `MusicKit.Lyrics` for karaoke-style display.
- **Listen Now** — Apple's curated feed could augment Following / Your Music.
- **Music videos** — `MusicVideo` resource type alongside `Song`.

---

## Phase A — Parity with RN (ship-blocker)

Goal: a Nodalong user moving from the RN version notices no missing functionality.

### A1. Subscription state surfacing ✅ DONE

`AppleMusicService` exposes `@Published subscription: MusicSubscription?` plus convenience properties `canPlayFullTracks` and `canBecomeSubscriber`. A background `Task` watches `MusicSubscription.subscriptionUpdates` and updates state automatically. The observer restarts after `authorize()` and on foreground via `refreshAuthStatus()`.

`ProfileView.musicSection` shows two rows when authorised: auth state + subscription state. When the user is authorised but not subscribed (and eligible), a "Subscribe to Apple Music" button presents the system `.musicSubscriptionOffer(...)` — no custom sign-up UI required.

A `PlaybackErrorAlert` view modifier (applied to MiniPlayerBar + NowPlayingView) catches `playerVM.trackUnavailable` and shows a Subscribe CTA there too.

### A2. Preview-URL playback for non-subscribers ✅ DONE

Solved. The right MusicKit API is `Song.previewAssets: [PreviewAsset]?` (the previous attempt used the wrong name `previews`). Each `PreviewAsset` has `url` (progressive AAC) and `hlsURL`.

`PlayerViewModel.play()` now tries `ApplicationMusicPlayer.shared.play()` first. If it throws (typical cause: no subscription), it falls through to `playPreview(of:)` which uses `AVPlayer` with the preview URL and manually populates `MPNowPlayingInfoCenter`.

Sets `trackUnavailable = true` only if **both** paths fail, which surfaces the `PlaybackErrorAlert` → "Subscribe to Apple Music" sheet.

### A3. Full library pagination

**What:** `getSavedTracks()` should fetch the user's entire library, not just 100.

**How:**
```swift
func getSavedTracks() async throws -> [NodalongKit.Song] {
    var results: [MusicKit.Song] = []
    var req = MusicLibraryRequest<MusicKit.Song>()
    req.limit = 100
    var response = try await req.response()
    results.append(contentsOf: response.items)
    while let next = try await response.nextBatch() {
        response = next
        results.append(contentsOf: response.items)
        if Task.isCancelled { break }
    }
    return results.map { Self.toSong($0) }
}
```

**Cost awareness:** A user with 5k saved tracks → 50 requests. Cache aggressively in `TrackCache`. Consider doing a delta sync (last `savedAt` timestamp) on subsequent runs instead of re-fetching all.

**Estimate:** 1 hour including the delta-sync optimisation.

### A4. Recently-played pagination

Same pattern as A3 for `MusicRecentlyPlayedRequest<MusicKit.Song>`. ~30 minutes.

### A5. *Removed.* Originally proposed "Open in Music.app" deep links — wrong direction. **All playback stays in-app.**

Nodalong is the player. `ApplicationMusicPlayer.shared` routes audio through Nodalong's audio session, Control Center shows the Nodalong brand, lock-screen controls drive `PlayerViewModel`. The user should never have to leave the app to listen.

Album/artist title taps in Shelf already navigate **in-app** to `AlbumDetailSearchView` / `ArtistDetailSearchView` (via `musicService.searchAll(...)` lookups), where rows play via `PlayerViewModel.play()`. That's the pattern.

If a "view full catalog details" affordance is wanted later, it lives inside Nodalong as a richer detail screen — not as an `open(URL)` to Music.app.

### A6. Subscription upgrade flow

**What:** When the user is unsubscribed and tries to play, show a sheet that offers them the Apple Music sign-up URL.

**How:** `MusicSubscription.current.subscribeURL` gives you the link. Wrap it in `SKOverlay` (the iOS in-app App Store overlay) for a native presentation, or just `.sheet { SafariView(url: ...) }`.

**Estimate:** 1 hour with SKOverlay; 15 min with SafariView.

---

## Phase B — Apple-Music-only wins

Goal: features the RN/Spotify version *couldn't have*.

### B1. Personalised recommendations strip on Feed

`MusicPersonalRecommendationsRequest` returns "Made For You" sections (Heavy Rotation, New Releases, Get Up Mix, etc). Slot a horizontal carousel into the FeedView between the segmented toggle and the following posts.

**API:**
```swift
let req = MusicPersonalRecommendationsRequest()
let resp = try await req.response()
// resp.recommendations is [MusicPersonalRecommendation]
```

Each recommendation has a title and a heterogenous list of items (songs, playlists, albums). Render selectively.

**Estimate:** 2-3 hours including UI.

### B2. Charts on the Search empty state

When the user opens Search but hasn't typed anything, show today's top tracks. Today the empty state is just a grey screen.

**API:** `MusicCatalogChartsRequest<MusicKit.Song>` (and similar for albums/playlists).

**Estimate:** 1-2 hours.

### B3. Lyrics on NowPlayingView

Tap album art to flip the card and show lyrics. Apple Music subscribers get *timed* lyrics that highlight the current line — `Lyrics.lines[index].timeRanges` syncs to playback time.

**API:** `MusicCatalogResourceRequest<MusicKit.Song>(matching: \.id, equalTo: id)` then `song.with([.lyrics])` exposes a `Lyrics` collection.

**Estimate:** 3-4 hours. Real product feature.

### B4. Explicit indicator + audio quality badges

Apple Music exposes `Song.contentRating == .explicit` and `audioVariants: [AudioVariant]`. Add a small "E" badge to track rows for explicit content, and a "Lossless"/"Dolby Atmos" indicator on NowPlayingView. Small but it's the Apple Music aesthetic.

**Estimate:** 1 hour.

### B5. Catalog queue beyond single-track

Currently `PlayerViewModel.play(_:)` enqueues exactly one song. `ApplicationMusicPlayer.Queue` supports rich playback — entire albums, mixes of songs, "play this song then continue with similar." Let Feed and Shelf push album-or-context-aware playback.

**API:**
```swift
ApplicationMusicPlayer.shared.queue = ApplicationMusicPlayer.Queue(for: album)
// or
ApplicationMusicPlayer.shared.queue = ApplicationMusicPlayer.Queue(for: [song1, song2, song3])
```

**Estimate:** 2 hours.

---

## Phase C — Polish

### C1. Cross-service catalog enrichment (Cloud Function)

When a feed post lands in Firestore with `appleMusicUri` missing (e.g. a legacy import or a second-service write), a Firestore-triggered Cloud Function does the ISRC lookup and writes back. This is the one Cloud Function I'd actually build, per the earlier discussion.

**Estimate:** 1 hour, ~30 lines of TypeScript.

### C2. Robust artist image fallback

`AppleMusicService.toArtistResult` uses `Artist.artwork` which is sometimes nil. Fall back to the artist's top album's artwork (one extra MusicKit call per nil artist). Cache aggressively.

**Estimate:** 1 hour.

### C3. Better resolution retries

`PlayerViewModel.resolve()` falls through ISRC → text. If text fails too, currently throws. Add one more rung: search by **just** the artist + album + track number (Apple Music IDs change across regions; same metadata can refind).

**Estimate:** 30 min.

### C4. Settings deep-link denial recovery — also add to AppleMusicLinkView

Currently `AppleMusicLinkView` only shows the "not determined" copy. If the user lands there in `.denied` state somehow (edge case), show the Settings recovery path.

**Estimate:** 15 min.

---

## Suggested order

1. **A1, A5, A6** — small/visible (1 day of work, real UX uplift)
2. **A3, A4** — library completeness (half a day)
3. **A2** — the preview playback piece (chunky; needs API research)
4. **B2, B4** — easiest Apple-Music wins (half a day combined)
5. **B5** — queue improvements (real product polish)
6. **B1, B3** — bigger product features (a couple of days each)
7. **C1, C2, C3, C4** — incremental polish

**Don't do:**
- Don't add MusicKit-specific types to view models. Hide everything behind `MusicService`.
- Don't fork the protocol per service. If you add Spotify back later, extend the protocol to cover the common surface; service-specific extras go on `AppleMusicService` directly and views narrow-cast.
- Don't persist MusicKit objects in Firestore. Always convert to `Song` / `CatalogTrack` first.

---

## Mapping table — RN feature → MusicKit API

| RN feature | MusicKit API |
|---|---|
| `getSavedTracks` (Spotify) | `MusicLibraryRequest<MusicKit.Song>` + pagination |
| `getRecentlyPlayed` | `MusicRecentlyPlayedRequest<MusicKit.Song>` |
| `searchAll` | `MusicCatalogSearchRequest(term:, types:)` |
| `searchByIsrc` | `MusicCatalogResourceRequest<Song>(matching: \.isrc, equalTo:)` |
| `getArtistAlbums` | `Artist.with([.albums])` after id lookup |
| `getAlbumTracks` | `Album.with([.tracks])` after id lookup |
| `play(uri:)` | `ApplicationMusicPlayer.shared.queue/play()` |
| `pause` | `ApplicationMusicPlayer.shared.pause()` |
| `withAutoRefresh` 401/refresh | **None needed** — MusicKit handles auth |
| Web Playback SDK device fallback | **None needed** — system plays via the device speaker |
| Spotify Connect | Not in MusicKit. Use AirPlay if device routing matters. |
| Now Playing metadata | Automatic via `ApplicationMusicPlayer` |
| Preview URLs | `Song.previews` (needs relationship load — investigate) |
| Subscription check | `MusicSubscription.subscriptionUpdates` |

---

## What stays the same

- `MusicService` protocol — the seam. Don't delete.
- `MusicServiceType` enum — keep `.spotify` for forward-compat with a second backend.
- All Firestore models — unchanged shapes, Apple Music URIs just go in `appleMusicUri`.
- The view model layer — already service-agnostic where it should be.
