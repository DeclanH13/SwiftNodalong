import SwiftUI

/// Welcome screen with Sign In / Create Account buttons.
///
/// Shown to unauthenticated users as the entry point to the auth navigation
/// stack. The Sign In button pushes `LoginView`; Create Account pushes
/// `RegisterView`.
struct SplashView: View {
    var body: some View {
        ZStack {
            Color.nodalong.bgDeep.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 8) {
                    NodalongMark(size: 96)
                        .foregroundStyle(Color.nodalong.textOnAccent)
                        .padding(.bottom, 8)
                    Text("Nodalong")
                        .font(Font.nodalong.custom(42, .bold))
                        .foregroundStyle(Color.nodalong.textOnAccent)
                    Text("Share the music you love")
                        .font(Font.nodalong.subheadline)
                        .foregroundStyle(Color.nodalong.textOnAccent.opacity(0.65))
                }

                Spacer()

                VStack(spacing: 12) {
                    NavigationLink(value: AuthRoute.login) {
                        Text("Sign In")
                            .font(Font.nodalong.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.nodalong.purpleMid)
                            .foregroundStyle(Color.nodalong.textOnAccent)
                            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                    }

                    NavigationLink(value: AuthRoute.register) {
                        Text("Create Account")
                            .font(Font.nodalong.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.nodalong.textOnAccent.opacity(0.08))
                            .foregroundStyle(Color.nodalong.textOnAccent)
                            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: Corner.container, style: .continuous)
                                    .strokeBorder(Color.nodalong.textOnAccent.opacity(0.35), lineWidth: 1)
                            )
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 52)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

#Preview("Splash") {
    NavigationStack {
        SplashView()
            .navigationDestination(for: AuthRoute.self) { route in
                switch route {
                case .login:          LoginView()
                case .register:       RegisterView()
                case .forgotPassword: ForgotPasswordView()
                }
            }
    }
    .environment(FirebaseAuthViewModel())
}
