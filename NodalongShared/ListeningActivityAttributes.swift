import ActivityKit
import Foundation

/// The Live Activity shown on the lock screen and in the Dynamic Island while
/// this device is tuned in to someone (NearMe tune-in or a synced party) or is
/// in a listening party.
///
/// Compiled into BOTH the app and the widget extension — the two must agree on
/// this type exactly, which is why it lives outside either target's folder.
struct ListeningActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        var isPlaying: Bool
        /// When playing, the progress bar runs `progressStart...progressEnd` on
        /// its own via `ProgressView(timerInterval:)`, so the app never has to
        /// push per-second updates. Nil while paused or when the length is unknown.
        var progressStart: Date?
        var progressEnd: Date?
    }

    /// "Tuned in to Aidooo" / the party's title. Fixed for the activity's life.
    var label: String
}
