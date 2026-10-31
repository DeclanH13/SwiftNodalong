import SwiftUI
import NodalongKit

/// Bottom sheet that lets the user add a single `Song` to one of their
/// playlists, or spin up a new playlist and add to it in one step.
///
/// Presented from the app-wide track "..." action menu (`TrackActionsMenuButton`),
/// so it relies on the environment's `PlaylistsViewModel` + `FirebaseAuthViewModel`.
struct AddToPlaylistSheet: View {
    let song: Song

    @Environment(FirebaseAuthViewModel.self) private var authVM
    @EnvironmentObject private var playlistsVM: PlaylistsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showCreate = false
    @State private var busyId: String? = nil
    @State private var addedId: String? = nil

    var body: some View {
        NavigationStack {
            List {
                Button { showCreate = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus")
                            .font(Font.nodalong.headline)
                            .foregroundStyle(Color.nodalong.purpleAccent)
                            .frame(width: 44, height: 44)
                            .background(Color.nodalong.bgCard)
                            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                        Text("New Playlist")
                            .font(Font.nodalong.subheadlineSemibold)
                            .foregroundStyle(Color.nodalong.textPrimary)
                        Spacer()
                    }
                }
                .listRowBackground(Color.nodalong.bgCard)

                ForEach(playlistsVM.playlists) { playlist in
                    Button { add(to: playlist) } label: { row(playlist) }
                        .listRowBackground(Color.nodalong.bgCard)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            // Let the mesh show through the bar instead of the opaque app-wide nav fill.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.nodalong.purpleAccent)
                }
            }
            .task {
                if let uid = authVM.currentUser?.uid { await playlistsVM.load(uid: uid) }
            }
            .sheet(isPresented: $showCreate) {
                CreatePlaylistSheet { newId in
                    // Add straight into the just-created playlist.
                    add(to: newId)
                }
            }
        }
    }

    private func row(_ playlist: Playlist) -> some View {
        HStack(spacing: 12) {
            ArtworkThumbnail(url: playlist.coverArtwork, size: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title)
                    .font(Font.nodalong.subheadlineMedium)
                    .foregroundStyle(Color.nodalong.textPrimary)
                    .lineLimit(1)
                Text("\(playlist.trackCount) track\(playlist.trackCount == 1 ? "" : "s")")
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textSecondary)
            }
            Spacer()
            if busyId == playlist.id {
                ProgressView().tint(Color.nodalong.textSecondary)
            } else if addedId == playlist.id {
                Image(systemName: Icons.checkmarkCircle)
                    .foregroundStyle(Color.nodalong.gold)
            }
        }
    }

    private func add(to playlist: Playlist) { add(to: playlist.id) }

    private func add(to playlistId: String) {
        guard let profile = authVM.profile, busyId == nil else { return }
        Task {
            busyId = playlistId
            await playlistsVM.addTrack(playlistId: playlistId, song: song, profile: profile)
            busyId = nil
            addedId = playlistId
            try? await Task.sleep(nanoseconds: 500_000_000)
            dismiss()
        }
    }
}

/// Sheet for creating a new playlist (name + visibility). Calls `onCreated`
/// with the new playlist id so callers can chain an action (e.g. add a track).
struct CreatePlaylistSheet: View {
    /// Invoked with the new playlist's id once created.
    var onCreated: ((String) -> Void)? = nil

    @Environment(FirebaseAuthViewModel.self) private var authVM
    @EnvironmentObject private var playlistsVM: PlaylistsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var visibility: PlaylistVisibility = .friends
    @State private var busy = false

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Playlist name", text: $title)
                        .foregroundStyle(Color.nodalong.textPrimary)
                }
                .listRowBackground(Color.nodalong.bgCard)

                Section("Who can see it") {
                    Picker("Visibility", selection: $visibility) {
                        ForEach(PlaylistVisibility.allCases, id: \.self) { v in
                            Text(visibilityLabel(v)).tag(v)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.nodalong.bgCard)
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("New Playlist")
            .navigationBarTitleDisplayMode(.inline)
            // Let the mesh show through the bar instead of the opaque app-wide nav fill.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.nodalong.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .foregroundStyle(Color.nodalong.purpleAccent)
                        .disabled(trimmedTitle.isEmpty || busy)
                }
            }
        }
    }

    private func visibilityLabel(_ v: PlaylistVisibility) -> String {
        switch v {
        case .private: return "Only me"
        case .friends: return "Friends"
        case .public:  return "Everyone"
        }
    }

    private func create() {
        guard let profile = authVM.profile, !trimmedTitle.isEmpty, !busy else { return }
        Task {
            busy = true
            let newId = await playlistsVM.create(profile: profile, title: trimmedTitle, visibility: visibility)
            busy = false
            if let newId { onCreated?(newId) }
            dismiss()
        }
    }
}

#if DEBUG
#Preview("Add to Playlist") {
    AddToPlaylistSheet(song: PreviewFixtures.song).withPreviewEnvironment()
}

#Preview("Create Playlist") {
    CreatePlaylistSheet().withPreviewEnvironment()
}
#endif
