import ActivityKit
import Combine
import Foundation

/// Mirrors "I'm tuned in to someone / in a listening party" onto a Live
/// Activity (lock screen + Dynamic Island).
///
/// Local only: updates are made by the app while it is alive. The app holds the
/// `audio` background mode while playing, so these keep working locked. A
/// remotely-updated activity (a friend's live track while the app is closed)
/// would need push — not built.
///
/// Reads the player/party state rather than being told about it: one place
/// decides "is there an activity right now", whichever of NearMe tune-in or a
/// party sync started the session.
@MainActor
final class LiveActivityCoordinator {
    private var activity: Activity<ListeningActivityAttributes>?
    private var cancellables = Set<AnyCancellable>()
    private var pending: Task<Void, Never>?
    private weak var playerVM: PlayerViewModel?
    private weak var partyVM: ListeningPartyViewModel?
    private var started = false

    func start(playerVM: PlayerViewModel, partyVM: ListeningPartyViewModel) {
        guard !started else { return }
        started = true
        self.playerVM = playerVM
        self.partyVM = partyVM

        // Anything left over from a previous run (a kill leaves the activity up).
        Task { for a in Activity<ListeningActivityAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) } }

        Publishers.CombineLatest4(playerVM.$followContext, playerVM.$nowPlaying, playerVM.$isPlaying, partyVM.$isActive)
            .sink { [weak self] _, _, _, _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
    }

    /// `@Published` emits on willSet, and track changes land before the progress
    /// clock resets — so wait a beat and read settled state instead of the
    /// emitted values. Also coalesces bursts into one update.
    private func scheduleRefresh() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func refresh() async {
        guard let playerVM, let partyVM else { return }

        let label: String?
        if let ctx = playerVM.followContext { label = ctx.label }
        else if partyVM.isActive { label = partyVM.party?.title ?? "Listening party" }
        else { label = nil }

        guard let label, let track = playerVM.nowPlaying else {
            await endActivity()
            return
        }

        var start: Date?, end: Date?
        let duration = playerVM.currentDuration
        if playerVM.isPlaying, duration > 0 {
            let elapsed = playerVM.progress * duration
            start = Date().addingTimeInterval(-elapsed)
            end = start?.addingTimeInterval(duration)
        }
        let state = ListeningActivityAttributes.ContentState(
            title: track.title, artist: track.artist, isPlaying: playerVM.isPlaying,
            progressStart: start, progressEnd: end)

        if let activity, activity.attributes.label == label {
            await activity.update(.init(state: state, staleDate: nil))
        } else {
            await endActivity()
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            do {
                activity = try Activity.request(
                    attributes: ListeningActivityAttributes(label: label),
                    content: .init(state: state, staleDate: nil))
            } catch {
                FieldLog.event("liveactivity", "request failed \(FieldLog.tag(error))")
            }
        }
    }

    private func endActivity() async {
        guard let activity else { return }
        self.activity = nil
        await activity.end(nil, dismissalPolicy: .immediate)
    }
}
