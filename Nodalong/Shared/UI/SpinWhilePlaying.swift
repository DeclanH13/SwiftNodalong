import SwiftUI

/// Rotates its content like a spinning record while `isPlaying` is true,
/// freezing in place — not snapping back to 0° — on pause.
///
/// Extracted from `MiniPlayerBar`'s own proven spin mechanism (byte-identical
/// rotation formula and `TimelineView` configuration), for the two NEW
/// spinning-artwork contexts (`NowPlayingView`, `PartyView`'s now-playing
/// hero) that didn't spin before this. `MiniPlayerBar` itself is
/// deliberately NOT migrated onto this modifier — its own spin logic has a
/// well-documented, multi-round on-device bug history (see its own doc
/// comments), and touching working, hard-won code for a pure refactor isn't
/// worth the risk.
///
/// Rotation is a pure function of wall-clock time via
/// `TimelineSchedule.animation(paused:)`, not a discrete `Bool`-toggled
/// `.rotationEffect` — a two-value (0°/360°) toggle can only ever freeze at
/// one of those two literal angles, hard-snapping on every pause instead of
/// holding wherever it visually was. `paused:` freezes `context.date` in
/// place and resumes advancing from there, with no timer/Combine overhead.
///
/// Gates on `\.scenePhase` internally, so callers don't need their own
/// check — this app declares `UIBackgroundModes: audio`, so playback keeps
/// running while the screen is locked, and a continuous Core Animation in
/// that state wedges the render-server fence — the root cause of the
/// "purple screen on reopen" bug this session already fixed once for
/// `MiniPlayerBar`; this modifier carries the identical fix forward for its
/// two new callers.
private struct SpinWhilePlaying: ViewModifier {
    let isPlaying: Bool
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                 paused: !(isPlaying && scenePhase == .active))) { context in
            content.rotationEffect(rotationAngle(at: context.date))
        }
    }

    private func rotationAngle(at date: Date) -> Angle {
        let seconds = date.timeIntervalSinceReferenceDate
        return .degrees((seconds / 8.0 * 360).truncatingRemainder(dividingBy: 360))
    }
}

extension View {
    func spinWhilePlaying(_ isPlaying: Bool) -> some View {
        modifier(SpinWhilePlaying(isPlaying: isPlaying))
    }
}
