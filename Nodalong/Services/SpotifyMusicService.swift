import Foundation
import CryptoKit
import AuthenticationServices
import UIKit
import NodalongKit

/// Web-API-backed implementation of `MusicService` for Spotify.
///
/// **Stage A scope**: auth (PKCE) + search/browse/library only. Playback is
/// intentionally stubbed — Spotify's Web API is a remote-control surface (HTTP
/// commands to an active Spotify Connect device), fundamentally unlike
/// MusicKit's in-process `ApplicationMusicPlayer`, and wiring it into
/// `PlayerViewModel` is a separate, later piece of work (Stage B). See the
/// project's Spotify integration plan for the full staging rationale.
///
/// No Spotify SDK dependency — plain `URLSession` + hand-rolled PKCE, since
/// Spotify's OAuth flow has no first-party Swift package. Tokens live in
/// `KeychainHelper` only (never Firestore, never UserDefaults).
@MainActor
final class SpotifyMusicService: ObservableObject, MusicService {

    // MARK: - Identity

    /// Returns `.spotify` — this conformer is permanently single-service,
    /// mirroring `AppleMusicService.serviceType`.
    nonisolated var serviceType: MusicServiceType { .spotify }

    // MARK: - Authorization state

    /// `true` once a valid (or refreshable) token set exists.
    @Published private(set) var isAuthenticated: Bool = false

    /// `true` only during the `ASWebAuthenticationSession` round-trip — lets
    /// Profile show a connecting spinner instead of a dead button tap.
    @Published private(set) var isAuthenticating: Bool = false

    /// Last error from `authorize()`, surfaced by Profile as an inline
    /// message. Cleared at the start of the next `authorize()` attempt.
    @Published private(set) var lastError: SpotifyServiceError? = nil

    /// The connected account's actual Spotify display name (`GET /v1/me`).
    /// Fetched once right after a successful connect/relaunch, purely so
    /// Profile can show "Connected as {name}" instead of a generic
    /// "Connected to Spotify" — concrete, at-a-glance proof this is a real,
    /// distinct Spotify account and not confusable with Apple Music (which
    /// has no equivalent identity to display).
    @Published private(set) var displayName: String? = nil

    // MARK: - Auth session state

    /// Held for the duration of `authorize()` only — `ASWebAuthenticationSession`
    /// and its presentation-context delegate must outlive the call that starts
    /// them or ARC can deallocate them before the completion handler fires.
    private var authSession: ASWebAuthenticationSession?
    private var authContextProvider: SpotifyAuthPresentationContextProvider?

    /// One-shot proactive-refresh timer, rescheduled after every successful
    /// exchange/refresh. See `scheduleProactiveRefresh(expiresIn:)`.
    private var refreshTask: Task<Void, Never>?

    // MARK: - Init / deinit

    init() {
        guard let existing = SpotifyTokenSet.loadFromKeychain() else { return }
        isAuthenticated = true
        let remaining = existing.expiresAt.timeIntervalSinceNow
        if remaining <= 60 {
            // Already expired or about to be — refresh now rather than
            // waiting out a timer that's already effectively due.
            Task { [weak self] in await self?.refreshInBackground() }
        } else {
            scheduleProactiveRefresh(expiresIn: remaining)
        }
        Task { [weak self] in await self?.fetchDisplayName() }
    }

    deinit {
        refreshTask?.cancel()
    }

    // MARK: - Authorization

    /// Runs the PKCE authorize flow via `ASWebAuthenticationSession`, then
    /// exchanges the returned code for tokens. Throws on cancellation, a
    /// `state` mismatch (CSRF guard), or a failed token exchange.
    func authorize() async throws {
        isAuthenticating = true
        lastError = nil
        defer { isAuthenticating = false }

        let verifier  = PKCE.generateCodeVerifier()
        let challenge = PKCE.codeChallenge(for: verifier)
        let state     = PKCE.generateState()

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authURL = components.url else { throw SpotifyServiceError.authCallbackMalformed }

        do {
            let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let contextProvider = SpotifyAuthPresentationContextProvider()
                authContextProvider = contextProvider

                let session = ASWebAuthenticationSession(
                    url: authURL,
                    callbackURLScheme: "com.bigdeccyh.nodalong"
                ) { url, error in
                    if let url {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: SpotifyServiceError.authCancelled(error))
                    }
                }
                session.presentationContextProvider = contextProvider
                // No cookie-jar reuse — appropriate for a first-time linking
                // flow with narrow scopes, at the cost of the user re-entering
                // credentials even if already logged into Spotify in Safari.
                session.prefersEphemeralWebBrowserSession = true
                authSession = session
                session.start()
            }

            guard
                let comps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                let items = comps.queryItems,
                let returnedState = items.first(where: { $0.name == "state" })?.value,
                returnedState == state,
                let code = items.first(where: { $0.name == "code" })?.value
            else {
                throw SpotifyServiceError.authCallbackMalformed
            }

            try await exchangeCodeForTokens(code: code, codeVerifier: verifier)
            authContextProvider = nil
            authSession = nil
        } catch {
            authContextProvider = nil
            authSession = nil
            lastError = error as? SpotifyServiceError ?? .network(error)
            throw error
        }
    }

    /// Clears local auth state and Keychain tokens. Spotify's Web API has no
    /// public token-revocation endpoint, so there's nothing to call remotely
    /// — wiping the local tokens is the correct and only action.
    func logout() async throws {
        refreshTask?.cancel()
        refreshTask = nil
        authSession = nil
        authContextProvider = nil
        KeychainHelper.remove(account: SpotifyTokenSet.Keys.accessToken)
        KeychainHelper.remove(account: SpotifyTokenSet.Keys.refreshToken)
        KeychainHelper.remove(account: SpotifyTokenSet.Keys.expiresAt)
        isAuthenticated = false
        displayName = nil
    }

    // MARK: - Token management

    /// Exchanges an authorization code for the initial token set. Spotify's
    /// contract guarantees a `refresh_token` on this call (unlike on refresh,
    /// where it's optional) — treat its absence as a failed exchange.
    private func exchangeCodeForTokens(code: String, codeVerifier: String) async throws {
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": Self.clientId,
            "code_verifier": codeVerifier,
        ]
        let dto = try await postTokenRequest(formBody: body)
        guard let refreshToken = dto.refreshToken else {
            throw SpotifyServiceError.authCallbackMalformed
        }
        let tokenSet = SpotifyTokenSet(
            accessToken: dto.accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(dto.expiresIn))
        )
        tokenSet.saveToKeychain()
        isAuthenticated = true
        scheduleProactiveRefresh(expiresIn: TimeInterval(dto.expiresIn))
        await fetchDisplayName()
    }

    /// `GET /v1/me` — fetches the connected account's own Spotify profile,
    /// purely for the display name shown in Profile. Best-effort: a failure
    /// here just means the row falls back to the generic "Connected to
    /// Spotify" label, not a broken auth state.
    private func fetchDisplayName() async {
        do {
            let dto: SpotifyMeDTO = try await authenticatedRequest(path: "/me", decoding: SpotifyMeDTO.self)
            displayName = dto.displayName?.nonEmpty ?? dto.id.nonEmpty
        } catch {
            print("[Nodalong.SpotifyMe] fetchDisplayName failed: \(error)")
        }
    }

    /// Refreshes the access token. Used both proactively (timer-driven) and
    /// reactively (401 backstop in `performRequest`).
    ///
    /// **Confirmed-in-production gotcha**: Spotify's refresh response can
    /// omit `refresh_token` entirely when the existing one is still valid for
    /// reuse — if absent, the existing Keychain value is kept, never
    /// overwritten with nothing (that would strand the session on the very
    /// next refresh).
    private func refreshAccessToken() async throws {
        guard var tokenSet = SpotifyTokenSet.loadFromKeychain() else {
            throw SpotifyServiceError.unauthorized
        }
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": tokenSet.refreshToken,
            "client_id": Self.clientId,
        ]
        let dto = try await postTokenRequest(formBody: body)
        tokenSet.accessToken = dto.accessToken
        if let newRefreshToken = dto.refreshToken {
            tokenSet.refreshToken = newRefreshToken
        }
        tokenSet.expiresAt = Date().addingTimeInterval(TimeInterval(dto.expiresIn))
        tokenSet.saveToKeychain()
        scheduleProactiveRefresh(expiresIn: TimeInterval(dto.expiresIn))
    }

    /// Timer-path wrapper — swallows errors, since a failed proactive refresh
    /// just means the reactive 401 path in `performRequest` catches it later.
    private func refreshInBackground() async {
        try? await refreshAccessToken()
    }

    /// Schedules a one-shot proactive refresh ~60s before the token expires.
    /// Cancels any previously scheduled refresh first — safe to call
    /// repeatedly, since every successful exchange/refresh reschedules this.
    /// No in-flight-refresh-dedup mutex: a concurrent proactive-timer refresh
    /// racing a reactive 401 refresh is tolerated (matches the sibling RN
    /// app's own accepted simplification) — redundant refresh calls are
    /// idempotent, worst case one surfaces as a single transient failure.
    private func scheduleProactiveRefresh(expiresIn: TimeInterval) {
        refreshTask?.cancel()
        let delay = max(expiresIn - 60, 5)
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.refreshInBackground()
        }
    }

    /// `POST /api/token` — `application/x-www-form-urlencoded`, NOT JSON
    /// (confirmed from a sibling production Spotify client; this is not
    /// documented as obvious and is easy to get wrong).
    private func postTokenRequest(formBody: [String: String]) async throws -> SpotifyTokenResponseDTO {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SpotifyServiceError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SpotifyServiceError.network(URLError(.badServerResponse))
        }
        guard (200...299).contains(http.statusCode) else {
            // 400 from the token endpoint is almost always `invalid_grant`
            // (expired/revoked code or refresh token) — treat as unauthorized
            // so callers route back into a fresh `authorize()`.
            throw http.statusCode == 400
                ? SpotifyServiceError.unauthorized
                : SpotifyServiceError.server(statusCode: http.statusCode)
        }
        do {
            return try JSONDecoder.spotify.decode(SpotifyTokenResponseDTO.self, from: data)
        } catch {
            throw SpotifyServiceError.decoding(error)
        }
    }

    // MARK: - Low-level HTTP

    private enum HTTPMethod: String { case get = "GET", put = "PUT", post = "POST" }

    /// Builds an authenticated `GET` request against the Spotify Web API and
    /// decodes its JSON body.
    private func authenticatedRequest<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        decoding type: T.Type
    ) async throws -> T {
        let request = try authenticatedURLRequest(method: .get, path: path, queryItems: queryItems)
        let data = try await sendWithRetry(request)
        do {
            return try JSONDecoder.spotify.decode(T.self, from: data)
        } catch {
            throw SpotifyServiceError.decoding(error)
        }
    }

    /// Issues a `PUT` command against the Spotify Web API with no response
    /// body expected — every playback-control endpoint (play/pause/seek/
    /// transfer) returns 204 No Content on success.
    private func authenticatedCommand(
        path: String,
        queryItems: [URLQueryItem] = [],
        jsonBody: [String: Any]? = nil,
        method: HTTPMethod = .put
    ) async throws {
        var request = try authenticatedURLRequest(method: method, path: path, queryItems: queryItems)
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: jsonBody)
        }
        _ = try await sendWithRetry(request)
    }

    private func authenticatedURLRequest(
        method: HTTPMethod,
        path: String,
        queryItems: [URLQueryItem]
    ) throws -> URLRequest {
        guard let tokenSet = SpotifyTokenSet.loadFromKeychain() else {
            throw SpotifyServiceError.unauthorized
        }
        guard var components = URLComponents(string: "https://api.spotify.com/v1" + path) else {
            throw SpotifyServiceError.unknown(statusCode: -1)
        }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { throw SpotifyServiceError.unknown(statusCode: -1) }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("Bearer \(tokenSet.accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Shared retry engine — every catalog/library/playback call funnels
    /// through here, whether or not it expects a JSON body back. Retry
    /// contract (confirmed from a sibling production Spotify client's real
    /// behavior, not estimated):
    /// - 401: refresh the access token once, retry the request once.
    /// - 429: read `Retry-After` (seconds), wait, retry once (not a loop).
    /// - 502/503: up to 2 retries, sleeping 1s then 2s between attempts.
    /// - Any other 4xx/5xx: throw immediately, no retry.
    private func sendWithRetry(
        _ request: URLRequest,
        didRefresh: Bool = false,
        rateLimitRetries: Int = 0,
        serverRetries: Int = 0
    ) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SpotifyServiceError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SpotifyServiceError.network(URLError(.badServerResponse))
        }

        switch http.statusCode {
        case 200...299:
            return data

        case 401:
            guard !didRefresh else { throw SpotifyServiceError.unauthorized }
            try await refreshAccessToken()
            guard let refreshed = SpotifyTokenSet.loadFromKeychain() else { throw SpotifyServiceError.unauthorized }
            var retried = request
            retried.setValue("Bearer \(refreshed.accessToken)", forHTTPHeaderField: "Authorization")
            return try await sendWithRetry(
                retried, didRefresh: true,
                rateLimitRetries: rateLimitRetries, serverRetries: serverRetries
            )

        case 403:
            throw SpotifyServiceError.forbidden

        case 404:
            throw SpotifyServiceError.notFound

        case 429:
            guard rateLimitRetries < 1 else {
                throw SpotifyServiceError.rateLimited(retryAfterSeconds: retryAfterSeconds(from: http))
            }
            let wait = retryAfterSeconds(from: http)
            try await Task.sleep(nanoseconds: UInt64(max(wait, 0)) * 1_000_000_000)
            return try await sendWithRetry(
                request, didRefresh: didRefresh,
                rateLimitRetries: rateLimitRetries + 1, serverRetries: serverRetries
            )

        case 502, 503:
            guard serverRetries < 2 else { throw SpotifyServiceError.server(statusCode: http.statusCode) }
            let delaySeconds: UInt64 = serverRetries == 0 ? 1 : 2
            try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            return try await sendWithRetry(
                request, didRefresh: didRefresh,
                rateLimitRetries: rateLimitRetries, serverRetries: serverRetries + 1
            )

        case 500...599:
            throw SpotifyServiceError.server(statusCode: http.statusCode)

        default:
            throw SpotifyServiceError.unknown(statusCode: http.statusCode)
        }
    }

    /// Defaults to 2s (slightly more conservative than a naive 1s) if
    /// Spotify omits `Retry-After` — shouldn't happen per their docs, but
    /// defensive against a rate-limit storm.
    private func retryAfterSeconds(from response: HTTPURLResponse) -> Int {
        response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init) ?? 2
    }

    // MARK: - Library

    func getSavedTracks() async throws -> [NodalongKit.Song] {
        let dto: SpotifyPagingDTO<SpotifySavedTrackDTO> = try await authenticatedRequest(
            path: "/me/tracks",
            queryItems: [URLQueryItem(name: "limit", value: "50")],
            decoding: SpotifyPagingDTO<SpotifySavedTrackDTO>.self
        )
        return dto.items.compactMap { Self.toSong($0.track) }
    }

    func getRecentlyPlayed() async throws -> [NodalongKit.Song] {
        let dto: SpotifyPagingDTO<SpotifyPlayHistoryDTO> = try await authenticatedRequest(
            path: "/me/player/recently-played",
            queryItems: [URLQueryItem(name: "limit", value: "25")],
            decoding: SpotifyPagingDTO<SpotifyPlayHistoryDTO>.self
        )
        return dto.items.compactMap { item in
            let listenedAt = item.playedAt
                .flatMap { ISO8601DateFormatter().date(from: $0) }
                .map { $0.timeIntervalSince1970 * 1000 }
            return Self.toSong(item.track, listenedAt: listenedAt)
        }
    }

    // MARK: - Playback (Stage B — remote control of an active Spotify Connect device)

    /// Resolves `song` to a real Spotify track (via `resolve`), ensures an
    /// active Connect device exists, and issues `PUT /me/player/play` with a
    /// single-URI list — mirrors `PlayerViewModel`'s existing "one song
    /// loaded at a time, our queue is authoritative" model exactly (the same
    /// reason `ApplicationMusicPlayer.queue` is always a single-entry array),
    /// so the device stops after this one track instead of auto-advancing
    /// into an unrelated Spotify context.
    func play(_ song: NodalongKit.Song) async throws {
        _ = try await playReturningResolvedUri(song)
    }

    /// Same as `play(_:)`, but returns the resolved Spotify track URI —
    /// `play(_:)` itself can't (it's a fixed-signature `MusicService`
    /// protocol requirement). Used by `PlayerViewModel` to remember exactly
    /// which Spotify URI it just told Spotify to play, so a later poll can
    /// detect when Spotify's own Next/Previous diverges from that.
    func playReturningResolvedUri(_ song: NodalongKit.Song) async throws -> String {
        let track = try await resolve(song)
        let deviceId = try await ensureActiveDevice()
        try await authenticatedCommand(
            path: "/me/player/play",
            queryItems: [URLQueryItem(name: "device_id", value: deviceId)],
            jsonBody: ["uris": [track.uri]]
        )
        return track.uri
    }

    /// Resolves `song` to its Spotify catalog URI without issuing a play
    /// command — used to pre-queue the next track (`addToNativeQueue(uri:)`)
    /// ahead of when it's actually due to play.
    func resolveTrackUri(for song: NodalongKit.Song) async throws -> String {
        try await resolve(song).uri
    }

    /// Adds a single track to Spotify's own native queue (`POST
    /// /me/player/queue`) — this is the ONLY queue-mutating endpoint
    /// Spotify's Web API exposes publicly; there is no remove, clear, or
    /// reorder endpoint at all (confirmed against Spotify's own docs and
    /// developer community — a long-standing, still-unaddressed limitation).
    /// Spotify's own docs also warn ordering isn't guaranteed across
    /// multiple queue-add calls. So this can only ever mirror ONE track at a
    /// time (the immediate next one) — don't extend this into a multi-track
    /// queue mirror without re-confirming that constraint has changed.
    func addToNativeQueue(uri: String) async throws {
        try await authenticatedCommand(
            path: "/me/player/queue",
            queryItems: [URLQueryItem(name: "uri", value: uri)],
            method: .post
        )
    }

    func resume() async throws {
        let deviceId = try await ensureActiveDevice()
        // No body — resumes whatever's currently loaded on the device.
        try await authenticatedCommand(path: "/me/player/play", queryItems: [URLQueryItem(name: "device_id", value: deviceId)])
    }

    func pause() async throws {
        let deviceId = try await ensureActiveDevice()
        try await authenticatedCommand(path: "/me/player/pause", queryItems: [URLQueryItem(name: "device_id", value: deviceId)])
    }

    /// Beyond the base `MusicService` protocol (matches the
    /// `getArtistTopTracks` precedent) — `PlayerViewModel` calls this
    /// directly when Spotify is the active service.
    func seekSpotify(toPositionMs positionMs: Int) async throws {
        let deviceId = try await ensureActiveDevice()
        try await authenticatedCommand(
            path: "/me/player/seek",
            queryItems: [
                URLQueryItem(name: "position_ms", value: String(positionMs)),
                URLQueryItem(name: "device_id", value: deviceId),
            ]
        )
    }

    /// `GET /me/player` — the poll target `PlayerViewModel` uses in place of
    /// a push callback (Spotify's Web API has none) for progress and
    /// end-of-track detection. Returns `nil` when nothing is playing
    /// anywhere on the account (a 204 No Content with an empty body).
    func fetchPlaybackState() async throws -> SpotifyPlaybackState? {
        let request = try authenticatedURLRequest(method: .get, path: "/me/player", queryItems: [])
        let data = try await sendWithRetry(request)
        guard !data.isEmpty, let dto = try? JSONDecoder.spotify.decode(SpotifyPlaybackStateDTO.self, from: data) else {
            return nil
        }
        return SpotifyPlaybackState(
            isPlaying:  dto.isPlaying,
            progressMs: dto.progressMs ?? 0,
            durationMs: dto.item?.durationMs ?? 0,
            trackUri:   dto.item?.uri,
            deviceId:   dto.device?.id
        )
    }

    /// Ensures there's an active Spotify Connect device to target, returning
    /// its id. Checks `GET /me/player` first (already-active device); if
    /// none, lists `GET /me/player/devices` and picks whichever device is
    /// marked `is_active` (falling back to the first entry if none are),
    /// transferring playback to it (`play: false` — the caller issues an
    /// actual `play` command separately). No device-picker UI for v1: a user
    /// with 2+ simultaneous devices and none currently active gets whichever
    /// comes first from Spotify's own list ordering.
    ///
    /// **Retries an empty device list up to twice more**, at increasing
    /// delays (1.0s, then 2.0s): a backgrounded, idle Spotify instance can
    /// transiently drop off Connect's device list for a beat before
    /// reappearing — confirmed on-device (worked once right after opening
    /// Spotify, then failed moments later with an empty list while Spotify
    /// was still running in the background). Widened from a single 1.5s
    /// retry after that one-shot window proved too short for longer idle
    /// gaps. This still doesn't fix Spotify being fully suspended by iOS,
    /// only papers over a momentary registration gap — see
    /// `PlayerViewModel.retryAfterSpotifyDeviceRecovery()` for the
    /// complementary recovery path once this genuinely gives up.
    private func ensureActiveDevice() async throws -> String {
        if let state = try? await fetchPlaybackState(), let deviceId = state.deviceId, !deviceId.isEmpty {
            return deviceId
        }

        var devices = try await authenticatedRequest(
            path: "/me/player/devices", decoding: SpotifyDevicesResponseDTO.self
        ).devices
        let retryDelaysNanoseconds: [UInt64] = [1_000_000_000, 2_000_000_000]
        for delay in retryDelaysNanoseconds where devices.isEmpty {
            try? await Task.sleep(nanoseconds: delay)
            devices = (try? await authenticatedRequest(
                path: "/me/player/devices", decoding: SpotifyDevicesResponseDTO.self
            ).devices) ?? []
        }

        let chosen = devices.first(where: { $0.isActive == true }) ?? devices.first
        guard let device = chosen, let deviceId = device.id, !deviceId.isEmpty else {
            throw SpotifyServiceError.noActiveDevice
        }
        try await authenticatedCommand(path: "/me/player", jsonBody: ["device_ids": [deviceId], "play": false])
        return deviceId
    }

    /// Maps a generic `Song` (which may be Apple-Music-sourced, from a
    /// legacy post, or freshly searched) onto a real Spotify track. Tries
    /// direct ID first, then a catalog-backed ISRC bridge, then title+artist
    /// text search — mirrors `AppleMusicService.resolve()`'s exact cascade
    /// shape. This is what makes "any song plays on whichever service is
    /// active, regardless of source" real for Spotify.
    ///
    /// **Feed-sourced songs almost always arrive with `isrc == nil`** —
    /// `Song.from(post:)` doesn't carry it (the shared `tracks/{catalogId}`
    /// catalog is the single source of truth for metadata like ISRC per this
    /// project's normalization convention, not per-post duplication — see
    /// CLAUDE.md's "Track metadata NORMALIZED" decision). Without step 2
    /// below, every Feed tap would skip straight to the fuzzier text search,
    /// which is why Spotify playback was inconsistent (worked for some
    /// tracks, "couldn't find" for others) rather than uniformly broken.
    private func resolve(_ song: NodalongKit.Song) async throws -> SpotifyTrackDTO {
        // Tracks the most specific real failure seen across the cascade — a
        // genuine transport/platform error (403 forbidden, 401 unauthorized,
        // 429 rate limited, 5xx) is far more actionable than "no match at
        // this step," so it's what gets thrown at the end instead of always
        // collapsing to `.notFound`. Only set from actual Spotify API calls
        // (not the Firestore catalog lookup below, which is unrelated to
        // Spotify's own health).
        var lastRealError: SpotifyServiceError?

        if song.sourceService == .spotify, !song.trackId.isEmpty {
            do {
                return try await getTrack(id: song.trackId)
            } catch {
                print("[Nodalong.SpotifyResolve] direct id lookup failed (\(song.trackId)): \(error)")
                lastRealError = error as? SpotifyServiceError
            }
        }

        // Catalog backfill: if this song has a shared catalog row, prefer
        // whatever cross-service identity it already carries — a Spotify id
        // some other Spotify-linked user already resolved for this exact
        // ISRC (fastest, most reliable, skips search entirely), or at least
        // its ISRC if this Song arrived without one.
        var isrc = song.isrc
        if let catalogId = song.catalogId, !catalogId.isEmpty {
            do {
                if let catalogTrack = try await getCatalogTrack(catalogId: catalogId) {
                    if let knownId = catalogTrack.spotifyTrackId, !knownId.isEmpty {
                        do {
                            return try await getTrack(id: knownId)
                        } catch {
                            print("[Nodalong.SpotifyResolve] catalog-known id lookup failed (\(knownId)): \(error)")
                            lastRealError = error as? SpotifyServiceError
                        }
                    }
                    if isrc == nil || isrc?.isEmpty == true {
                        isrc = catalogTrack.isrc
                    }
                }
            } catch {
                print("[Nodalong.SpotifyResolve] catalog lookup failed (\(catalogId)): \(error)")
            }
        }

        if let isrc, !isrc.isEmpty {
            do {
                if let result = try await searchByIsrc(isrc, preferAlbum: song.album), !result.trackId.isEmpty {
                    return try await getTrack(id: result.trackId)
                }
                print("[Nodalong.SpotifyResolve] ISRC search returned no match (\(isrc))")
            } catch {
                print("[Nodalong.SpotifyResolve] ISRC search failed (\(isrc)): \(error)")
                lastRealError = error as? SpotifyServiceError
            }
        }

        // Tiered text-search fallback: Spotify's `track:`/`artist:` field
        // search is fairly literal, so a raw title carrying a suffix like
        // "(feat. X)" or "- Remastered 2011", or a multi-artist string like
        // "Drake, Future", can return zero results even when the track
        // genuinely exists under a cleaner title. Each tier is only tried
        // when the previous one came back with nothing AND its inputs
        // actually differ from what was just tried — tracks that already
        // resolve on the raw pair hit exactly one search call, unchanged
        // from before. See `NodalongKit`'s `SearchQueryNormalization.swift`.
        let cleanedTitle = stripSearchNoise(song.title)
        let leadArtist = primaryArtist(song.artist)
        var triedPairs = Set<String>()
        let candidates: [(title: String, artist: String)] = [
            (song.title, song.artist),
            (cleanedTitle, song.artist),
            (cleanedTitle, leadArtist),
        ]
        for candidate in candidates {
            let key = "\(candidate.title)|\(candidate.artist)"
            guard !candidate.title.isEmpty, !candidate.artist.isEmpty, triedPairs.insert(key).inserted else { continue }
            do {
                if let result = try await searchByTitleArtist(title: candidate.title, artist: candidate.artist, preferAlbum: song.album), !result.trackId.isEmpty {
                    return try await getTrack(id: result.trackId)
                }
                print("[Nodalong.SpotifyResolve] text search returned no match ('\(candidate.title)' by '\(candidate.artist)')")
            } catch {
                print("[Nodalong.SpotifyResolve] text search failed ('\(candidate.title)' by '\(candidate.artist)'): \(error)")
                lastRealError = error as? SpotifyServiceError
            }
        }

        throw lastRealError ?? SpotifyServiceError.notFound
    }

    private func getTrack(id: String) async throws -> SpotifyTrackDTO {
        try await authenticatedRequest(path: "/tracks/\(id)", decoding: SpotifyTrackDTO.self)
    }

    // MARK: - Search

    func searchTracks(_ query: String, maxResults: Int) async throws -> [NodalongKit.Song] {
        let dto: SpotifySearchResponseDTO = try await authenticatedRequest(
            path: "/search",
            queryItems: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "type", value: "track"),
                URLQueryItem(name: "limit", value: String(maxResults)),
            ],
            decoding: SpotifySearchResponseDTO.self
        )
        return (dto.tracks?.items ?? []).compactMap { Self.toSong($0) }
    }

    func searchArtists(_ query: String, maxResults: Int) async throws -> [ArtistResult] {
        let dto: SpotifySearchResponseDTO = try await authenticatedRequest(
            path: "/search",
            queryItems: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "type", value: "artist"),
                URLQueryItem(name: "limit", value: String(maxResults)),
            ],
            decoding: SpotifySearchResponseDTO.self
        )
        return (dto.artists?.items ?? []).compactMap { Self.toArtistResult($0) }
    }

    func searchAlbums(_ query: String, maxResults: Int) async throws -> [AlbumResult] {
        let dto: SpotifySearchResponseDTO = try await authenticatedRequest(
            path: "/search",
            queryItems: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "type", value: "album"),
                URLQueryItem(name: "limit", value: String(maxResults)),
            ],
            decoding: SpotifySearchResponseDTO.self
        )
        return (dto.albums?.items ?? []).compactMap { Self.toAlbumResult($0) }
    }

    /// No direct by-ISRC resource endpoint (unlike Apple's
    /// `matching: \.isrc`) — Spotify's search supports an `isrc:` field
    /// filter instead. Protocol-facing entry point — no album preference,
    /// see the internal `searchByIsrc(_:preferAlbum:)` overload used by
    /// `resolve(_:)`, which does.
    func searchByIsrc(_ isrc: String) async throws -> SearchResult? {
        try await searchByIsrc(isrc, preferAlbum: nil)
    }

    /// Same lookup as `searchByIsrc(_:)`, but scores multiple candidates
    /// against `preferAlbum` (when known) instead of blindly taking the
    /// first Spotify search result — an ISRC can match several releases
    /// (original album, deluxe reissue, "Greatest Hits" compilation). See
    /// `NodalongKit`'s `ReleaseMatching.swift`. `preferAlbum == nil`
    /// (the protocol-facing `searchByIsrc(_:)`) falls back to a compilation-
    /// keyword-only preference, same principle as before but no longer
    /// literally unfiltered.
    private func searchByIsrc(_ isrc: String, preferAlbum: String?) async throws -> SearchResult? {
        let dto: SpotifySearchResponseDTO = try await authenticatedRequest(
            path: "/search",
            queryItems: [
                URLQueryItem(name: "q", value: "isrc:\(isrc)"),
                URLQueryItem(name: "type", value: "track"),
                URLQueryItem(name: "limit", value: "10"),
            ],
            decoding: SpotifySearchResponseDTO.self
        )
        guard let tracks = dto.tracks?.items, !tracks.isEmpty else { return nil }
        let idx = bestReleaseIndex(albumNames: tracks.map { $0.album?.name ?? "" }, expectedAlbum: preferAlbum) ?? 0
        let track = tracks[idx]
        return SearchResult(uri: track.uri, trackId: track.id, isrc: track.externalIds?.isrc ?? isrc)
    }

    func searchByTitleArtist(title: String, artist: String) async throws -> SearchResult? {
        try await searchByTitleArtist(title: title, artist: artist, preferAlbum: nil)
    }

    private func searchByTitleArtist(title: String, artist: String, preferAlbum: String?) async throws -> SearchResult? {
        let dto: SpotifySearchResponseDTO = try await authenticatedRequest(
            path: "/search",
            queryItems: [
                URLQueryItem(name: "q", value: "track:\(title) artist:\(artist)"),
                URLQueryItem(name: "type", value: "track"),
                URLQueryItem(name: "limit", value: "10"),
            ],
            decoding: SpotifySearchResponseDTO.self
        )
        guard let tracks = dto.tracks?.items, !tracks.isEmpty else { return nil }
        let idx = bestReleaseIndex(albumNames: tracks.map { $0.album?.name ?? "" }, expectedAlbum: preferAlbum) ?? 0
        let track = tracks[idx]
        return SearchResult(uri: track.uri, trackId: track.id, isrc: track.externalIds?.isrc)
    }

    func searchAll(
        _ query: String,
        maxPerType: Int
    ) async throws -> (artists: [ArtistResult], albums: [AlbumResult], tracks: [NodalongKit.Song]) {
        let dto: SpotifySearchResponseDTO = try await authenticatedRequest(
            path: "/search",
            queryItems: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "type", value: "artist,album,track"),
                URLQueryItem(name: "limit", value: String(maxPerType)),
            ],
            decoding: SpotifySearchResponseDTO.self
        )
        return (
            artists: (dto.artists?.items ?? []).compactMap { Self.toArtistResult($0) },
            albums:  (dto.albums?.items ?? []).compactMap  { Self.toAlbumResult($0) },
            tracks:  (dto.tracks?.items ?? []).compactMap  { Self.toSong($0) }
        )
    }

    // MARK: - Browse

    func getArtistAlbums(artistId: String) async throws -> [AlbumResult] {
        guard !artistId.isEmpty else { return [] }
        let dto: SpotifyPagingDTO<SpotifyAlbumDTO> = try await authenticatedRequest(
            path: "/artists/\(artistId)/albums",
            decoding: SpotifyPagingDTO<SpotifyAlbumDTO>.self
        )
        return dto.items.compactMap { Self.toAlbumResult($0) }
    }

    /// Beyond the base `MusicService` protocol — added for parity with
    /// `AppleMusicService`, which has it (used by artist-detail "Top Songs").
    func getArtistTopTracks(artistId: String) async throws -> [NodalongKit.Song] {
        guard !artistId.isEmpty else { return [] }
        let dto: SpotifyArtistTopTracksResponseDTO = try await authenticatedRequest(
            path: "/artists/\(artistId)/top-tracks",
            decoding: SpotifyArtistTopTracksResponseDTO.self
        )
        return dto.tracks.compactMap { Self.toSong($0) }
    }

    /// `/v1/albums/{id}/tracks` returns simplified track objects with no
    /// nested album or `external_ids.isrc` — the caller-supplied
    /// `albumName`/`artwork` fill that gap, exactly like
    /// `AppleMusicService.getAlbumTracks` already does for the same reason.
    func getAlbumTracks(
        albumId: String,
        albumName: String,
        artwork: String
    ) async throws -> [NodalongKit.Song] {
        guard !albumId.isEmpty else { return [] }
        let dto: SpotifyPagingDTO<SpotifyTrackDTO> = try await authenticatedRequest(
            path: "/albums/\(albumId)/tracks",
            decoding: SpotifyPagingDTO<SpotifyTrackDTO>.self
        )
        return dto.items.compactMap { Self.toSong($0, overrideAlbum: albumName, overrideArtwork: artwork) }
    }

    // MARK: - DTO → NodalongKit conversion

    /// Returns `nil` for empty-identifier records, matching
    /// `AppleMusicService.toSong`'s contract — callers `compactMap`.
    private static func toSong(
        _ dto: SpotifyTrackDTO,
        listenedAt: Double? = nil,
        overrideAlbum: String? = nil,
        overrideArtwork: String? = nil
    ) -> NodalongKit.Song? {
        guard !dto.id.isEmpty else { return nil }
        // Spotify's `images[]` is ordered largest-first, so `.first` is the
        // largest available — opposite convention from Apple's
        // `Artwork.url(width:height:)`, which requests a specific size.
        let artwork = overrideArtwork?.nonEmpty ?? (dto.album?.images?.first?.url ?? "")
        let album   = overrideAlbum?.nonEmpty ?? (dto.album?.name ?? "")
        return NodalongKit.Song(
            id:               dto.id,
            title:            dto.name,
            artist:           dto.artists?.first?.name ?? "",
            album:            album,
            artwork:          artwork,
            trackId:          dto.id,
            uri:              dto.uri,
            listenedAt:       listenedAt,
            sourceService:    .spotify,
            isrc:             dto.externalIds?.isrc,
            duration:         dto.durationMs,
            trackNumber:      dto.trackNumber,
            albumReleaseDate: dto.album?.releaseDate
        )
    }

    private static func toArtistResult(_ dto: SpotifyArtistDTO) -> ArtistResult? {
        guard !dto.id.isEmpty else { return nil }
        return ArtistResult(
            id:            dto.id,
            name:          dto.name,
            imageUrl:      dto.images?.first?.url ?? "",
            genres:        (dto.genres ?? []).joined(separator: ", "),
            followers:     dto.followers?.total ?? 0,
            sourceService: .spotify
        )
    }

    private static func toAlbumResult(_ dto: SpotifyAlbumDTO) -> AlbumResult? {
        guard !dto.id.isEmpty else { return nil }
        return AlbumResult(
            id:            dto.id,
            name:          dto.name,
            artistName:    dto.artists?.first?.name ?? "",
            artwork:       dto.images?.first?.url ?? "",
            releaseDate:   dto.releaseDate ?? "",
            totalTracks:   dto.totalTracks ?? 0,
            albumType:     dto.albumType ?? "album",
            sourceService: .spotify
        )
    }

    // MARK: - Constants

    private static let clientId    = "19444d59f4a146cabf5eb29269e5c491"
    // NOT `com.bigdeccyh.nodalong://` — confirmed on-device (2026-07-11) that
    // Spotify's Dashboard now rejects a bare `scheme://` with nothing after
    // it ("One or more of your redirect URIs are not valid"), even though the
    // RN app originally registered exactly that. `.../callback` is the other
    // URI already registered for this Client ID and is the one Spotify
    // actually accepts.
    private static let redirectURI = "com.bigdeccyh.nodalong://callback"
    // `user-modify-playback-state`/`user-read-playback-state` added for
    // Stage B (real playback) — Spotify scopes are locked at consent time,
    // so any already-connected account needs to disconnect + reconnect once
    // this ships to actually be granted these.
    private static let scopes: [String] = [
        "user-read-private",
        "user-library-read",
        "user-read-recently-played",
        "user-modify-playback-state",
        "user-read-playback-state",
    ]
}

/// Snapshot of `GET /me/player` — the poll target `PlayerViewModel` uses for
/// progress/end-of-track detection while Spotify is the active service
/// (Spotify's Web API has no push/callback mechanism).
struct SpotifyPlaybackState {
    let isPlaying: Bool
    let progressMs: Int
    let durationMs: Int
    let trackUri: String?
    let deviceId: String?
}

// MARK: - Errors

enum SpotifyServiceError: LocalizedError {
    case unauthorized
    case forbidden
    case notFound
    case rateLimited(retryAfterSeconds: Int)
    case server(statusCode: Int)
    case network(Error)
    case decoding(Error)
    case authCancelled(Error?)
    case authCallbackMalformed
    case notImplemented
    /// No Spotify Connect device is active anywhere on the account, and none
    /// could be auto-selected from `GET /me/player/devices` (empty list).
    /// Distinct from a per-track failure: retrying the *next* queued track
    /// won't help, since the same "nothing to play on" problem applies to
    /// every track equally until the user opens Spotify somewhere.
    case noActiveDevice
    case unknown(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .unauthorized:          return "Spotify session expired. Please reconnect."
        case .forbidden:             return "Spotify denied this request."
        case .notFound:              return "Couldn't find this on Spotify."
        case .rateLimited:           return "Too many requests to Spotify. Try again shortly."
        case .server:                return "Spotify is temporarily unavailable."
        case .network:               return "Network error reaching Spotify."
        case .decoding:              return "Unexpected response from Spotify."
        case .authCancelled:         return "Spotify sign-in was cancelled."
        case .authCallbackMalformed: return "Spotify sign-in failed. Please try again."
        case .notImplemented:        return "Not yet supported for Spotify."
        case .noActiveDevice:        return "Open Spotify on a device, then try again."
        case .unknown:               return "Something went wrong with Spotify."
        }
    }
}

// MARK: - PKCE

/// Pure, stateless PKCE helpers — no library equivalent to `expo-auth-session`
/// exists in plain Swift, so this is hand-rolled per RFC 7636.
private enum PKCE {
    private static let unreservedChars = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// 128-character `code_verifier` drawn from the RFC 7636 unreserved
    /// charset, backed by `SecRandomCopyBytes` (a CSPRNG — this is a security
    /// token, not `arc4random`).
    static func generateCodeVerifier(length: Int = 128) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return String(bytes.map { unreservedChars[Int($0) % unreservedChars.count] })
    }

    /// `code_challenge` = base64url(SHA256(code_verifier)), no padding.
    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    /// Opaque CSRF-protection value compared against the authorize
    /// callback's `state` query param.
    static func generateState() -> String {
        generateCodeVerifier(length: 32)
    }
}

private extension Data {
    /// Standard base64 → base64url per RFC 4648 §5.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Token model

/// Thin Keychain-backed value type for the current token set. Account keys
/// are hardcoded (single-account-per-device) — this app has no Firebase-
/// account-switching UI to conflict with that assumption.
private struct SpotifyTokenSet {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    enum Keys {
        static let accessToken  = "spotify_access_token"
        static let refreshToken = "spotify_refresh_token"
        static let expiresAt    = "spotify_expires_at"
    }

    static func loadFromKeychain() -> SpotifyTokenSet? {
        guard
            let access = KeychainHelper.get(account: Keys.accessToken),
            let refresh = KeychainHelper.get(account: Keys.refreshToken),
            let expiresAtRaw = KeychainHelper.get(account: Keys.expiresAt),
            let expiresAtEpoch = Double(expiresAtRaw)
        else { return nil }
        return SpotifyTokenSet(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date(timeIntervalSince1970: expiresAtEpoch)
        )
    }

    func saveToKeychain() {
        KeychainHelper.set(accessToken, account: Keys.accessToken)
        KeychainHelper.set(refreshToken, account: Keys.refreshToken)
        KeychainHelper.set(String(expiresAt.timeIntervalSince1970), account: Keys.expiresAt)
    }
}

// MARK: - ASWebAuthenticationSession presentation context

/// `ASWebAuthenticationPresentationContextProviding` is an Objective-C
/// protocol requiring `NSObject` — kept as a separate, minimal delegate
/// rather than making the whole service an `NSObject` subclass.
private final class SpotifyAuthPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // `ASPresentationAnchor` is `UIWindow` on iOS; its bare `init()` is
        // deprecated in favor of `init(windowScene:)` — but this fallback only
        // runs when NO window scene was found, i.e. exactly the case with no
        // scene to construct one from, so there's no non-deprecated way to
        // build a placeholder anchor here. A wrapper marked
        // `@available(deprecated:)` was tried and does NOT suppress this —
        // Swift's deprecated-calling-deprecated leniency only covers uses
        // *inside* a deprecated declaration's own body, it doesn't extend to
        // callers of that declaration — so this is left as a plain, knowingly-
        // unavoidable warning on an effectively unreachable branch.
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}

// MARK: - Wire DTOs

private struct SpotifyImageDTO: Decodable {
    let url: String
}

private struct SpotifyFollowersDTO: Decodable {
    let total: Int?
}

private struct SpotifyArtistDTO: Decodable {
    let id: String
    let name: String
    let images: [SpotifyImageDTO]?
    let genres: [String]?
    let followers: SpotifyFollowersDTO?
}

private struct SpotifyAlbumDTO: Decodable {
    let id: String
    let name: String
    let images: [SpotifyImageDTO]?
    let releaseDate: String?
    let totalTracks: Int?
    let albumType: String?
    let artists: [SpotifyArtistDTO]?
}

private struct SpotifyExternalIdsDTO: Decodable {
    let isrc: String?
}

/// Spotify's "simplified track object" (nested inside an album's track
/// listing) omits `album`/`external_ids` — both decode as `nil` here, which
/// `toSong`'s override params + missing-ISRC handling already account for.
private struct SpotifyTrackDTO: Decodable {
    let id: String
    let name: String
    let uri: String
    let durationMs: Int?
    let trackNumber: Int?
    let externalIds: SpotifyExternalIdsDTO?
    let album: SpotifyAlbumDTO?
    let artists: [SpotifyArtistDTO]?
}

private struct SpotifyPagingDTO<Item: Decodable>: Decodable {
    let items: [Item]
}

private struct SpotifySearchResponseDTO: Decodable {
    let tracks: SpotifyPagingDTO<SpotifyTrackDTO>?
    let artists: SpotifyPagingDTO<SpotifyArtistDTO>?
    let albums: SpotifyPagingDTO<SpotifyAlbumDTO>?
}

private struct SpotifySavedTrackDTO: Decodable {
    let track: SpotifyTrackDTO
}

private struct SpotifyPlayHistoryDTO: Decodable {
    let track: SpotifyTrackDTO
    let playedAt: String?
}

private struct SpotifyArtistTopTracksResponseDTO: Decodable {
    let tracks: [SpotifyTrackDTO]
}

private struct SpotifyTokenResponseDTO: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
}

private struct SpotifyMeDTO: Decodable {
    let id: String
    let displayName: String?
}

private struct SpotifyPlaybackStateDTO: Decodable {
    let isPlaying: Bool
    let progressMs: Int?
    let item: SpotifyTrackDTO?
    let device: SpotifyDeviceDTO?
}

private struct SpotifyDeviceDTO: Decodable {
    let id: String?
    let isActive: Bool?
}

private struct SpotifyDevicesResponseDTO: Decodable {
    let devices: [SpotifyDeviceDTO]
}

// MARK: - Helpers

private extension JSONDecoder {
    static let spotify: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

private extension CharacterSet {
    /// `.urlQueryAllowed` minus the characters that are meaningful in a
    /// `application/x-www-form-urlencoded` body (`&`, `=`, `+`).
    static let urlQueryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return allowed
    }()
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

#if DEBUG
extension SpotifyMusicService {
    /// Authenticated-state instance for SwiftUI previews. No network calls —
    /// just flips `isAuthenticated` so views render the post-auth path.
    static var mockPreview: SpotifyMusicService {
        let svc = SpotifyMusicService()
        svc.isAuthenticated = true
        return svc
    }
}
#endif
