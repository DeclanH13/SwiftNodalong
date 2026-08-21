import Foundation

/// Lifecycle of a listening party.
public enum PartyStatus: String, Codable, Hashable, Sendable {
    case live
    case ended
}

/// Who may add tracks to the party queue.
public enum PartyPermission: String, Codable, Hashable, Sendable {
    /// Any participant (friend who joined) can add.
    case anyoneCanAdd = "anyone"
    /// Only the host can add.
    case ownerOnly = "owner"
}

/// How a party participant is listening.
public enum PartyListenMode: String, Codable, Hashable, Sendable {
    /// The host plays; this participant just watches (the DJ model — default,
    /// and the only option for non-subscribers).
    case inRoom = "inRoom"
    /// This participant plays the same track on their own device, in sync with
    /// the host ("radio").
    case sync = "sync"
}

/// A listening party — the durable record at `parties/{id}` (Firestore).
///
/// **DJ model:** the host's device is the only audio source; remote participants
/// contribute to the shared queue and watch. Ephemeral live state (presence, the
/// now-playing pointer) lives in RTDB, not here — see `PartyLiveService`.
///
/// `id` is the Firestore documentID and is NOT part of the stored payload (the
/// read layer injects it after decoding).
public struct ListeningParty: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public let hostUid: String
    public var hostUsername: String
    public var hostAvatarEmoji: String?
    public var hostAvatarColor: String?
    public var title: String
    public var status: PartyStatus
    public var permission: PartyPermission
    public let createdAt: Double
    public var endedAt: Double?
    /// Set when the party ends and its queue is frozen into a playlist.
    public var resultPlaylistId: String?

    public init(
        id: String = "",
        hostUid: String,
        hostUsername: String,
        hostAvatarEmoji: String? = nil,
        hostAvatarColor: String? = nil,
        title: String,
        status: PartyStatus = .live,
        permission: PartyPermission = .anyoneCanAdd,
        createdAt: Double,
        endedAt: Double? = nil,
        resultPlaylistId: String? = nil
    ) {
        self.id = id
        self.hostUid = hostUid
        self.hostUsername = hostUsername
        self.hostAvatarEmoji = hostAvatarEmoji
        self.hostAvatarColor = hostAvatarColor
        self.title = title
        self.status = status
        self.permission = permission
        self.createdAt = createdAt
        self.endedAt = endedAt
        self.resultPlaylistId = resultPlaylistId
    }

    private enum CodingKeys: String, CodingKey {
        case hostUid, hostUsername, hostAvatarEmoji, hostAvatarColor
        case title, status, permission, createdAt, endedAt, resultPlaylistId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id               = ""
        hostUid          = try c.decodeIfPresent(String.self, forKey: .hostUid) ?? ""
        hostUsername     = try c.decodeIfPresent(String.self, forKey: .hostUsername) ?? ""
        hostAvatarEmoji  = try c.decodeIfPresent(String.self, forKey: .hostAvatarEmoji)
        hostAvatarColor  = try c.decodeIfPresent(String.self, forKey: .hostAvatarColor)
        title            = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        status           = try c.decodeIfPresent(PartyStatus.self, forKey: .status) ?? .live
        permission       = try c.decodeIfPresent(PartyPermission.self, forKey: .permission) ?? .anyoneCanAdd
        createdAt        = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        endedAt          = try c.decodeIfPresent(Double.self, forKey: .endedAt)
        resultPlaylistId = try c.decodeIfPresent(String.self, forKey: .resultPlaylistId)
    }

    public var isLive: Bool { status == .live }
}

/// A present participant — mirrors an RTDB `parties_live/{id}/presence/{uid}`
/// node. Parsed from a plain dictionary by `PartyLiveService` (RTDB isn't
/// Codable-native), so this is a lightweight value type, `id == uid`.
public struct PartyParticipant: Identifiable, Hashable, Sendable {
    public let id: String        // uid
    public var username: String
    public var avatarEmoji: String?
    public var avatarColor: String?
    public var joinedAt: Double
    /// How this participant is listening (in the room vs in sync). Defaults to
    /// `.inRoom` for legacy presence nodes written before sync support.
    public var mode: PartyListenMode

    public init(id: String, username: String, avatarEmoji: String? = nil,
                avatarColor: String? = nil, joinedAt: Double,
                mode: PartyListenMode = .inRoom) {
        self.id = id
        self.username = username
        self.avatarEmoji = avatarEmoji
        self.avatarColor = avatarColor
        self.joinedAt = joinedAt
        self.mode = mode
    }
}

/// The host-written "now playing" pointer, mirrored at
/// `parties_live/{id}/nowPlaying` (RTDB). Watched (display-only) by in-room
/// guests; fed into the follow engine by sync guests (see `ListeningPartyViewModel`).
public struct PartyNowPlaying: Hashable, Sendable {
    public var catalogId: String
    public var positionMs: Int?
    public var isPlaying: Bool
    public var updatedAt: Double
    /// `true` while the host's own playback is the 30-second preview fallback
    /// (non-subscriber host). Sync is blocked against a preview-mode host — see
    /// `SyncTimeline.isPreviewPlayback`'s doc comment.
    public var isPreviewPlayback: Bool

    public init(catalogId: String, positionMs: Int? = nil, isPlaying: Bool, updatedAt: Double, isPreviewPlayback: Bool = false) {
        self.catalogId = catalogId
        self.positionMs = positionMs
        self.isPlaying = isPlaying
        self.updatedAt = updatedAt
        self.isPreviewPlayback = isPreviewPlayback
    }
}
