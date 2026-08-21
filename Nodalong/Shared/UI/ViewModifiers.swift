import SwiftUI

private struct AuthFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(Color.nodalong.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.nodalong.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
    }
}

extension View {
    func authFieldStyle() -> some View {
        modifier(AuthFieldModifier())
    }
}

#if DEBUG
#Preview("Auth field style") {
    VStack(spacing: 12) {
        TextField("Email", text: .constant("you@example.com"))
            .authFieldStyle()
        SecureField("Password", text: .constant("••••••••"))
            .authFieldStyle()
    }
    .padding(24)
    .background(Color.nodalong.bgBase)
}
#endif
