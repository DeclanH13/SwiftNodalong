import SwiftUI
import NodalongKit

/// Owner-only: invite a mutual follow to contribute to a playlist. The invite
/// lands in their inbox; accepting adds them to `contributorUids`.
struct InviteFriendSheet: View {
    let playlist: Playlist

    @Environment(\.dismiss) private var dismiss
    @Environment(FirebaseAuthViewModel.self) private var authVM

    @State private var friends: [UserProfile] = []
    @State private var loaded = false
    @State private var invited: Set<String> = []
    @State private var busy: String?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                if !loaded {
                    ProgressView()
                } else if friends.isEmpty {
                    Text("You can invite people you follow who follow you back.")
                        .font(Font.nodalong.caption)
                        .foregroundStyle(Color.nodalong.textSecondary)
                }
                ForEach(friends, id: \.uid) { friend in
                    let already = playlist.contributorUids.contains(friend.uid)
                    Button { invite(friend) } label: {
                        HStack(spacing: 10) {
                            AvatarView(emoji: friend.avatarEmoji, colorHex: friend.avatarColor, size: 32)
                            Text(friend.username).foregroundStyle(Color.nodalong.textPrimary)
                            Spacer()
                            if already {
                                Text("Contributor").font(Font.nodalong.caption)
                                    .foregroundStyle(Color.nodalong.textSecondary)
                            } else if invited.contains(friend.uid) {
                                Image(systemName: "checkmark").foregroundStyle(Color.nodalong.purpleAccent)
                            } else if busy == friend.uid {
                                ProgressView()
                            } else {
                                Text("Invite").font(Font.nodalong.subheadlineSemibold)
                                    .foregroundStyle(Color.nodalong.purpleAccent)
                            }
                        }
                    }
                    .disabled(already || invited.contains(friend.uid) || busy != nil)
                }
                if let errorText {
                    Text(errorText).font(Font.nodalong.caption).foregroundStyle(.red)
                }
            }
            .navigationTitle("Invite a friend")
            .navigationBarTitleDisplayMode(.inline)
            // Let the mesh show through the bar instead of the opaque app-wide nav fill.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task {
                if let me = authVM.currentUser?.uid { friends = await mutualFriends(of: me) }
                loaded = true
            }
        }
    }

    private func invite(_ friend: UserProfile) {
        guard let me = authVM.profile else { return }
        busy = friend.uid
        errorText = nil
        Task {
            do {
                try await sendPlaylistInvite(to: friend.uid, from: me, playlistId: playlist.id, playlistTitle: playlist.title)
                invited.insert(friend.uid)
            } catch {
                errorText = "Couldn't invite \(friend.username)."
            }
            busy = nil
        }
    }
}
