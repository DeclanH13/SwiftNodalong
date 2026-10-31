import SwiftUI
import NodalongKit

/// "Send to a friend" — pick one mutual follow, add an optional note, send.
/// A friend here is a mutual follow (`friendUids`), which is also exactly what
/// `firestore.rules` requires for the inbox write, so the picker can't offer
/// someone the rules would reject.
struct SendSongSheet: View {
    let song: Song

    @Environment(\.dismiss) private var dismiss
    @Environment(FirebaseAuthViewModel.self) private var authVM

    @State private var friends: [UserProfile] = []
    @State private var loaded = false
    @State private var note = ""
    @State private var sendingTo: String?
    @State private var sentTo: Set<String> = []
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Add a note (optional)", text: $note)
                        .onChange(of: note) { _, v in
                            if v.count > inboxNoteMaxLength { note = String(v.prefix(inboxNoteMaxLength)) }
                        }
                } footer: {
                    Text("\(song.title) — \(song.artist)")
                }
                Section("Friends") {
                    if !loaded {
                        ProgressView()
                    } else if friends.isEmpty {
                        Text("You can send songs to people you follow who follow you back.")
                            .font(Font.nodalong.caption)
                            .foregroundStyle(Color.nodalong.textSecondary)
                    }
                    ForEach(friends, id: \.uid) { friend in
                        Button { send(to: friend) } label: {
                            HStack(spacing: 10) {
                                AvatarView(emoji: friend.avatarEmoji, colorHex: friend.avatarColor, size: 32)
                                Text(friend.username).foregroundStyle(Color.nodalong.textPrimary)
                                Spacer()
                                if sentTo.contains(friend.uid) {
                                    Image(systemName: "checkmark").foregroundStyle(Color.nodalong.purpleAccent)
                                } else if sendingTo == friend.uid {
                                    ProgressView()
                                } else {
                                    Text("Send").font(Font.nodalong.subheadlineSemibold)
                                        .foregroundStyle(Color.nodalong.purpleAccent)
                                }
                            }
                        }
                        .disabled(sentTo.contains(friend.uid) || sendingTo != nil)
                    }
                }
                if let errorText {
                    Text(errorText).font(Font.nodalong.caption).foregroundStyle(.red)
                }
            }
            .navigationTitle("Send to a friend")
            .navigationBarTitleDisplayMode(.inline)
            // Let the mesh show through the bar instead of the opaque app-wide nav fill.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { await loadFriends() }
        }
    }

    private func loadFriends() async {
        guard let me = authVM.currentUser?.uid else { loaded = true; return }
        friends = await mutualFriends(of: me)
        loaded = true
    }

    private func send(to friend: UserProfile) {
        guard let me = authVM.profile else { return }
        sendingTo = friend.uid
        errorText = nil
        Task {
            do {
                // The inbox row stores only a catalogId (the catalog is the
                // source of truth for metadata) — make sure one exists.
                let catalogId = (song.catalogId?.isEmpty == false) ? song.catalogId! : try await ensureCatalogId(for: song)
                try await sendSongToInbox(to: friend.uid, from: me, catalogId: catalogId, note: note)
                sentTo.insert(friend.uid)
            } catch {
                errorText = "Couldn't send to \(friend.username)."
            }
            sendingTo = nil
        }
    }
}

/// People who follow `uid` AND whom `uid` follows — the only people the inbox
/// rules let them send to. Shared by every "pick a friend" surface.
func mutualFriends(of uid: String) async -> [UserProfile] {
    async let following = SocialCache.shared.followList(uid: uid, mode: .following)
    async let followers = SocialCache.shared.followList(uid: uid, mode: .followers)
    let (a, b) = await (following, followers)
    let ids = friendUids(following: a.map(\.uid), followers: b.map(\.uid))
    let byUid = Dictionary(a.map { ($0.uid, $0) }, uniquingKeysWith: { x, _ in x })
    return ids.compactMap { byUid[$0] }
}
