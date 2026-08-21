import Foundation

/// Who can see a playlist. Enforced client-side today and (once shipped) by
/// Firestore security rules — see `firestore.rules`.
public enum PlaylistVisibility: String, Codable, Hashable, Sendable, CaseIterable {
    /// Only the owner.
    case `private`
    /// The owner and their mutual-follow friends (default).
    case friends
    /// Anyone.
    case `public`
}

/// How a playlist came to exist. Stored flat (`source` + `partyId`) rather than
/// as an enum-with-payload so Firestore can query it and the schema stays simple.
public enum PlaylistSource: String, Codable, Hashable, Sendable {
    /// Hand-built by the owner.
    case manual
    /// Frozen from an ended listening party (`partyId` points at the source).
    case party
}

/// A user-owned collection of tracks stored at `playlists/{id}`.
///
/// The playlist doc holds its own metadata (title/visibility/…); its tracks live
/// in the `playlists/{id}/tracks` subcollection as slim `PlaylistTrack` docs that
/// overlay metadata from the shared catalog on read.
///
/// `id` is the Firestore documentID and is NOT part of the stored payload — the
/// read layer injects it after decoding (`CodingKeys` omits it).
public struct Playlist: Codable, Identifiable, Hashable, Sendable {
    /// Firestore documentID. Empty until set by the read layer.
    public var id: String
    public let ownerUid: String
    public var ownerUsername: String
    public var ownerAvatarEmoji: String?
    public var ownerAvatarColor: String?
    public var title: String
    public var description: String?
    /// Cover image URL — derived from the first track's artwork (or a custom
    /// upload later). May be empty; render falls back to a placeholder.
    public var coverArtwork: String
    public var visibility: PlaylistVisibility
    public let source: PlaylistSource
    /// The party this playlist was frozen from, when `source == .party`.
    public let partyId: String?
    /// Everyone who contributed a track (host + participants for party playlists;
    /// just the owner for manual ones). Used to surface a frozen party playlist
    /// on every participant's profile and to gate reads.
    public var contributorUids: [String]
    public var trackCount: Int
    public let createdAt: Double
    public var updatedAt: Double

    public init(
        id: String = "",
        ownerUid: String,
        ownerUsername: String,
        ownerAvatarEmoji: String? = nil,
        ownerAvatarColor: String? = nil,
        title: String,
        description: String? = nil,
        coverArtwork: String = "",
        visibility: PlaylistVisibility = .friends,
        source: PlaylistSource = .manual,
        partyId: String? = nil,
        contributorUids: [String] = [],
        trackCount: Int = 0,
        createdAt: Double,
        updatedAt: Double
    ) {
        self.id = id
        self.ownerUid = ownerUid
        self.ownerUsername = ownerUsername
        self.ownerAvatarEmoji = ownerAvatarEmoji
        self.ownerAvatarColor = ownerAvatarColor
        self.title = title
        self.description = description
        self.coverArtwork = coverArtwork
        self.visibility = visibility
        self.source = source
        self.partyId = partyId
        self.contributorUids = contributorUids
        self.trackCount = trackCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // `id` is the documentID, not a stored field — omit it from the payload.
    private enum CodingKeys: String, CodingKey {
        case ownerUid, ownerUsername, ownerAvatarEmoji, ownerAvatarColor
        case title, description, coverArtwork, visibility, source, partyId
        case contributorUids, trackCount, createdAt, updatedAt
    }

    // Tolerant decode so a doc written by an older/leaner client still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id               = ""
        ownerUid         = try c.decodeIfPresent(String.self, forKey: .ownerUid) ?? ""
        ownerUsername    = try c.decodeIfPresent(String.self, forKey: .ownerUsername) ?? ""
        ownerAvatarEmoji = try c.decodeIfPresent(String.self, forKey: .ownerAvatarEmoji)
        ownerAvatarColor = try c.decodeIfPresent(String.self, forKey: .ownerAvatarColor)
        title            = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        description      = try c.decodeIfPresent(String.self, forKey: .description)
        coverArtwork     = try c.decodeIfPresent(String.self, forKey: .coverArtwork) ?? ""
        visibility       = try c.decodeIfPresent(PlaylistVisibility.self, forKey: .visibility) ?? .friends
        source           = try c.decodeIfPresent(PlaylistSource.self, forKey: .source) ?? .manual
        partyId          = try c.decodeIfPresent(String.self, forKey: .partyId)
        contributorUids  = try c.decodeIfPresent([String].self, forKey: .contributorUids) ?? []
        trackCount       = try c.decodeIfPresent(Int.self, forKey: .trackCount) ?? 0
        createdAt        = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        updatedAt        = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
    }
}
