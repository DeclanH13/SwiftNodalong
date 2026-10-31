import Foundation
import NodalongKit

/// Builds playlists out of what *real people* are listening to.
///
/// Nodalong's differentiator is people, not algorithms (see CLAUDE.md §1), so
/// this deliberately isn't a recommender competing with Apple Music — it can't
/// win that fight and shouldn't try. Instead every playlist has a premise you
/// can say out loud ("people near you are playing this"), and every track is
/// credited to a named person. That's the part Apple and Spotify structurally
/// cannot copy: they don't have your follow graph.
///
/// **One engine, four people-lenses.** A `PlaylistLens` only decides *which
/// pool of people* to draw from and *how to skew* them; ranking, scoring and
/// selection are shared and live as pure, unit-tested functions in NodalongKit
/// (`TasteAffinity.swift`, `PlaylistGeneration.swift`).
///
/// **`.taste` is the exception, and knowingly so.** It is sourced from the
/// catalog rather than from people, which is the direction this file's own
/// comment above argues against. It earns its place by weighting signals Apple
/// cannot see — what you chose to spotlight (capped at 3/day) and what you kept
/// on your Shelf — and by excluding everything you have already heard, which
/// Apple's own recommendations do not. It runs through `runTaste`, deliberately
/// NOT through `run`: the two pipelines share a shape but nothing else, and
/// forcing them together would tangle both.
///
/// **Two stages, because reads cost money.** Stage 1 ranks the pool using data
/// that is already in memory or free to fetch, and only the top
/// `deepFetchLimit` people get the expensive stage-2 fetch. Fanning out over
/// every follow would be thousands of reads per generation. This mirrors the
/// `.prefix(6)` politeness cap the prefetch work already established.
@MainActor
final class PlaylistGenerator: ObservableObject {

    /// How many people get the expensive stage-2 bundle fetch. Over-selected
    /// past what's strictly needed, because someone whose taste we already fully
    /// own contributes zero new candidates and silently drops out.
    private let deepFetchLimit = 8

    /// Radius for the `nearby` lens, matching NearMe's own default.
    private let nearbyRadiusKm: Double = 10.0

    /// Generated playlists refresh every Monday: a playlist last built before
    /// the most recent Monday 00:00 (local time) is rebuilt the next time Home is
    /// looked at. `Playlist.updatedAt` already tracks this — no new field.
    static func lastMondayStartMs(now: Date = Date()) -> Double {
        var cal = Calendar.current
        cal.firstWeekday = 2   // Monday
        let start = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        return start.timeIntervalSince1970 * 1000
    }

    /// A playlist whose automatic rebuild was attempted more recently than this
    /// isn't retried. Without it a lens that keeps failing (or finds nothing,
    /// so `updatedAt` never moves) would retry on every Home appearance and
    /// quietly burn ~1,000 reads each time. Device-local, in `UserDefaults`.
    private static let retryAfter: TimeInterval = 6 * 60 * 60

    private var autoPassRunning = false

    /// Bump when the generation logic changes in a way that makes existing
    /// playlists wrong (not merely stale). Every generated playlist is then
    /// rebuilt once, ignoring the Monday schedule — otherwise a fix would sit
    /// unseen until next Monday, since there is no manual refresh.
    /// 2: genre runs judge artists by overall tags (Frank Ocean in "Rock").
    private static let algorithmVersion = 6
    /// A genre discovery list shorter than this is not published (one came out
    /// at 3 tracks).
    static let minGenrePlaylistSize = 15

    private static func recentSuggestedKey(_ uid: String) -> String { "nodalong.recentSuggested.\(uid)" }

    /// Normalized artist key → epoch seconds it was last suggested. Device-local.
    static func loadRecentSuggestions(uid: String) -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: recentSuggestedKey(uid)) as? [String: Double] ?? [:]
    }

    static func recordSuggestions(uid: String, keys: Set<String>) {
        let now = Date().timeIntervalSince1970
        var all = loadRecentSuggestions(uid: uid).filter { now - $0.value < 60 * 86_400 }   // prune old
        for k in keys where !k.isEmpty { all[k] = now }
        UserDefaults.standard.set(all, forKey: recentSuggestedKey(uid))
    }

    private static func algorithmKey(_ uid: String) -> String { "nodalong.genAlgoVersion.\(uid)" }

    /// Which tile — `lens.genre.variant` — so the retry guard is per tile whether
    /// the playlist exists yet or not.
    private static func attemptKey(lens: PlaylistLens, genre: String?, variant: String?, uid: String) -> String {
        "nodalong.genRefresh.\(uid).\(lens.rawValue).\(genre ?? "-").\(variant ?? "-")"
    }

    private func recentlyAttempted(lens: PlaylistLens, genre: String?, variant: String?, uid: String) -> Bool {
        let last = UserDefaults.standard.double(forKey: Self.attemptKey(lens: lens, genre: genre, variant: variant, uid: uid))
        return last > 0 && Date().timeIntervalSince1970 - last < Self.retryAfter
    }

    private func markAttempt(lens: PlaylistLens, genre: String?, variant: String?, uid: String) {
        UserDefaults.standard.set(Date().timeIntervalSince1970,
                                  forKey: Self.attemptKey(lens: lens, genre: genre, variant: variant, uid: uid))
    }

    @Published private(set) var generating: Set<PlaylistLens> = []
    @Published var errorMessage: String?

    /// Set when a run finished but produced nothing, so the UI can explain why
    /// rather than showing an empty playlist.
    @Published var emptyReason: String?

    func isGenerating(_ lens: PlaylistLens) -> Bool { generating.contains(lens) }

    /// Sentinel for the un-scoped taste run, so `tasteBusyKey` can be a plain
    /// `String?` rather than a second optional layer.
    static let generalTasteKey = "__general__"

    /// Which taste run is in flight — a genre name, `generalTasteKey`, or nil.
    @Published private(set) var tasteBusyKey: String?

    /// True only for the specific taste tile that's building, so tapping the
    /// hip-hop tile doesn't grey out the general one and vice versa.
    func isGeneratingTaste(genre: String?) -> Bool {
        tasteBusyKey == (genre ?? Self.generalTasteKey)
    }

    // MARK: - Entry point

    /// Generates (or regenerates in place) the playlist for `lens`.
    /// Returns the playlist id, or nil if there wasn't enough to build one.
    @discardableResult
    func generate(
        lens: PlaylistLens,
        me: UserProfile,
        myLibrary: [LibraryTrackDoc],
        myGeohash: String?
    ) async -> String? {
        guard !generating.contains(lens) else { return nil }
        generating.insert(lens)
        errorMessage = nil
        emptyReason = nil
        defer { generating.remove(lens) }

        do {
            return try await run(lens: lens, me: me, myLibrary: myLibrary, myGeohash: myGeohash)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            print("[Nodalong.Generator] \(lens.rawValue) failed: \(error)")
            return nil
        }
    }

    private func run(
        lens: PlaylistLens,
        me: UserProfile,
        myLibrary: [LibraryTrackDoc],
        myGeohash: String?
    ) async throws -> String? {

        // --- My own taste, and everything I've already heard -----------------
        let myRecents = (try? await getYourMusicFeed(uid: me.uid)) ?? []

        var mine = TasteProfile.from(library: myLibrary)
        mine = mine.merging(.from(posts: myRecents))
        mine = mine.merging(.from(spotlights: me.spotlightTracks))

        guard !mine.isEmpty else {
            emptyReason = "We need to know what you listen to first. Play some music and try again."
            return nil
        }

        // A generated playlist that hands back tracks you already have is
        // worthless, so this exclusion set is the feature, not an optimisation.
        var heard = Set(myLibrary.map(\.catalogId))
        for p in myRecents { heard.insert(p.catalogId) }
        for s in me.spotlightTracks { if let c = s.catalogId { heard.insert(c) } }

        // --- Stage 1: rank the lens's pool (cheap) ---------------------------
        let pool = try await candidatePool(lens: lens, me: me, myGeohash: myGeohash)
        guard !pool.isEmpty else {
            emptyReason = Self.emptyPoolMessage(for: lens)
            return nil
        }

        let ranked = rankPeople(mine: mine, candidates: pool, limit: deepFetchLimit)
        guard !ranked.isEmpty else {
            emptyReason = "Nobody's taste lines up with yours yet. Follow a few more people."
            return nil
        }

        // --- Stage 2: deep-fetch only the top matches (bounded) --------------
        // Routed through SocialCache deliberately: it's the same cache profile
        // browsing fills, so anyone recently viewed is free, and the blend lens
        // rides on whatever the single-lens runs already warmed.
        // Fan out concurrently: awaiting these in series cost 8x network
        // latency for no reason. `SocialCache` is an actor with in-flight
        // sharing, so parallel calls are safe and a person already being
        // fetched is joined rather than re-fetched.
        let viewerUid = me.uid
        var contributions: [TrackContribution] = []

        await withTaskGroup(of: [TrackContribution].self) { group in
            for person in ranked {
                group.addTask {
                    let bundle = await SocialCache.shared.bundle(uid: person.uid, viewerUid: viewerUid)
                    return Self.contributions(from: bundle, person: person)
                }
            }
            for await theirs in group { contributions.append(contentsOf: theirs) }
        }

        // --- Stage 3: score and select (pure, tested) ------------------------
        let selected = selectTracks(
            contributions: contributions,
            excluding: heard,
            signalWeights: lens.signalWeights
        )
        guard !selected.isEmpty else {
            emptyReason = "You've already heard everything your matches are playing. Try again later."
            return nil
        }

        // --- Stage 4: resolve metadata and write ----------------------------
        let catalog = await CatalogCache.shared.metadata(for: selected.map(\.catalogId))

        // Always .appleMusic: Spotify entry points were removed (CLAUDE.md
        // 2026-07-17), so there is no other service a generated track can come
        // from today. Playback still resolves cross-service via ISRC if that
        // ever changes.
        let tracks = selected.map { t in
            (
                catalogId: t.catalogId,
                addedByUid: t.addedByUid,
                addedByUsername: t.addedByUsername,
                sourceService: MusicServiceType.appleMusic
            )
        }

        let cover = selected
            .compactMap { catalog[$0.catalogId]?.artwork }
            .first { !$0.isEmpty } ?? ""

        // Ordered best-first, deduped — used for both the guard below and the
        // description, which now names people instead of counting them.
        var contributorNames: [String] = []
        var usedContributors = Set<String>()
        for t in selected where !usedContributors.contains(t.addedByUid) {
            usedContributors.insert(t.addedByUid)
            contributorNames.append(t.addedByUsername)
        }

        // A blend of one person is not a blend — it is whichever single-source
        // lens already covers them, under a name that implies more. Say so
        // rather than writing a fourth copy of the same playlist.
        if lens == .blend, usedContributors.count < 2 {
            emptyReason = "Your blend needs a few more people. Follow someone new, or open Near Me to find listeners around you."
            return nil
        }

        return try await upsertGeneratedPlaylist(
            ownerUid: me.uid,
            ownerUsername: me.username,
            ownerAvatarEmoji: me.avatarEmoji,
            ownerAvatarColor: me.avatarColor,
            lens: lens,
            description: Self.describe(lens: lens, contributors: contributorNames),
            coverArtwork: cover,
            tracks: tracks
        )
    }

    // MARK: - Taste lens (catalog-sourced)

    /// How many of my own artists seed the expansion. Past roughly this many
    /// the tail is background listening rather than taste, and every extra seed
    /// costs two MusicKit round trips.
    private let tasteSeedLimit = 8

    /// How many discovered artists get their top songs fetched. 12 × ~10 tracks
    /// is a deep enough pool to fill 25 slots under a 2-per-artist cap with room
    /// for the heard-exclusion to bite.
    private let tasteCandidateArtistLimit = 40

    /// How much of the user's Apple Music library to read per taste run.
    ///
    /// A device-local read, so paging costs no network — but it is held in
    /// memory for the run and every track contributes to the artist and
    /// genre weighting, so it is bounded rather than unlimited. 500 covers a
    /// substantial library without the whole thing being resident.
    private let appleLibrarySeedLimit = 500

    /// Which catalog-sourced playlist to build. All of them share one pipeline
    /// (seeds → candidates → `selectTasteTracks` → write) and differ only in
    /// where candidate artists and tracks come from.
    enum CatalogMode: Hashable {
        /// New artists next to what you play, optionally limited to a genre.
        case discovery(genre: String?)
        /// Tracks you haven't heard, from the artists you already love.
        case deepCuts
        /// Recent releases from artists similar to yours.
        case newFromSimilar
        /// Discovery seeded from ONE of your artists.
        case becauseArtist(key: String, name: String)

        var lens: PlaylistLens {
            switch self {
            case .discovery:       return .taste
            case .deepCuts:        return .deepCuts
            case .newFromSimilar:  return .newFromSimilar
            case .becauseArtist:   return .becauseArtist
            }
        }
        var genre: String? { if case .discovery(let g) = self { return g }; return nil }
        var variant: String? { if case .becauseArtist(_, let n) = self { return n }; return nil }

        /// Identifies which tile is building. "§"-prefixed so it can't collide
        /// with a genre name.
        var busyKey: String {
            switch self {
            case .discovery(let g):          return g ?? PlaylistGenerator.generalTasteKey
            case .deepCuts:                  return "§deep"
            case .newFromSimilar:            return "§new"
            case .becauseArtist(let k, _):   return "§artist:\(k)"
            }
        }

        /// The mode a stored generated playlist was built with, for the Monday
        /// rebuild. `nil` for people-lenses.
        static func of(_ p: Playlist) -> CatalogMode? {
            switch p.lens {
            case .taste:          return .discovery(genre: p.genre)
            case .deepCuts:       return .deepCuts
            case .newFromSimilar: return .newFromSimilar
            case .becauseArtist:
                guard let name = p.variant else { return nil }
                return .becauseArtist(key: primaryArtist(name).lowercased(), name: name)
            default:              return nil
            }
        }
    }

    /// Generates the catalog-sourced taste playlist (general or one genre).
    @discardableResult
    func generateTaste(
        me: UserProfile,
        myLibrary: [LibraryTrackDoc],
        musicService: AppleMusicService,
        reshuffle: Bool = true,
        genre: String? = nil,
        weeklySeed: Bool = false
    ) async -> String? {
        await generateCatalog(
            mode: .discovery(genre: genre), me: me, myLibrary: myLibrary,
            musicService: musicService, reshuffle: reshuffle, weeklySeed: weeklySeed
        )
    }

    /// Generates any catalog-sourced playlist.
    ///
    /// - `reshuffle`: `true` for an explicit user action (tapping a tile) —
    ///   draws a fresh random seed. `false` for the automatic Monday rebuild.
    /// - `weeklySeed`: the Monday rebuild. A constant per-user seed would return
    ///   an identical list every week while inputs are unchanged, so the week
    ///   number is mixed in — stable within a week, different next Monday.
    @discardableResult
    func generateCatalog(
        mode: CatalogMode,
        me: UserProfile,
        myLibrary: [LibraryTrackDoc],
        musicService: AppleMusicService,
        reshuffle: Bool = true,
        weeklySeed: Bool = false
    ) async -> String? {
        // One catalog run at a time — each is a real fan-out across artists, and
        // they share `emptyReason` / `errorMessage`, so overlapping runs would
        // report over each other. `tasteBusyKey` records WHICH one so only the
        // tapped tile shows a spinner.
        guard tasteBusyKey == nil else { return nil }
        tasteBusyKey = mode.busyKey
        generating.insert(mode.lens)
        errorMessage = nil
        emptyReason = nil
        defer {
            generating.remove(mode.lens)
            tasteBusyKey = nil
        }

        let day = UInt64(Self.lastMondayStartMs() / (7 * 86_400_000))
        let seed: UInt64 = reshuffle
            ? UInt64.random(in: UInt64.min...UInt64.max)
            : (weeklySeed ? Self.stableSeed(for: me.uid) ^ (day &* 0x9E37_79B9_7F4A_7C15)
                         : Self.stableSeed(for: me.uid))

        do {
            return try await runCatalog(mode: mode, me: me, myLibrary: myLibrary, musicService: musicService, shuffleSeed: seed)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            print("[Nodalong.Generator] \(mode.lens.rawValue) failed: \(error)")
            return nil
        }
    }

    /// True only for the specific catalog tile that's building.
    func isGeneratingCatalog(_ mode: CatalogMode) -> Bool { tasteBusyKey == mode.busyKey }

    /// Which of a candidate artist's albums to mine for deep cuts.
    ///
    /// Full-length albums only — a single or EP has no deep cuts by
    /// definition, and a compilation is the same hits this lens is already
    /// trying to avoid (filtered with the same `containsCompilationKeyword`
    /// list `getNewReleases` and `isBetterRelease` use, so "what counts as a
    /// compilation" stays defined in one place).
    ///
    /// Oldest first: an artist's earlier records are the ones a newcomer is
    /// least likely to have heard, and taking the newest would collide with
    /// whatever surfaced them in the first place. Ties break on id so a
    /// regeneration with an unchanged catalog picks the same albums — the
    /// seeded jitter is the only thing that should introduce variety.
    static func deepCutAlbums(from albums: [AlbumResult]) -> [AlbumResult] {
        albums
            .filter { $0.albumType == "album" && !containsCompilationKeyword($0.name) }
            .sorted { $0.releaseDate == $1.releaseDate ? $0.id < $1.id : $0.releaseDate < $1.releaseDate }
            .prefix(tasteAlbumsPerArtist)
            .map { $0 }
    }

    /// Albums to mine for tracks you haven't heard from an artist you already
    /// love — more of them than the discovery lens samples, since this is the
    /// whole point of the playlist. Full-length, non-compilation, oldest first.
    static func ownedDeepCutAlbums(from albums: [AlbumResult]) -> [AlbumResult] {
        albums
            .filter { $0.albumType == "album" && !containsCompilationKeyword($0.name) }
            .sorted { $0.releaseDate == $1.releaseDate ? $0.id < $1.id : $0.releaseDate < $1.releaseDate }
            .prefix(5)
            .map { $0 }
    }

    /// Releases from the last 60 days, already out, for "New From Artists Like Yours".
    static func recentReleases(from albums: [AlbumResult]) -> [AlbumResult] {
        albums
            .filter { !containsCompilationKeyword($0.name) && isRecentRelease($0.releaseDate, withinDays: 60) }
            .sorted { $0.releaseDate == $1.releaseDate ? $0.id < $1.id : $0.releaseDate > $1.releaseDate }
            .prefix(3)
            .map { $0 }
    }

    /// A per-user constant, so the weekly auto-refresh produces a stable
    /// ordering for a given person rather than reshuffling behind them.
    private static func stableSeed(for uid: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in uid.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    private func runCatalog(
        mode: CatalogMode,
        me: UserProfile,
        myLibrary: [LibraryTrackDoc],
        musicService: AppleMusicService,
        shuffleSeed: UInt64?
    ) async throws -> String? {

        // --- Stage 0: what I listen to, weighted (pure, tested) --------------
        let myRecents = (try? await getYourMusicFeed(uid: me.uid)) ?? []
        // The user's own Apple Music library — read live, never persisted. Both a
        // seed source and (more importantly) an exclusion source. Best-effort.
        let appleLibrary = (try? await musicService.getSavedTracks(limit: appleLibrarySeedLimit)) ?? []
        diagLog("runCatalog(\(mode.busyKey)): appleLibrary \(appleLibrary.count) tracks")

        let genre = mode.genre
        // Discovery-style runs draw a wider pool and rotate the weaker seeds each
        // week, so the similarity graph is explored from a different corner every
        // time instead of always from the same top 8.
        let rotatesSeeds: Bool = { switch mode { case .discovery, .newFromSimilar: return true; default: return false } }()
        var seeds = buildTasteSeeds(
            library: myLibrary,
            recents: myRecents,
            spotlights: me.spotlightTracks,
            appleLibrary: appleLibrary,
            artistLimit: rotatesSeeds ? 25 : tasteSeedLimit,
            seedGenre: genre,
            overrides: TasteOverridesStore.load(uid: me.uid)
        )
        if rotatesSeeds {
            seeds = TasteSeeds(
                artists: rotatedSeeds(seeds.artists, total: tasteSeedLimit, shuffleSeed: shuffleSeed),
                genreWeights: seeds.genreWeights, heardCatalogIds: seeds.heardCatalogIds,
                heardIsrcs: seeds.heardIsrcs, heardTitleArtist: seeds.heardTitleArtist,
                allArtistKeys: seeds.allArtistKeys
            )
            diagLog("runCatalog(\(mode.busyKey)): seeds \(seeds.artists.map(\.displayName))")
        }
        guard !seeds.isEmpty else {
            emptyReason = genre.map {
                "You haven't played enough \($0) yet for us to find more of it."
            } ?? "We need to know what you listen to first. Play some music, save a few tracks, and try again."
            return nil
        }

        // "Because you listen to X" seeds from X alone. X comes from the tile
        // (your top artists by Shelf tracks), which may not be in the weighted
        // top 8 — so build the seed if it isn't there. Exclusions are untouched.
        if case .becauseArtist(let key, let name) = mode {
            let seed = seeds.artists.first { $0.key == key }
                ?? SeededArtist(key: key, displayName: name, weight: 1)
            seeds = TasteSeeds(
                artists: [seed], genreWeights: seeds.genreWeights,
                heardCatalogIds: seeds.heardCatalogIds, heardIsrcs: seeds.heardIsrcs,
                heardTitleArtist: seeds.heardTitleArtist, allArtistKeys: seeds.allArtistKeys
            )
        }

        // --- Stage 1: which artists to draw tracks from ----------------------
        // Every fetch routes through `MusicDetailCache`, which is disk-persisted
        // under a user-independent key.
        func resolve(_ name: String) async -> ArtistResult? {
            await MusicDetailCache.shared.resolveArtistByName(name, fetch: {
                let results = try? await musicService.searchAll(name, maxPerType: 1)
                return results?.artists.first
            })
        }

        var candidateArtists: [CandidateArtist] = []
        if mode == .deepCuts {
            // The artists themselves — no expansion, no "known artist" exclusion.
            for seed in seeds.artists {
                guard let resolved = await resolve(seed.displayName) else { continue }
                candidateArtists.append(CandidateArtist(
                    id: resolved.id, name: resolved.name, score: seed.weight, seedNames: [seed.displayName]
                ))
            }
            guard !candidateArtists.isEmpty else {
                emptyReason = "Couldn't look up your artists right now. Try again in a moment."
                return nil
            }
        } else {
            let known = seeds.knownArtistKeys
            var similarBySeed: [(seed: SeededArtist, similar: [(id: String, name: String)])] = []
            for seed in seeds.artists {
                guard let resolved = await resolve(seed.displayName) else { continue }
                let extras = await MusicDetailCache.shared.extras(artistId: resolved.id) {
                    guard let e = try? await musicService.getArtistExtras(artistId: resolved.id) else { return nil }
                    return ArtistExtraDetails(similarArtists: e.similarArtists, featuresOn: e.featuresOn)
                }
                guard let similar = extras?.similarArtists, !similar.isEmpty else { continue }
                similarBySeed.append((seed, similar.map { (id: $0.id, name: $0.name) }))
            }
            let novelty = noveltyMultipliers(
                recent: Self.loadRecentSuggestions(uid: me.uid),
                nowSeconds: Date().timeIntervalSince1970)
            candidateArtists = rankCandidateArtists(
                similarBySeed: similarBySeed, excluding: known, limit: tasteCandidateArtistLimit,
                novelty: novelty, dampenHubs: true
            )

            // Second hop: expand a few of the first-hop candidates that only ONE
            // seed pointed at (hubs are already over-represented), at reduced
            // weight. Reaches artists two steps from your taste, which Apple's
            // single-hop list never surfaces. Cached persistently per artist.
            for pick in secondHopPicks(candidateArtists, shuffleSeed: shuffleSeed) {
                let extras = await MusicDetailCache.shared.extras(artistId: pick.id) {
                    guard let e = try? await musicService.getArtistExtras(artistId: pick.id) else { return nil }
                    return ArtistExtraDetails(similarArtists: e.similarArtists, featuresOn: e.featuresOn)
                }
                guard let similar = extras?.similarArtists, !similar.isEmpty else { continue }
                // Credited to the ORIGINAL seed, so "Because you listen to X"
                // never names an artist the user hasn't heard of.
                let origin = SeededArtist(
                    key: primaryArtist(pick.name).lowercased(),
                    displayName: pick.seedNames.first ?? pick.name,
                    weight: 0.4 * pick.score)
                similarBySeed.append((origin, similar.map { (id: $0.id, name: $0.name) }))
            }
            candidateArtists = rankCandidateArtists(
                similarBySeed: similarBySeed, excluding: known, limit: tasteCandidateArtistLimit,
                novelty: novelty, dampenHubs: true
            )
            diagLog("runCatalog(\(mode.busyKey)): candidates \(candidateArtists.prefix(12).map(\.name))")
            guard !candidateArtists.isEmpty else {
                emptyReason = "We couldn't find anything new next to what you play. Try again once you've listened to a bit more."
                return nil
            }
        }

        // --- Stage 2: their tracks, scored and selected (pure, tested) -------
        var candidates: [TasteCandidate] = []
        for artist in candidateArtists {
            let core = await MusicDetailCache.shared.core(artistId: artist.id) {
                guard let c = try? await musicService.getArtistCore(artistId: artist.id) else { return nil }
                return ArtistCoreDetails(albums: c.albums, topTracks: c.topTracks)
            }

            // Top songs FIRST, so when an album track is the same recording as a
            // hit, `selectTasteTracks`' identity dedup keeps the top-songs entry
            // and with it that track's familiarity penalty. "New" releases skip
            // top songs entirely — they're an artist's old hits by definition.
            if mode != .newFromSimilar {
                for (rank, song) in (core?.topTracks ?? []).enumerated() {
                    candidates.append(TasteCandidate(song: song, artistScore: artist.score, rank: rank))
                }
            }

            let albums: [AlbumResult]
            switch mode {
            case .deepCuts:        albums = Self.ownedDeepCutAlbums(from: core?.albums ?? [])
            case .newFromSimilar:  albums = Self.recentReleases(from: core?.albums ?? [])
            default:               albums = Self.deepCutAlbums(from: core?.albums ?? [])
            }
            for album in albums {
                let tracks = await MusicDetailCache.shared.tracks(
                    albumId: album.id, releaseDate: album.releaseDate,
                    name: album.name, artist: album.artistName, artwork: album.artwork
                ) {
                    (try? await musicService.getAlbumTracks(
                        albumId: album.id, albumName: album.name, artwork: album.artwork
                    )) ?? []
                }
                for song in tracks where mode != .newFromSimilar || song.isPlayable {
                    candidates.append(TasteCandidate(song: song, artistScore: artist.score, rank: tasteAlbumTrackRank))
                }
            }
        }

        // A genre-scoped run keeps only artists who genuinely belong to the genre
        // and, within them, tracks tagged with it (`filterCandidates`).
        let inGenre: [TasteCandidate] = {
            guard let genre else { return candidates }
            return filterCandidates(candidates, toGenre: genre)
        }()

        let selected = selectTasteTracks(candidates: inGenre, seeds: seeds, shuffleSeed: shuffleSeed)
        // Remember who was suggested so they sit out the next few weeks.
        Self.recordSuggestions(uid: me.uid, keys: Set(selected.map(\.artistKey)))
        guard !selected.isEmpty else {
            switch mode {
            case .discovery(let g):
                emptyReason = g.map { "Nothing new in \($0) right now — we've run out of things you haven't already heard." }
                    ?? "You've already heard everything we'd suggest right now. Try again later."
            case .deepCuts:
                emptyReason = "You've already heard everything from your top artists."
            case .newFromSimilar:
                emptyReason = "Nothing new from artists like yours in the last 60 days."
            case .becauseArtist(_, let name):
                emptyReason = "Nothing new next to \(name) that you haven't already heard."
            }
            return nil
        }

        if case .discovery(let g?) = mode, selected.count < Self.minGenrePlaylistSize {
            emptyReason = "Not enough new \(g) to build a playlist yet."
            return nil
        }

        // --- Stage 3: give the kept tracks catalog ids, and write ------------
        // Only the final 25: a MusicKit candidate has no `catalogId` until it's
        // kept, and doing this per candidate would be hundreds of transactions.
        var tracks: [(catalogId: String, addedByUid: String, addedByUsername: String, sourceService: MusicServiceType)] = []
        for candidate in selected {
            guard let catalogId = try? await ensureCatalogId(for: candidate.song) else { continue }
            // Credited to the owner: there is no person behind a catalog
            // suggestion, and inventing one would be a lie.
            tracks.append((catalogId, me.uid, me.username, .appleMusic))
        }
        guard !tracks.isEmpty else {
            emptyReason = "Couldn't prepare those suggestions. Try again."
            return nil
        }

        let cover = selected.first { !$0.song.artwork.isEmpty }?.song.artwork ?? ""

        let title: String?
        let description: String
        switch mode {
        case .discovery(let g):
            title = g.map { "\($0) Discoveries" }
            description = Self.describeTaste(seeds: seeds)
        case .deepCuts:
            title = nil
            description = "Songs you haven't heard from \(Self.artistList(seeds.artists.prefix(3).map(\.displayName)))."
        case .newFromSimilar:
            title = nil
            description = "Fresh releases from artists like \(Self.artistList(seeds.artists.prefix(3).map(\.displayName)))."
        case .becauseArtist(_, let name):
            title = "Because you listen to \(name)"
            description = "More like \(name)."
        }

        return try await upsertGeneratedPlaylist(
            ownerUid: me.uid,
            ownerUsername: me.username,
            ownerAvatarEmoji: me.avatarEmoji,
            ownerAvatarColor: me.avatarColor,
            lens: mode.lens,
            description: description,
            coverArtwork: cover,
            genre: mode.genre,
            variant: mode.variant,
            title: title,
            tracks: tracks
        )
    }

    /// "A", "A and B", "A, B and C".
    private static func artistList(_ names: [String]) -> String {
        switch names.count {
        case 0:  return "your artists"
        case 1:  return names[0]
        case 2:  return "\(names[0]) and \(names[1])"
        default: return "\(names[0]), \(names[1]) and \(names[2])"
        }
    }

    /// Names the artists this was actually built from, so a suggestion can
    /// always explain itself — the stand-in for the named-person credit every
    /// other lens carries.
    static func describeTaste(seeds: TasteSeeds) -> String {
        let names = seeds.artists.prefix(3).map(\.displayName)
        guard !names.isEmpty else { return "Built from what you listen to." }
        let remainder = seeds.artists.count - names.count
        let list: String
        switch names.count {
        case 1:  list = names[0]
        case 2:  list = "\(names[0]) and \(names[1])"
        default: list = "\(names[0]), \(names[1]) and \(names[2])"
        }
        return remainder > 0
            ? "Because you listen to \(list) and \(remainder) more."
            : "Because you listen to \(list)."
    }

    /// A tile Home is showing, and so wants a playlist behind.
    enum Wanted: Hashable {
        case people(PlaylistLens)
        case catalog(CatalogMode)

        var lens: PlaylistLens {
            switch self { case .people(let l): return l; case .catalog(let m): return m.lens }
        }
        var genre: String? { if case .catalog(let m) = self { return m.genre }; return nil }
        var variant: String? { if case .catalog(let m) = self { return m.variant }; return nil }
    }

    /// The silent background pass. Does two things, one tile at a time:
    ///
    /// 1. **Builds** any wanted tile that has no playlist yet, so nobody has to
    ///    tap an empty tile to get it.
    /// 2. **Rebuilds** every existing generated playlist that has gone stale
    ///    (older than last Monday, or built by an outdated algorithm).
    ///
    /// Returns silently — deliberately no navigation, unlike a user-initiated
    /// tap, because yanking someone into a playlist they didn't ask for on
    /// opening Home would be hostile. A tile attempted within `retryAfter` isn't
    /// retried, so a build that finds nothing (or fails) can't repeat on every
    /// Home appearance.
    ///
    /// Sequential on purpose: each people-lens is ~1,000 reads, and the catalog
    /// ones share the disk-cached artist/album fetches, so later ones are cheap.
    ///
    /// Returns true when it built anything, so the caller knows to re-read its
    /// playlists — a return value rather than published state, which would
    /// invalidate every observing view for a one-shot signal.
    @discardableResult
    func refreshAndBuildIfNeeded(
        existing: [Playlist],
        wanted: [Wanted],
        me: UserProfile,
        myLibrary: [LibraryTrackDoc],
        myGeohash: String?,
        musicService: AppleMusicService
    ) async -> Bool {
        // Never race a build already in flight, or another run of this pass:
        // Home re-triggers it as inputs arrive, and two interleaved passes could
        // mark a tile "attempted" and then lose its build to the other's busy flag.
        guard !autoPassRunning, generating.isEmpty, tasteBusyKey == nil else { return false }
        autoPassRunning = true
        defer { autoPassRunning = false }
        // Generating from an empty library only burns the retry guard on
        // "we need to know what you listen to".
        guard !myLibrary.isEmpty else { return false }

        let outdated = UserDefaults.standard.integer(forKey: Self.algorithmKey(me.uid)) < Self.algorithmVersion
        let cutoff = outdated ? Double.greatestFiniteMagnitude : Self.lastMondayStartMs()
        defer {
            if outdated { UserDefaults.standard.set(Self.algorithmVersion, forKey: Self.algorithmKey(me.uid)) }
        }

        func run(lens: PlaylistLens, mode: CatalogMode?, weekly: Bool) async {
            if let mode {
                await generateCatalog(
                    mode: mode, me: me, myLibrary: myLibrary, musicService: musicService,
                    reshuffle: false, weeklySeed: weekly
                )
            } else {
                await generate(lens: lens, me: me, myLibrary: myLibrary, myGeohash: myGeohash)
            }
        }

        var built = false

        // 1. Wanted tiles with no playlist yet, in on-screen order.
        for tile in wanted {
            let has = existing.contains {
                $0.source == .generated && $0.lens == tile.lens && $0.genre == tile.genre && $0.variant == tile.variant
            }
            guard !has,
                  !recentlyAttempted(lens: tile.lens, genre: tile.genre, variant: tile.variant, uid: me.uid)
            else { continue }
            markAttempt(lens: tile.lens, genre: tile.genre, variant: tile.variant, uid: me.uid)
            if case .catalog(let mode) = tile {
                await run(lens: tile.lens, mode: mode, weekly: false)
            } else {
                await run(lens: tile.lens, mode: nil, weekly: false)
            }
            built = true
        }

        // 2. Existing playlists that have gone stale.
        let stale = existing
            .filter { $0.source == .generated && $0.lens != nil && $0.updatedAt < cutoff }
            .sorted { $0.updatedAt < $1.updatedAt }
        for playlist in stale {
            guard let lens = playlist.lens else { continue }
            guard outdated || !recentlyAttempted(lens: lens, genre: playlist.genre, variant: playlist.variant, uid: me.uid)
            else { continue }
            markAttempt(lens: lens, genre: playlist.genre, variant: playlist.variant, uid: me.uid)
            if lens.isCatalogSourced {
                guard let mode = CatalogMode.of(playlist) else { continue }
                await run(lens: lens, mode: mode, weekly: true)
            } else {
                await run(lens: lens, mode: nil, weekly: true)
            }
            built = true
        }
        return built
    }

    // MARK: - Pools (the only thing a lens actually changes)

    private func candidatePool(
        lens: PlaylistLens,
        me: UserProfile,
        myGeohash: String?
    ) async throws -> [PersonTaste] {
        switch lens {
        case .circle:   return await circlePool(me: me)
        case .nearby:   return try await nearbyPool(me: me, myGeohash: myGeohash)
        case .admirers: return try await admirersPool(me: me)
        case .blend:    return try await blendPool(me: me, myGeohash: myGeohash)
        // Unreachable: `.taste` has no pool of people and never enters this
        // pipeline — it runs through `runTaste`. Listed explicitly rather than
        // hidden behind a `default`, so a genuinely new people-lens still fails
        // to compile here until it has a pool.
        case .taste, .deepCuts, .newFromSimilar, .becauseArtist: return []
        }
    }

    /// People you follow. Their profiles (and the spotlights embedded on them)
    /// are already cached from launch, so stage 1 here costs nothing.
    private func circlePool(me: UserProfile) async -> [PersonTaste] {
        let following = await FollowingCache.shared.following(uid: me.uid)
        guard !following.isEmpty else { return [] }
        let profiles = await UserProfileCache.shared.profiles(uids: following.map(\.uid))
        return profiles.map { Self.personTaste(from: $0, skew: 1) }
    }

    /// People physically near you. Proximity is the *filter*, taste is the
    /// *rank* — `getNearbyUsers` returns no distance, so we don't invent one.
    /// `UserProfile.spotlightTracks` is embedded, so their deliberate picks are
    /// free here too.
    private func nearbyPool(me: UserProfile, myGeohash: String?) async throws -> [PersonTaste] {
        guard let myGeohash, !myGeohash.isEmpty else { return [] }
        let nearby = try await getNearbyUsers(
            geohash: myGeohash, excludeUid: me.uid, radiusKm: nearbyRadiusKm
        )
        return nearby.map { Self.personTaste(from: $0, skew: 1) }
    }

    /// People who nodded your tracks — skewed by how much they've nodded, so
    /// someone who reacted to twelve of your tracks outranks a one-off.
    private func admirersPool(me: UserProfile) async throws -> [PersonTaste] {
        let nodders = try await getNodders(sourceUid: me.uid)
        guard !nodders.isEmpty else { return [] }

        let profiles = await UserProfileCache.shared.profiles(uids: nodders.map(\.uid))
        let strengthByUid = Dictionary(
            uniqueKeysWithValues: nodders.map { ($0.uid, Double($0.nodCount)) }
        )
        let maxNods = max(strengthByUid.values.max() ?? 1, 1)

        return profiles.map { profile in
            // Normalize to 1...2 so nod strength meaningfully reorders people
            // without swamping taste affinity entirely.
            let strength = strengthByUid[profile.uid] ?? 1
            return Self.personTaste(from: profile, skew: 1 + (strength / maxNods))
        }
    }

    /// Everyone, deduped. Each source contributes its own skew; a person who
    /// shows up in several pools keeps the strongest one rather than stacking,
    /// so being both a follow and nearby can't runaway-boost someone.
    private func blendPool(me: UserProfile, myGeohash: String?) async throws -> [PersonTaste] {
        async let circle   = circlePool(me: me)
        async let nearby   = try? nearbyPool(me: me, myGeohash: myGeohash)
        async let admirers = try? admirersPool(me: me)

        let all = await circle + (await nearby ?? []) + (await admirers ?? [])

        var best: [String: PersonTaste] = [:]
        for p in all {
            if let existing = best[p.uid], existing.skew >= p.skew { continue }
            best[p.uid] = p
        }
        return Array(best.values)
    }

    // MARK: - Helpers

    /// Builds a cheap stage-1 profile from a `UserProfile` alone.
    ///
    /// Uses only the spotlights embedded on the profile doc — deliberate picks,
    /// the highest-intent signal in the app, and free because the profile is
    /// already fetched. Stage 2 deepens this for the few people who survive.
    private static func personTaste(from profile: UserProfile, skew: Double) -> PersonTaste {
        PersonTaste(
            uid: profile.uid,
            username: profile.username,
            profile: .from(spotlights: profile.spotlightTracks),
            skew: skew
        )
    }

    /// Turns one person's fetched listening into weighted evidence.
    /// `nonisolated` so the stage-2 task group can call it off the main actor.
    /// Pure: reads only its arguments, touches no actor state.
    nonisolated private static func contributions(
        from bundle: ProfileBundle,
        person: RankedPerson
    ) -> [TrackContribution] {
        var out: [TrackContribution] = []

        for s in bundle.spotlightHistory {
            guard let catalogId = s.catalogId, !catalogId.isEmpty else { continue }
            out.append(TrackContribution(
                catalogId: catalogId, artist: s.artist,
                personUid: person.uid, personUsername: person.username,
                personWeight: person.weight, signal: .spotlight
            ))
        }

        for p in bundle.recentTracks {
            out.append(TrackContribution(
                catalogId: p.catalogId, artist: p.artist,
                personUid: person.uid, personUsername: person.username,
                personWeight: person.weight,
                signal: p.replayCount > 0 ? .replayedRecent : .recentPlay
            ))
        }

        return out
    }

    /// Names the people, because *who* is the whole product. "2 people" is the
    /// kind of thing an algorithm says; "From Aidooo and Sam" is not.
    private static func describe(lens: PlaylistLens, contributors: [String]) -> String {
        let names = nameList(contributors)
        switch lens {
        case .circle:   return "From \(names), who you follow."
        case .nearby:   return "From \(names), near you."
        case .admirers: return "From \(names), who liked your music."
        case .blend:    return "From \(names)."
        // See `candidatePool` — `.taste` describes itself via `describeTaste`,
        // which names artists rather than people.
        case .taste, .deepCuts, .newFromSimilar, .becauseArtist: return Self.tasteFallbackDescription
        }
    }

    /// Stand-in for the two people-pipeline switches `.taste` can never reach.
    /// Never shown: `runTaste` writes its own description and empty reasons.
    private static let tasteFallbackDescription = "Built from what you listen to."

    private static func nameList(_ names: [String]) -> String {
        switch names.count {
        case 0:  return "people you follow"
        case 1:  return names[0]
        case 2:  return "\(names[0]) and \(names[1])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) others"
        }
    }

    private static func emptyPoolMessage(for lens: PlaylistLens) -> String {
        switch lens {
        case .circle:   return "Follow a few people to build this one."
        case .nearby:   return "No one's listening nearby right now."
        case .admirers: return "Nobody has nodded your tracks yet."
        case .blend:    return "Follow a few people to build this one."
        // See `candidatePool`. `runTaste` sets its own reasons inline.
        case .taste, .deepCuts, .newFromSimilar, .becauseArtist: return Self.tasteFallbackDescription
        }
    }
}
