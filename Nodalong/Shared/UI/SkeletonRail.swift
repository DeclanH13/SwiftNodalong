import SwiftUI

/// Placeholder horizontal rail matching Home's carousel geometry — shown only
/// on a true first-ever launch (no cached snapshot yet, network still in
/// flight), so the screen reads as "content is loading" instead of just
/// showing the greeting with nothing else, then popping sections in with no
/// warning. Disabled for scrolling since it has nothing real to scroll to.
struct SkeletonRail: View {
    var tileSize: CGFloat = 140

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        ShimmerView()
                            .frame(width: tileSize, height: tileSize)
                            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                        ShimmerView()
                            .frame(width: tileSize * 0.7, height: 12)
                            .clipShape(Capsule())
                        ShimmerView()
                            .frame(width: tileSize * 0.45, height: 10)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollDisabled(true)
    }
}

#if DEBUG
#Preview {
    SkeletonRail()
        .padding(.vertical)
        .background(Color.nodalong.bgBase)
}
#endif
