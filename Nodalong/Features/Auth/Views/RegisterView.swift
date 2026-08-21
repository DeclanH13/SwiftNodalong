import SwiftUI
import NodalongKit

/// Email/password registration with avatar picker.
///
/// Form: email, password, username, avatar character + color (via
/// `AvatarPickerView`). On submit, calls `FirebaseAuthViewModel.register`,
/// which creates the Firebase user and writes the initial `users/{uid}` doc.
struct RegisterView: View {
    @Environment(FirebaseAuthViewModel.self) private var authVM
    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var selectedEmoji = userAvatarEmojis[1]   // 🐱 by default
    @State private var selectedColor = userAccentColors[0]
    @FocusState private var focusedField: Field?

    private enum Field { case username, email, password }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 6) {
                    NodalongMark(size: 64)
                        .foregroundStyle(Color.nodalong.textOnAccent)
                        .padding(.bottom, 4)
                    Text("Create account")
                        .font(Font.nodalong.titleBold)
                        .foregroundStyle(Color.nodalong.textOnAccent)
                    Text("Join Nodalong today")
                        .foregroundStyle(Color.nodalong.textOnAccent.opacity(0.75))
                }
                .padding(.top, 32)

                // Live avatar preview
                AvatarView(emoji: selectedEmoji, colorHex: selectedColor, size: 96)

                AvatarPickerView(
                    selectedEmoji: $selectedEmoji,
                    selectedColor: $selectedColor,
                    labelColor: Color.nodalong.textOnAccent.opacity(0.75)
                )

                VStack(spacing: 12) {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .email }
                        .authFieldStyle()

                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                        .authFieldStyle()

                    SecureField("Password", text: $password)
                        .textContentType(.newPassword)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { submitRegister() }
                        .authFieldStyle()
                }

                if let error = authVM.authError {
                    Text(error)
                        .font(Font.nodalong.footnote)
                        .foregroundStyle(Color.nodalong.error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: submitRegister) {
                    Group {
                        if authVM.isSubmitting {
                            ProgressView().tint(.white)
                        } else {
                            Text("Create Account").font(Font.nodalong.headline)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .background(Color.nodalong.purpleMid)
                .foregroundStyle(Color.nodalong.textOnAccent)
                .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                .disabled(authVM.isSubmitting || username.isEmpty || email.isEmpty || password.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .background(Color.nodalong.bgDeep.ignoresSafeArea())
        .navigationTitle("Create Account")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { authVM.authError = nil }
    }

    private func submitRegister() {
        guard !username.isEmpty, !email.isEmpty, !password.isEmpty else { return }
        Task {
            await authVM.register(
                email: email,
                password: password,
                username: username,
                avatarEmoji: selectedEmoji,
                avatarColor: selectedColor
            )
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack { RegisterView() }.withPreviewEnvironment()
}
#endif
