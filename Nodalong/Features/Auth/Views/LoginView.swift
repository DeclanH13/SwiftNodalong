import SwiftUI

/// Email/password sign-in screen.
///
/// Two text fields + submit. Calls `FirebaseAuthViewModel.signIn`. Links to
/// `RegisterView` and `ForgotPasswordView`. Error messages render inline from
/// `authVM.authError`.
struct LoginView: View {
    @Environment(FirebaseAuthViewModel.self) private var authVM
    @State private var email = ""
    @State private var password = ""
    @FocusState private var focusedField: Field?

    private enum Field { case email, password }

    var body: some View {
        VStack(spacing: 0) {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 6) {
                    NodalongMark(size: 64)
                        .foregroundStyle(Color.nodalong.textOnAccent)
                        .padding(.bottom, 4)
                    Text("Welcome back")
                        .font(Font.nodalong.titleBold)
                        .foregroundStyle(Color.nodalong.textOnAccent)
                    Text("Sign in to your account")
                        .foregroundStyle(Color.nodalong.textOnAccent.opacity(0.75))
                }
                .padding(.top, 32)

                VStack(spacing: 12) {
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
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { submitSignIn() }
                        .authFieldStyle()
                }

                if let error = authVM.authError {
                    Text(error)
                        .font(Font.nodalong.footnote)
                        .foregroundStyle(Color.nodalong.error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: submitSignIn) {
                    Group {
                        if authVM.isSubmitting {
                            ProgressView().tint(.white)
                        } else {
                            Text("Sign In").font(Font.nodalong.headline)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .background(Color.nodalong.purpleMid)
                .foregroundStyle(Color.nodalong.textOnAccent)
                .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                .disabled(authVM.isSubmitting || email.isEmpty || password.isEmpty)

                NavigationLink(value: AuthRoute.forgotPassword) {
                    Text("Forgot password?")
                        .font(Font.nodalong.footnote)
                        .foregroundStyle(Color.nodalong.textOnAccent.opacity(0.85))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        }
        .background(Color.nodalong.bgDeep.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        // `textOnAccent`, not the default: these sit on `bgDeep`, where the
        // default dark ink measures ~2:1 in light mode. See `screenControls`.
        .screenControls(tint: Color.nodalong.textOnAccent)
        .onDisappear { authVM.authError = nil }
    }

    private func submitSignIn() {
        guard !email.isEmpty, !password.isEmpty else { return }
        Task { await authVM.signIn(email: email, password: password) }
    }
}

#if DEBUG
#Preview {
    NavigationStack { LoginView() }.withPreviewEnvironment()
}
#endif
