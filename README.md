# Nodalong (iOS, Swift)

Native iOS port of the Nodalong social music-discovery app. Built with **SwiftUI + Firebase + (currently) Spotify**, mid-port to **Apple Music + MusicKit**.

> **New to Swift, or returning after a few years?** Skip ahead to [Reading order for new contributors](#reading-order-for-new-contributors) — it's a guided 30-minute tour that gets you to "I can change a screen and see it in the canvas" faster than reading every file.

---

## Quick start

Prerequisites: macOS, Xcode 15+, [XcodeGen](https://github.com/yonki-tanaka/XcodeGen).

```bash
brew install xcodegen
# Download GoogleService-Info.plist from Firebase Console → Project Settings → iOS apps,
# then drop it at Nodalong/GoogleService-Info.plist (gitignored).
xcodegen generate
open Nodalong.xcodeproj
```

Press **Cmd+R** in Xcode to run on a simulator.

**You never edit `Nodalong.xcodeproj` by hand or commit it** — it's regenerated from `project.yml`. Any time you change `project.yml` (add a target, change a build setting, etc.), run `xcodegen generate` again.

### Building from the command line

```bash
xcodegen generate
xcodebuild -project Nodalong.xcodeproj -scheme Nodalong \
  -destination 'generic/platform=iOS Simulator' build
```

---

## Reading order for new contributors

Open these files in this order. Reading them gives you the whole codebase. ~30 minutes.

1. **`project.yml`** — single source of truth for the Xcode project. Targets, dependencies, Info.plist, build settings.
2. **`Nodalong/AppDelegate.swift`** — the launch hook. Calls `FirebaseApp.configure()` and activates the audio session. 20 lines.
3. **`Nodalong/NodalongApp.swift`** — SwiftUI entry point. Creates every view model and injects them via `.environmentObject`. This is the dependency-injection root.
4. **`Nodalong/ContentView.swift`** — top-level router. Decides splash / auth stack / main app based on Firebase auth state.
5. **`Nodalong/Features/Main/MainTabView.swift`** — the bottom-tab UI.
6. **`Nodalong/Features/NearMe/`** — the NearMe feature folder. Read top to bottom. It's the **best worked example** of the codebase patterns: View ↔ ViewModel ↔ Firestore API call ↔ pure logic in NodalongKit.

Every file in those folders has a `///` doc-comment at the top explaining what it does and how it connects. **You should be able to navigate by reading file headers** rather than skim-reading the bodies.

---

## Project layout

```
SwiftNodalong/
├── project.yml                    # XcodeGen spec — edit this, run `xcodegen generate`
├── Nodalong.xcodeproj/            # Generated. Never edit. Not committed.
├── Nodalong/                      # App target — code that touches Firebase, SwiftUI, iOS frameworks
│   ├── NodalongApp.swift          # SwiftUI entry point + dependency injection
│   ├── ContentView.swift          # Splash / Auth / Main router
│   ├── AppDelegate.swift          # FirebaseApp.configure() on launch
│   ├── GoogleService-Info.plist   # Firebase config (gitignored)
│   ├── API/
│   │   ├── Firestore/             # One file per Firestore collection
│   │   └── Spotify/               # Spotify REST calls (DELETION CANDIDATE — see below)
│   ├── Services/                  # Long-lived app-wide services (Player, Library, Location, Sync)
│   ├── Features/
│   │   ├── Auth/                  # Splash, Login, Register, Forgot Password, Spotify Link
│   │   ├── Main/                  # MainTabView
│   │   ├── Feed/                  # Following + Your Music feeds
│   │   ├── Shelf/                 # Saved library: Albums + Artists views
│   │   ├── NearMe/                # Geohash map of nearby users
│   │   ├── Search/                # User + catalog search
│   │   ├── Profile/               # Own profile, other-user profile, edit, follow lists
│   │   └── Player/                # Now Playing full-screen
│   ├── Shared/
│   │   ├── UI/                    # Reusable views (TrackCard, MiniPlayerBar, AvatarPicker, ...)
│   │   ├── Theme/                 # Color tokens (Color+Theme.swift)
│   │   ├── Icons/                 # Sprite/character system
│   │   └── Previews/              # PreviewFixtures.swift — mock data for SwiftUI canvas
│   └── Resources/                 # Asset catalog, launch storyboard
├── NodalongKit/                   # Swift package — pure logic, no frameworks
│   ├── Sources/NodalongKit/
│   │   ├── Models/                # Data shapes (Song, Post, UserProfile, ...)
│   │   ├── Utils/                 # Pure functions (geohash, search ranking, grouping)
│   │   ├── Services/              # Cross-service protocols (MusicService)
│   │   └── Constants/             # Limits, theme constants
│   └── Tests/                     # Unit tests for the package
└── README.md                      # You are here
```

**Two folders for code, on purpose.** `Nodalong/` is the app target — it imports Firebase, SwiftUI, MusicKit, etc. `NodalongKit/` is a Swift package — pure Swift only, no Apple/Firebase frameworks. The split lets `NodalongKit` be unit-tested without spinning up Firebase or a simulator (see `NodalongKit/Tests/`).

**Rule:** if your new code doesn't need Firebase / UI / iOS frameworks, it belongs in `NodalongKit`.

---

## The five-second rule — where do I find X?

| If you want to change… | Look in… |
|---|---|
| What a screen looks like | `Nodalong/Features/<feature>/<Name>View.swift` |
| What a screen does (state, logic, API calls) | `Nodalong/Features/<feature>/<Name>ViewModel.swift` |
| A Firestore call | `Nodalong/API/Firestore/<Collection>.swift` |
| A Spotify call (going away) | `Nodalong/API/Spotify/SpotifyAPI.swift` |
| A data model (Song, Post, UserProfile, ...) | `NodalongKit/Sources/NodalongKit/Models/` |
| Pure logic with no UI (geohash, search ranking) | `NodalongKit/Sources/NodalongKit/Utils/` |
| A shared UI component (TrackCard, MiniPlayerBar) | `Nodalong/Shared/UI/` |
| Theme colors | `Nodalong/Shared/Theme/Color+Theme.swift` |
| App startup, provider wiring | `Nodalong/NodalongApp.swift` |
| Firebase initialisation | `Nodalong/AppDelegate.swift` |
| Mock data for SwiftUI previews | `Nodalong/Shared/Previews/PreviewFixtures.swift` |

---

## Firebase: where it lives

### Configuration

`Nodalong/GoogleService-Info.plist` — downloaded from the Firebase Console, **not committed** (see `.gitignore`). Without it, the app won't compile / won't connect.

### Initialisation

`Nodalong/AppDelegate.swift` calls `FirebaseApp.configure()` exactly once at launch. After that, every Firebase SDK call (Auth, Firestore, Storage) Just Works from anywhere in the app.

```swift
func application(_ application: UIApplication, didFinishLaunchingWithOptions ...) -> Bool {
    FirebaseApp.configure()
    configureAudioSession()
    return true
}
```

### Data access — one file per collection

Every Firestore read/write lives in **`Nodalong/API/Firestore/`**:

| File | Firestore collection(s) | What it does |
|---|---|---|
| `Users.swift` | `users/{uid}` | Profile CRUD, username search |
| `Posts.swift` | `users/{uid}/recent_tracks/` | Feed assembly, nod transactions |
| `Library.swift` | `users/{uid}/library/{catalogId}` | Save / unsave tracks |
| `Catalog.swift` | `tracks/{catalogId}`, `track_isrc_index/` | Cross-service track resolution by ISRC |
| `Follows.swift` | `users/{uid}/following/`, `followers/` | Follow graph |
| `Location.swift` | `users/{uid}` (geohash field) | Update + nearby-user geo queries |
| `LinkedServices.swift` | `users/{uid}/linked_services/spotify` | Spotify refresh-token persistence (going away) |

**Rule of thumb:** if you're reading or writing Firestore, the call is a free `async throws` function in one of these files. **View models call these functions; views never touch Firestore directly.**

The same convention applies to Spotify (`Nodalong/API/Spotify/`) and will apply to MusicKit when it lands.

---

## How data flows: a worked example

Take **loading the feed**. Five layers, top to bottom:

### 1. The View — `Features/Feed/FeedView.swift`

```swift
.task { await feedVM.load(myUid: authVM.profile?.uid) }
```

The view says "when I appear, ask the VM to load." That's the only thing the view knows about Firestore — there isn't one. It reads `feedVM.posts` and renders cards.

### 2. The ViewModel — `Features/Feed/FeedViewModel.swift` (the "controller")

```swift
@Published private(set) var posts: [Post] = []

func load(myUid: String?) async {
    posts = await fetchPosts(myUid: myUid)   // calls the API layer
}
```

The VM holds state. When `posts` changes, **SwiftUI re-renders the view automatically** — that's what `@Published` does. No imperative "redraw" call.

### 3. The API layer — `API/Firestore/Posts.swift`

```swift
func getFollowingFeed(myUid: String) async throws -> [Post] {
    // queries Firestore, decodes documents into Post structs, returns them
}
```

Pure `async throws` function. No SwiftUI imports here — this file knows about Firebase and `Post`, nothing else.

### 4. The Model — `NodalongKit/Sources/NodalongKit/Models/Post.swift`

```swift
public struct Post: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let username: String
    public let title: String
    // ...
}
```

Just a data shape. No behavior. Lives in NodalongKit because models have no framework dependencies — they're pure Swift.

### 5. Firestore — the actual remote DB

The Firebase iOS SDK in `API/Firestore/Posts.swift` handles HTTPS, caching, offline behaviour.

### The flow back

Firestore → SDK → decoded `[Post]` → `feedVM.posts = ...` → `@Published` broadcasts → SwiftUI sees state changed → `FeedView` re-renders → new cards appear.

**Read [FeedView.swift](Nodalong/Features/Feed/FeedView.swift) and [FeedViewModel.swift](Nodalong/Features/Feed/FeedViewModel.swift) side by side** and the pattern clicks. Every feature in the app uses the same five layers.

---

## SwiftUI previews — the dev workflow

**Every screen in this app is previewable in Xcode's canvas without running the simulator.** This is the dev workflow you should use 95% of the time. No Firebase setup, no signing in, no Spotify auth — just edit code, watch the canvas update.

### Using a preview

1. Open any view file (e.g. `FeedView.swift`).
2. Press **Cmd+Option+Enter** to show the canvas on the right.
3. The canvas renders the screen with hardcoded fixture data.
4. Edit code → canvas updates live.

### How it's wired

Three pieces:

**a. `Nodalong/Shared/Previews/PreviewFixtures.swift`** holds all mock data: a fake "you" user, a friend, sample songs, posts, library tracks, an artist, an album. The whole file is wrapped in `#if DEBUG` so it never ships in release builds.

**b. Each view model has a `static var mockPreview` factory** in a `#if DEBUG` extension next to it. Returns an instance pre-populated with fixtures. Example, end of `FeedViewModel.swift`:

```swift
#if DEBUG
extension FeedViewModel {
    static var mockPreview: FeedViewModel {
        let vm = FeedViewModel()
        vm.applyMockPreviewState(posts: PreviewFixtures.posts)
        return vm
    }
}
#endif
```

**c. `View.withPreviewEnvironment()`** (in `PreviewFixtures.swift`) injects *every* `@EnvironmentObject` the feature views read from. So a preview block is usually a one-liner:

```swift
#if DEBUG
#Preview {
    FeedView().withPreviewEnvironment()
}
#endif
```

### Why previews don't crash without Firebase

`FirebaseAuthViewModel.init()` would normally register a Firebase listener — that would crash in previews because `FirebaseApp.configure()` hasn't run. So the init is guarded:

```swift
if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" {
    startAuthListener()
}
```

Xcode sets `XCODE_RUNNING_FOR_PREVIEWS=1` automatically when rendering the canvas. The same guard exists on `PlayerViewModel` (skips audio session activation in previews).

**If you add a new VM whose `init()` touches Firebase, MusicKit, or system audio, copy this guard.**

### Adding a preview to a new view

```swift
#if DEBUG
#Preview {
    YourView().withPreviewEnvironment()
}
#endif
```

If your view takes a navigation parameter (like `UserProfileView(user: UserProfile)`), pass a fixture: `UserProfileView(user: PreviewFixtures.friendProfile)`. If you need a fixture that doesn't exist yet, add one to `PreviewFixtures.swift`.

### Troubleshooting previews

- **"No preview available"** — the file has no `#Preview { ... }` block. Add one.
- **"No ObservableObject of type X found"** — your view declares an `@EnvironmentObject` that `withPreviewEnvironment()` doesn't inject. Either add it to `PreviewFixtures.swift`, or inject inline:
  ```swift
  #Preview { YourView().environmentObject(YourVM.mockPreview).withPreviewEnvironment() }
  ```
- **Preview crashes when loading** — usually a VM `init()` is calling into Firebase or audio without the preview env-var guard. Add the guard.

---

## Architecture: MVVM, not MVC

iOS used to be MVC — every screen had a `UIViewController` class holding both UI and logic. SwiftUI dropped that. Nodalong uses **MVVM**:

| MVC role | Where it lives here | Example file |
|---|---|---|
| **Model** (data shape) | `NodalongKit/Sources/NodalongKit/Models/` | `Song.swift`, `Post.swift` |
| **View** (UI only) | `Nodalong/Features/<feature>/<Name>View.swift` | `FeedView.swift` |
| **ViewModel** (the "controller") | `Nodalong/Features/<feature>/<Name>ViewModel.swift` | `FeedViewModel.swift` |
| Service (cross-cutting, not per-screen) | `Nodalong/Services/` | `LocationService.swift` |

**There is no `Controller.swift` file** — the ViewModel *is* the controller. SwiftUI's `@Published` + `@EnvironmentObject` system makes the controller's job narrower than the old `UIViewController`: it doesn't manage view lifecycle or imperatively redraw, just exposes observable state.

**Service vs. ViewModel** — fuzzy distinction:
- **ViewModel** = state for a specific screen, scoped to that screen (`FeedViewModel`, `ShelfViewModel`)
- **Service** = app-wide capability with its own lifecycle, shared across screens (`LocationService`, `PlayerViewModel`, `LibrarySyncService`)

Both are `ObservableObject` classes injected via `@EnvironmentObject`.

---

## Swift for returners — five-minute cheat sheet

Patterns you'll see in every file:

**Optionals — `?` after a type means "may be nil."** Unwrap with `if let`, `guard let`, or `??` (default):
```swift
guard let uri = nowPlaying?.uri else { return }
let name = profile?.username ?? "Anonymous"
```

**`@Published`** — like `useState` on a class. SwiftUI views re-render automatically when a `@Published` property changes:
```swift
@Published private(set) var posts: [Post] = []
```

**`@EnvironmentObject`** — like React Context. App root injects an instance with `.environmentObject(...)`, any descendant reads it by declaring the property:
```swift
@EnvironmentObject private var feedVM: FeedViewModel
```

**`@MainActor`** — "this class only runs on the main thread." Required for anything that writes UI state. Every view model has it.

**`async`/`await` + `try`** — same as JavaScript, but throws is explicit. `try await x()` is `await x()` + "this might throw an error":
```swift
let users = try await getNearbyUsers(geohash: g, excludeUid: uid)
```

**Closures with `[weak self]`** — `(_) => { ... }` with explicit weak capture so the closure doesn't keep the VM alive forever. Swift has no garbage collector.

**`struct` vs `class`** — structs are values (copied on assignment), classes are references (shared). Models are structs. View models are classes (they have to be — `ObservableObject` requires class semantics).

That's 90% of what you'll read in this codebase. Everything else builds on it.

---

## Common tasks, step-by-step

### Add a new screen

1. Create `Nodalong/Features/<Feature>/<Name>View.swift` — your SwiftUI `View`.
2. If it needs state or API calls, create `Nodalong/Features/<Feature>/<Name>ViewModel.swift` (`ObservableObject`, `@MainActor`).
3. Wire navigation: either add a tab in `MainTabView.swift`, or push from an existing view with `NavigationLink(value: ...)`.
4. Add a `#Preview { YourView().withPreviewEnvironment() }` block at the bottom.

### Add a Firestore query

1. Open the relevant file in `Nodalong/API/Firestore/` (or create one for a new collection).
2. Add an `async throws` free function. Return decoded models from `NodalongKit/Sources/NodalongKit/Models/`.
3. Call it from a ViewModel — never from a View directly.

### Add a model field

1. Add the property to the struct in `NodalongKit/Sources/NodalongKit/Models/<Model>.swift`.
2. If you're updating `CodingKeys`, mirror the Firestore JSON key. Default-value the new property if old documents won't have it.
3. Update fixtures in `Nodalong/Shared/Previews/PreviewFixtures.swift`.

### Add a mock for a new ViewModel

1. In the VM file, add a `fileprivate func applyMockPreviewState(...)` that populates `@Published` properties from inside the class (so it can write through `private(set)`).
2. Below the class, add an `#if DEBUG extension YourVM { static var mockPreview: YourVM { ... } }`.
3. Add it to `withPreviewEnvironment()` in `PreviewFixtures.swift` so other previews inherit it.

---

## What's about to change

This codebase is mid-port from **Spotify** to **Apple Music**. The MusicKit migration will:

- **Delete** `Nodalong/API/Spotify/`, `SpotifyAuthViewModel`, `SpotifyLinkView`
- **Add** `AppleMusicService` conforming to the (cleaned-up) `MusicService` protocol in `NodalongKit/Sources/NodalongKit/Services/MusicService.swift`
- **Strip** access-token threading from every play call site — `playerVM.play(track, token: ...)` becomes `playerVM.play(track)`
- **Lose** the entire Spotify Web Playback hack — `ApplicationMusicPlayer.shared` + iOS Control Center handle playback and lock-screen metadata natively

Anything Spotify-specific is going away. **Don't invest in extending it.** If you see Spotify code, treat it as deletion-pending.

---

## Troubleshooting

- **"GoogleService-Info.plist not found"** — download from Firebase Console → Project Settings, drop at `Nodalong/GoogleService-Info.plist`.
- **Xcode project missing / out of date** — run `xcodegen generate`. Required after every `project.yml` change. Never edit the `.xcodeproj` by hand.
- **"No preview available" in a view file** — view doesn't have a `#Preview` block. Add one (see [SwiftUI previews](#swiftui-previews--the-dev-workflow)).
- **Preview crashes with "No ObservableObject of type X found"** — view needs an env object that `withPreviewEnvironment()` doesn't inject. Add it there, or inject inline in the `#Preview { }` block.
- **Build error about `Color.nodalong.something`** — check the theme tokens in `Nodalong/Shared/Theme/Color+Theme.swift`. Not every color you might want exists; add it there.
