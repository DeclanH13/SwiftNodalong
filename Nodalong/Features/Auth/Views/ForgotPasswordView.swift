import SwiftUI

/// Sends a Firebase password-reset email.
///
/// Always shows success without revealing whether the email is registered.
struct ForgotPasswordView: View {
    @Environment(FirebaseAuthViewModel.self) private var authVM
    @State private var email = ""
    @State private var isSent = false
    @State private var isSending = false
    @FocusState private var emailFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 6) {
                    Text("Reset password")
                        .font(Font.nodalong.titleBold)
                        .foregroundStyle(Color.nodalong.textOnAccent)
                    Text("We'll send you a reset link")
                        .foregroundStyle(Color.nodalong.textOnAccent.opacity(0.75))
                }
                .padding(.top, 32)

                if isSent {
                    sentConfirmation
                } else {
                    sendForm
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
    }

    private var sendForm: some View {
        VStack(spacing: 16) {
            TextField("Email", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($emailFocused)
                .submitLabel(.send)
                .onSubmit { submitReset() }
                .authFieldStyle()

            Button(action: submitReset) {
                Group {
                    if isSending {
                        ProgressView().tint(.white)
                    } else {
                        Text("Send Reset Link").font(Font.nodalong.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .background(Color.nodalong.purpleMid)
            .foregroundStyle(Color.nodalong.textOnAccent)
            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
            .disabled(isSending || email.isEmpty)
        }
    }

    private var sentConfirmation: some View {
        VStack(spacing: 12) {
            Image(systemName: Icons.checkmarkCircle)
                .font(.system(size: 52))
                .foregroundStyle(Color.nodalong.textOnAccent)
            Text("Check your email")
                .font(Font.nodalong.headline)
                .foregroundStyle(Color.nodalong.textOnAccent)
            Text("If an account exists for \(email), you'll receive a password reset link shortly.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.nodalong.textOnAccent.opacity(0.75))
                .font(Font.nodalong.footnote)
        }
        .padding(.top, 8)
    }

    private func submitReset() {
        guard !email.isEmpty else { return }
        isSending = true
        Task {
            // Always show success — don't reveal whether the email exists.
            try? await authVM.forgotPassword(email: email)
            isSent = true
            isSending = false
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack { ForgotPasswordView() }.withPreviewEnvironment()
}
#endif
