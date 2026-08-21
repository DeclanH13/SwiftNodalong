import SwiftUI
import NodalongKit

/// Edit username, bio, and avatar (character + color).
///
/// Modal sheet pushed from `ProfileView`. Calls
/// `FirebaseAuthViewModel.updateProfile` on save, which writes to Firestore
/// and refreshes the local profile.
struct EditProfileView: View {
    @Environment(FirebaseAuthViewModel.self) private var authVM
    @Environment(\.dismiss) private var dismiss

    @State private var username      = ""
    @State private var bio           = ""
    @State private var selectedEmoji = userAvatarEmojis[1]
    @State private var selectedColor = userAccentColors[0]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    AvatarView(emoji: selectedEmoji, colorHex: selectedColor, size: 96)

                    AvatarPickerView(
                        selectedEmoji: $selectedEmoji,
                        selectedColor: $selectedColor
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Username")
                            .font(Font.nodalong.footnoteMedium)
                            .foregroundStyle(Color.nodalong.textSecondary)
                        TextField("Username", text: $username)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Color.nodalong.bgCard)
                            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                            .foregroundStyle(Color.nodalong.textPrimary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Bio")
                            .font(Font.nodalong.footnoteMedium)
                            .foregroundStyle(Color.nodalong.textSecondary)
                        TextField("Tell people about yourself", text: $bio, axis: .vertical)
                            .lineLimit(3...5)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Color.nodalong.bgCard)
                            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                            .foregroundStyle(Color.nodalong.textPrimary)
                    }
                    
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
            }
            .background(Color.nodalong.bgBase)
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.nodalong.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if authVM.isSubmitting {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task {
                                await authVM.updateProfile(
                                    username:    username,
                                    bio:         bio,
                                    avatarEmoji: selectedEmoji,
                                    avatarColor: selectedColor
                                )
                                dismiss()
                            }
                        }
                        .foregroundStyle(Color.nodalong.purpleAccent)
                        .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .task {
            username      = authVM.profile?.username ?? ""
            bio           = authVM.profile?.bio ?? ""
            selectedEmoji = authVM.profile?.avatarEmoji ?? userAvatarEmojis[1]
            selectedColor = authVM.profile?.avatarColor ?? userAccentColors[0]
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack { EditProfileView() }.withPreviewEnvironment()
}
#endif
