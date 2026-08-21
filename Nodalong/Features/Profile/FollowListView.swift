import SwiftUI
import NodalongKit

enum FollowListMode: Hashable {
    case followers, following
}

/// A fully-specified follow-list push: **which user's** list, and which half
/// of it.
///
/// Replaces pushing a bare `FollowListMode`, which carried no uid — so the
/// uid came from whichever screen's `.navigationDestination` closure happened
/// to run. `ProfileView` (yours) and `UserProfileView` (theirs) both
/// registered a destination for that same type, and reaching someone's
/// profile from your own Profile tab put BOTH registrations on one stack.
/// This codebase already established that SwiftUI resolves such a duplicate
/// in favour of the registration closest to the stack ROOT — so tapping
/// *their* follower count pushed a list built from *your* uid.
///
/// Carrying the uid in the value removes the ambiguity entirely: there is now
/// exactly one registration (per tab root, alongside `UserProfile`'s), and it
/// can't build the wrong list because everything it needs is in the value.
struct FollowListTarget: Hashable {
    let uid: String
    let username: String
    let mode: FollowListMode
}

/// Modal list of followers or following for a given user.
///
/// One screen, two modes (`.followers` | `.following`). Tap an entry to
/// navigate to their `UserProfileView`; toggle follow inline.
struct FollowListView: View {
    let uid:  String
    let mode: FollowListMode
    /// Shown in the nav title so it's unambiguous whose list this is —
    /// previously impossible, since the pushed value carried no identity.
    var username: String = ""

    @Environment(FirebaseAuthViewModel.self) private var authVM

    @State private var profiles:      [UserProfile] = []
    @State private var followingUids: Set<String> = []
    @State private var isLoading     = true

    /// "Followers" for your own list, "<name>'s Followers" for someone
    /// else's — the screen used to be unable to say whose list it was.
    private var followListTitle: String {
        let base = mode == .followers ? "Followers" : "Following"
        let isMe = uid == authVM.currentUser?.uid
        guard !isMe, !username.isEmpty else { return base }
        return "\(username)'s \(base)"
    }

    var body: some View {
        List {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.nodalong.bgCard)
            } else if profiles.isEmpty {
                Text(mode == .followers ? "No followers yet" : "Not following anyone")
                    .foregroundStyle(Color.nodalong.textSecondary)
                    .listRowBackground(Color.nodalong.bgCard)
            } else {
                ForEach(profiles, id: \.uid) { profile in
                    NavigationLink(value: profile) {
                        HStack(spacing: 12) {
                            AvatarView(emoji: profile.avatarEmoji, colorHex: profile.avatarColor, size: 36)
                            Text(profile.username)
                                .font(Font.nodalong.subheadlineMedium)
                                .foregroundStyle(Color.nodalong.textPrimary)
                            Spacer()
                            if profile.uid != authVM.currentUser?.uid {
                                followButton(for: profile)
                            }
                        }
                    }
                    .listRowBackground(Color.nodalong.bgCard)
                }
            }

        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.nodalong.bgBase)
        .navigationTitle(followListTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @ViewBuilder
    private func followButton(for profile: UserProfile) -> some View {
        let isFollowing = followingUids.contains(profile.uid)
        Button(isFollowing ? "Following" : "Follow") {
            toggle(profile: profile)
        }
        .font(Font.nodalong.captionSemibold)
        .foregroundStyle(isFollowing ? Color.nodalong.textSecondary : Color.nodalong.purpleAccent)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .overlay(
            RoundedRectangle(cornerRadius: Corner.container, style: .continuous)
                .stroke(isFollowing ? Color.nodalong.textSecondary : Color.nodalong.purpleAccent, lineWidth: 1)
        )
        // `.borderless` (not `.plain`) — inside a `NavigationLink` row in a
        // `List`, this is what keeps the button's own tap from also
        // activating the row's navigation.
        .buttonStyle(.borderless)
    }

    private func load() async {
        isLoading = true
        // Independent of the followers/following fetch below (only needs
        // `myUid`, not `entries`) — hoisted into `async let` so it runs
        // concurrently instead of after, cutting one round-trip off the total.
        async let myFollowingResult: [(uid: String, username: String)] = {
            guard let myUid = authVM.currentUser?.uid else { return [] }
            return (try? await getFollowedEntries(uid: myUid)) ?? []
        }()

        let entries = mode == .followers
            ? (try? await getFollowersList(uid: uid)) ?? []
            : (try? await getFollowingList(uid: uid)) ?? []
        // Enrich the bare (uid, username) entries into full UserProfiles for
        // avatar display + profile navigation; preserve the original order,
        // dropping any uid whose profile fetch is missing (e.g. a deleted
        // account) instead of showing a blank row.
        let fetched = (try? await getUserProfiles(uids: entries.map(\.uid))) ?? []
        let byUid = Dictionary(uniqueKeysWithValues: fetched.map { ($0.uid, $0) })
        profiles = entries.compactMap { byUid[$0.uid] }
        followingUids = Set((await myFollowingResult).map { $0.uid })
        isLoading = false
    }

    private func toggle(profile: UserProfile) {
        guard let myUid     = authVM.currentUser?.uid,
              let myUsername = authVM.profile?.username else { return }
        if followingUids.contains(profile.uid) {
            followingUids.remove(profile.uid)
            Task {
                do { try await unfollowUser(myUid: myUid, targetUid: profile.uid) }
                catch { followingUids.insert(profile.uid) }
            }
        } else {
            followingUids.insert(profile.uid)
            Task {
                do { try await followUser(myUid: myUid, myUsername: myUsername,
                                          targetUid: profile.uid, targetUsername: profile.username) }
                catch { followingUids.remove(profile.uid) }
            }
        }
    }
}

#if DEBUG
#Preview("Followers") {
    NavigationStack {
        FollowListView(uid: PreviewFixtures.myUid, mode: .followers)
    }
    .withPreviewEnvironment()
}

#Preview("Following") {
    NavigationStack {
        FollowListView(uid: PreviewFixtures.myUid, mode: .following)
    }
    .withPreviewEnvironment()
}
#endif
