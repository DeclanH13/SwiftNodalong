import SwiftUI
import FirebaseAuth
import NodalongKit

/// Holds the current user's Firebase Auth state and Nodalong profile.
///
/// Owns sign-in, registration, password reset, profile updates, and spotlight
/// add/remove with optimistic UI + rollback. The Firebase auth-state listener
/// fires on startup and re-loads the profile from Firestore.
///
/// Reads: Firebase Auth, Firestore `users/{uid}` and spotlight history.
/// Drives: every screen via `@EnvironmentObject` — `authVM.profile?.uid` is
/// the canonical "who am I" reference.
@MainActor
@Observable
final class FirebaseAuthViewModel {
    private(set) var currentUser: FirebaseAuth.User? = nil
    private(set) var profile: UserProfile? = nil
    /// True only from cold-start until the first auth-state check resolves.
    /// ContentView uses this to hold the splash colour; it is NOT set during sign-in.
    private(set) var isInitializing = true
    /// True while a sign-in / register network call is in flight.
    /// Disables form buttons and shows in-button progress views.
    private(set) var isSubmitting = false
    var authError: String? = nil
    var spotlightLimitReached = false

    /// Bumped exactly once per successful interactive sign-in/register —
    /// `ContentView` observes this (not `isAuthenticated`) to show the
    /// post-auth bridge splash. `isAuthenticated` also flips true on a cold
    /// launch once the profile lands, which would otherwise re-trigger the
    /// same bridge on every launch; a dedicated counter keeps the two cases
    /// distinct without relying on ordering between `@Published` writes.
    private(set) var postAuthBridgeToken = 0
    /// Set right before an interactive `signIn` call; consumed inside
    /// `loadProfile` to decide whether this particular profile load should
    /// bump `postAuthBridgeToken`. NOT the same signal as `isSubmitting` —
    /// `updateProfile()` also sets `isSubmitting` and calls `loadProfile`
    /// indirectly via `refreshProfile()`, and that path must NOT flash the
    /// splash.
    @ObservationIgnored private var pendingInteractiveAuth = false

    /// Set of trackIds the user has spotlit today (resets at midnight). Derived
    /// from profile so all spotlight UI stays in sync with a single source of truth.
    var todaySpotlitIds: Set<String> {
        let todayKey = dateKey(epochMs: Date().timeIntervalSince1970 * 1000)
        return Set((profile?.spotlightTracks ?? [])
            .filter { dateKey(epochMs: $0.spotlitAt) == todayKey }
            .map { $0.trackId })
    }

    var atSpotlightLimit: Bool { todaySpotlitIds.count >= maxSpotlights }

    @ObservationIgnored private var listenerHandle: AuthStateDidChangeListenerHandle?

    var isAuthenticated: Bool { currentUser != nil && profile != nil }

    init() {
        // Skip Firebase listener registration inside the Xcode preview agent —
        // FirebaseApp isn't configured there and the listener would crash.
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" {
            // Stale-while-revalidate: `Auth.auth().currentUser` is restored
            // synchronously from the keychain at launch. If we also have a
            // profile snapshot for that uid, render immediately — the splash
            // is skipped entirely — and let the listener's `loadProfile`
            // silently refresh from the network moments later (last write
            // wins). Genuine first-ever launch (no snapshot yet) falls
            // through unchanged: the splash holds until the network read
            // completes, same as before this existed.
            if let user = Auth.auth().currentUser,
               let cached = SnapshotStore.load(UserProfile.self, key: "profile", uid: user.uid) {
                currentUser = user
                profile = cached
                isInitializing = false
            }
            startAuthListener()
            startInitWatchdog()
        }
    }

    /// Safety net so the cold-launch splash can never wedge forever. If the auth
    /// listener / profile fetch hasn't resolved within 10 s (e.g. a Firestore
    /// read stalls on a background-locked relaunch), clear `isInitializing` so
    /// the UI falls through to a usable state instead of a frozen splash.
    private func startInitWatchdog() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, self.isInitializing else { return }
            self.isInitializing = false
        }
    }

    // MARK: - Auth state

    private func startAuthListener() {
        listenerHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentUser = user
                if let user {
                    await self.loadProfile(uid: user.uid)
                    await self.ensureUsernameLower()
                } else {
                    self.profile = nil
                    self.isInitializing = false
                    self.isSubmitting = false
                }
            }
        }
    }

    // MARK: - Auth operations

    func signIn(email: String, password: String) async {
        isSubmitting = true
        pendingInteractiveAuth = true
        authError = nil
        do {
            try await Auth.auth().signIn(withEmail: email, password: password)
            // Auth listener fires and calls loadProfile, which resets isSubmitting
            // and bumps postAuthBridgeToken (pendingInteractiveAuth is set).
        } catch {
            isSubmitting = false
            pendingInteractiveAuth = false
            authError = mapAuthError(error)
        }
    }

    func register(
        email: String,
        password: String,
        username: String,
        avatarEmoji: String,
        avatarColor: String
    ) async {
        isSubmitting = true
        authError = nil
        do {
            let result = try await Auth.auth().createUser(withEmail: email, password: password)
            let uid = result.user.uid
            let now = Date().timeIntervalSince1970 * 1000
            let newProfile = UserProfile(
                uid: uid,
                email: email,
                username: username,
                usernameLower: username.lowercased(),
                bio: "",
                avatarEmoji: avatarEmoji,
                avatarColor: avatarColor,
                activeService: .appleMusic,
                lastActive: now,
                createdAt: now,
                updatedAt: now
            )
            try await createUserProfile(newProfile)
            // Set state directly so we don't depend on the auth listener racing
            // against the Firestore write above.
            currentUser = result.user
            profile = newProfile
            SnapshotStore.save(newProfile, key: "profile", uid: uid)
            authError = nil
            isSubmitting = false
            postAuthBridgeToken += 1
        } catch {
            isSubmitting = false
            authError = mapAuthError(error)
        }
    }

    func signOut() {
        // Clear this uid's snapshots BEFORE signing out — a later sign-in on
        // this device (same or different account) must never render stale
        // content belonging to whoever was last signed in.
        if let uid = currentUser?.uid { SnapshotStore.clear(uid: uid) }
        try? Auth.auth().signOut()
    }

    func forgotPassword(email: String) async throws {
        try await Auth.auth().sendPasswordReset(withEmail: email)
    }

    func refreshProfile() async {
        guard let uid = currentUser?.uid else { return }
        await loadProfile(uid: uid)
    }

    func updateProfile(username: String, bio: String, avatarEmoji: String, avatarColor: String) async {
        guard let uid = currentUser?.uid else { return }
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSubmitting = true
        do {
            try await updateUserProfile(uid: uid, fields: [
                "username":      trimmed,
                "usernameLower": trimmed.lowercased(),
                "bio":           bio,
                "avatarEmoji":   avatarEmoji,
                "avatarColor":   avatarColor,
                "updatedAt":     Date().timeIntervalSince1970 * 1000
            ])
            await refreshProfile()
        } catch {
            authError = error.localizedDescription
        }
        isSubmitting = false
    }

    func addToSpotlight(_ track: LibraryTrackDoc) async {
        guard let uid = currentUser?.uid else { return }
        let current     = profile?.spotlightTracks ?? []
        let todayKey    = dateKey(epochMs: Date().timeIntervalSince1970 * 1000)
        let todayTracks = current.filter { dateKey(epochMs: $0.spotlitAt) == todayKey }
        let isUpdate    = todayTracks.contains { $0.trackId == track.catalogId }

        guard isUpdate || todayTracks.count < maxSpotlights else {
            spotlightLimitReached = true
            return
        }

        let now = Date().timeIntervalSince1970 * 1000
        let spotlight = SpotlightTrack(
            trackId:       track.catalogId,
            title:         track.title,
            artist:        track.artist,
            album:         track.album,
            artwork:       track.artwork,
            uri:           track.uri,
            spotlitAt:     now,
            catalogId:     track.catalogId,
            sourceService: track.sourceService
        )
        var newList = todayTracks.filter { $0.trackId != track.catalogId }
        newList.append(spotlight)

        // Optimistic update — star and profile section respond instantly.
        profile?.spotlightTracks = newList
        do {
            try await addSpotlightTrackBatch(uid: uid, spotlight: spotlight, newActiveList: newList)
        } catch {
            profile?.spotlightTracks = current
            authError = error.localizedDescription
        }
    }

    func removeFromSpotlight(trackId: String) async {
        guard let uid = currentUser?.uid else { return }
        let current = profile?.spotlightTracks ?? []
        let updated = current.filter { $0.trackId != trackId }

        // Optimistic update.
        profile?.spotlightTracks = updated
        do {
            try await updateSpotlightTracks(uid: uid, tracks: updated)
        } catch {
            profile?.spotlightTracks = current
            authError = error.localizedDescription
        }
    }

    // MARK: - Private helpers

    private func loadProfile(uid: String) async {
        // A cached snapshot may already be rendered (see `init()`) — a
        // transient network failure here must never blank or error it out
        // from under the user; it should just keep showing what's there
        // until a fetch actually succeeds.
        let hadProfile = profile != nil
        do {
            if let fresh = try await getUserProfile(uid: uid) {
                profile = fresh
                SnapshotStore.save(fresh, key: "profile", uid: uid)
            } else if !hadProfile {
                authError = "Profile not found. Please try signing in again."
            }
        } catch {
            if !hadProfile { authError = error.localizedDescription }
        }
        isInitializing = false
        isSubmitting = false
        if pendingInteractiveAuth {
            pendingInteractiveAuth = false
            postAuthBridgeToken += 1
        }
    }

    private func ensureUsernameLower() async {
        guard let profile, profile.usernameLower == nil,
              let uid = currentUser?.uid else { return }
        try? await updateUserProfile(uid: uid, fields: ["usernameLower": profile.username.lowercased()])
        await refreshProfile()
    }

    #if DEBUG
    /// Populates this VM with hardcoded fixture state. Called by `mockPreview`
    /// to bypass the Firebase listener and write directly to `private(set)`
    /// properties from inside the class.
    fileprivate func applyMockPreviewState() {
        self.profile = PreviewFixtures.myProfile
        self.isInitializing = false
    }
    #endif

    private func mapAuthError(_ error: Error) -> String {
        let code = (error as NSError).code
        if code == AuthErrorCode.invalidEmail.rawValue {
            return "Invalid email address."
        } else if code == AuthErrorCode.wrongPassword.rawValue
                    || code == AuthErrorCode.invalidCredential.rawValue {
            return "Incorrect email or password."
        } else if code == AuthErrorCode.emailAlreadyInUse.rawValue {
            return "An account with this email already exists."
        } else if code == AuthErrorCode.weakPassword.rawValue {
            return "Password must be at least 6 characters."
        } else if code == AuthErrorCode.networkError.rawValue {
            return "Network error. Please check your connection."
        } else {
            return "Something went wrong. Please try again."
        }
    }
}

#if DEBUG
extension FirebaseAuthViewModel {
    /// Authenticated VM instance for SwiftUI previews. Safe to construct
    /// without `FirebaseApp.configure()` because the env-guarded init skips
    /// the auth-state listener.
    static var mockPreview: FirebaseAuthViewModel {
        let vm = FirebaseAuthViewModel()
        vm.applyMockPreviewState()
        return vm
    }
}
#endif
