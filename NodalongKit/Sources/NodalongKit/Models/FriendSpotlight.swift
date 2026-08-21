/// A single friend's today's spotlight pick, paired with who picked it.
/// Powers Home's "Friends' Spotlights" rail — see
/// `getFriendsSpotlightsToday(followingUids:)`.
public struct FriendSpotlight: Identifiable, Hashable, Sendable, Codable {
    // Composite, not just `track.trackId` — two different friends can
    // legitimately spotlight the same track on the same day, which would
    // otherwise produce a duplicate id in a SwiftUI `ForEach`.
    public var id: String { "\(user.uid)_\(track.trackId)" }
    public let user: UserProfile
    public let track: SpotlightTrack

    public init(user: UserProfile, track: SpotlightTrack) {
        self.user = user
        self.track = track
    }
}
