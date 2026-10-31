import Combine
import Foundation
import UIKit
import WidgetKit
import NodalongKit

/// Keeps the widgets' App Group payload current: today's friend spotlights
/// (from Home) and what's playing now. Artwork is downloaded into the shared
/// container because a widget can't fetch images itself.
///
/// Writes are debounced and skipped when nothing changed, and
/// `reloadAllTimelines` is only called on a real change — iOS budgets widget
/// reloads, so a chatty caller would just get throttled.
@MainActor
final class WidgetSync {
    private var cancellables = Set<AnyCancellable>()
    private var pending: Task<Void, Never>?
    private var last = WidgetPayload()
    private weak var playerVM: PlayerViewModel?
    private weak var homeVM: HomeViewModel?
    private var started = false

    func start(playerVM: PlayerViewModel, homeVM: HomeViewModel) {
        guard !started, WidgetStore.containerURL != nil else { return }
        started = true
        self.playerVM = playerVM
        self.homeVM = homeVM

        Publishers.CombineLatest(playerVM.$nowPlaying, playerVM.$isPlaying)
            .sink { [weak self] _, _ in self?.schedule() }
            .store(in: &cancellables)
        homeVM.$friendsSpotlights
            .sink { [weak self] _ in self?.schedule() }
            .store(in: &cancellables)
    }

    private func schedule() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    private func sync() async {
        guard let playerVM, let homeVM else { return }

        let today = dateKey(epochMs: Date().timeIntervalSince1970 * 1000)
        let spotlights = homeVM.friendsSpotlights
            .filter { dateKey(epochMs: $0.track.spotlitAt) == today }
            .prefix(3)
        var spotlightRows: [WidgetPayload.Spotlight] = []
        for s in spotlights {
            let file = await downloadArtwork(s.track.artwork)
            spotlightRows.append(.init(id: s.id, username: s.user.username, title: s.track.title,
                                       artist: s.track.artist, artworkFile: file))
        }

        var nowPlaying: WidgetPayload.NowPlaying?
        if let t = playerVM.nowPlaying {
            nowPlaying = .init(title: t.title, artist: t.artist, isPlaying: playerVM.isPlaying,
                               artworkFile: await downloadArtwork(t.artwork))
        }

        var payload = WidgetPayload(spotlights: spotlightRows, nowPlaying: nowPlaying)
        guard payload != last else { return }   // `updatedAt` is stamped after the compare
        last = payload
        payload.updatedAt = Date()
        WidgetStore.write(payload)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Small JPEG into the container, named by a hash of the URL so a repeat
    /// download is a no-op. Returns nil if there's no artwork or it failed.
    private func downloadArtwork(_ url: String) async -> String? {
        let sized = ArtworkURL.sized(url, points: 80)
        guard !sized.isEmpty, let remote = URL(string: sized), let dir = WidgetStore.containerURL else { return nil }
        let name = "art_\(abs(sized.hashValue)).jpg"
        let local = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: local.path) { return name }
        guard let (data, _) = try? await URLSession.shared.data(from: remote),
              UIImage(data: data) != nil else { return nil }
        try? data.write(to: local, options: .atomic)
        return name
    }
}
