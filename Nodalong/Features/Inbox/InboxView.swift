import SwiftUI
import NodalongKit

/// Push value for the inbox screen.
struct InboxRoute: Hashable {}

/// Songs friends sent you, and invites to collaborative playlists.
struct InboxView: View {
    @EnvironmentObject private var inboxVM: InboxViewModel
    @EnvironmentObject private var playerVM: PlayerViewModel
    @Environment(FirebaseAuthViewModel.self) private var authVM

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ScreenTitle("Inbox")
                    if inboxVM.items.isEmpty {
                        Text("Nothing here yet. Songs and playlist invites from friends land here.")
                            .font(Font.nodalong.subheadline)
                            .foregroundStyle(Color.nodalong.textSecondary)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }
                    ForEach(inboxVM.items) { item in
                        InboxRow(item: item)
                            .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 16)
            }
        }
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .screenControls()
        .onAppear { inboxVM.markSeen() }
    }
}

private struct InboxRow: View {
    let item: InboxItem

    @EnvironmentObject private var inboxVM: InboxViewModel
    @EnvironmentObject private var playerVM: PlayerViewModel
    @Environment(FirebaseAuthViewModel.self) private var authVM
    @State private var track: CatalogTrack?
    @State private var accepted = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AvatarView(emoji: item.fromAvatarEmoji, colorHex: item.fromAvatarColor, size: 32)
                Text(headline)
                    .font(Font.nodalong.subheadlineSemibold)
                    .foregroundStyle(Color.nodalong.textPrimary)
                    .lineLimit(2)
                Spacer()
                Button { inboxVM.dismiss(item) } label: {
                    Image(systemName: "xmark").font(Font.nodalong.captionBold)
                        .foregroundStyle(Color.nodalong.textSecondary)
                }
                .buttonStyle(.plain)
            }
            if let note = item.note, !note.isEmpty {
                Text("“\(note)”").font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textSecondary)
            }
            switch item.kind {
            case .song:
                if let track {
                    Button {
                        let song = Song.from(catalogTrack: track, catalogId: item.catalogId ?? "")
                        Task { await playerVM.play(song) }
                    } label: {
                        HStack(spacing: 10) {
                            ArtworkThumbnail(url: track.artwork, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title).font(Font.nodalong.subheadlineMedium).lineLimit(1)
                                Text(track.artist).font(Font.nodalong.caption)
                                    .foregroundStyle(Color.nodalong.textSecondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "play.fill")
                        }
                        .foregroundStyle(Color.nodalong.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
            case .playlistInvite:
                Button {
                    guard let pid = item.playlistId, let uid = authVM.currentUser?.uid else { return }
                    Task {
                        do { try await acceptPlaylistInvite(playlistId: pid, myUid: uid); accepted = true }
                        catch { failed = true }
                    }
                } label: {
                    Text(accepted ? "Joined" : (failed ? "Couldn't join — try again" : "Accept"))
                        .font(Font.nodalong.subheadlineSemibold)
                        .foregroundStyle(Color.nodalong.textOnAccent)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Color.nodalong.purpleAccent)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(accepted)
            case .unknown:
                EmptyView()
            }
        }
        .padding(12)
        .background(Color.nodalong.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        .task(id: item.catalogId) {
            guard item.kind == .song, let id = item.catalogId else { return }
            track = await CatalogCache.shared.metadata(for: [id])[id]
        }
    }

    private var headline: String {
        switch item.kind {
        case .song:           return "\(item.fromUsername) sent you a song"
        case .playlistInvite: return "\(item.fromUsername) invited you to “\(item.playlistTitle ?? "a playlist")”"
        case .unknown:        return item.fromUsername
        }
    }
}

/// Bell with an unread badge; pushes the inbox on the current tab.
struct InboxBellButton: View {
    @EnvironmentObject private var inboxVM: InboxViewModel
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        Button {
            router.push(InboxRoute(), onto: router.selectedTab)
        } label: {
            Image(systemName: "bell")
                .font(Font.nodalong.subheadlineMedium)
                .foregroundStyle(Color.nodalong.textPrimary)
                .frame(width: 34, height: 34)
                .overlay(alignment: .topTrailing) {
                    if inboxVM.unreadCount > 0 {
                        Text("\(min(inboxVM.unreadCount, 9))")
                            .font(Font.nodalong.caption2)
                            .foregroundStyle(Color.nodalong.textOnAccent)
                            .frame(minWidth: 14, minHeight: 14)
                            .background(Color.nodalong.purpleAccent, in: Circle())
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Inbox")
    }
}
