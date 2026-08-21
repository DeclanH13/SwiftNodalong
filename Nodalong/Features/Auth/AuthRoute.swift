/// Navigation destination for the unauthenticated `NavigationStack` —
/// used by `SplashView.navigationDestination(for:)` to push the right
/// auth screen.
enum AuthRoute: Hashable {
    case login
    case register
    case forgotPassword
}
