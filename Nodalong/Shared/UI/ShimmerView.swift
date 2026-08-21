import SwiftUI
import NodalongKit

/// Animated shimmer placeholder rendered wherever network artwork is loading.
///
/// A subtle highlight gradient sweeps left-to-right on a dark base, signalling
/// "content is loading" rather than "something is broken." Shown in the
/// `.empty` phase of every `AsyncImage`/`CachedArtworkImage` that fetches a
/// remote URL.
///
/// **Bounded, not `repeatForever`.** This is used as a permanent-loading
/// placeholder in a few places (`ShelfView`'s "still resolving" state), so a
/// tile whose artwork never resolves would otherwise shimmer at up to 60fps
/// for the entire session — real, measurable idle CPU with nothing to show
/// for it. After `maxSweeps` passes it settles to the static base color; a
/// placeholder that's been "loading" for ~7 seconds reads as done trying,
/// not broken, which is the honest state.
struct ShimmerView: View {
    @State private var phase: CGFloat = 0
    private static let maxSweeps = 6

    var body: some View {
        Color.nodalong.bgCard
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, Color.nodalong.textPrimary.opacity(0.06), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    // Double the width so the highlight fully crosses the view
                    .frame(width: geo.size.width * 2)
                    // phase 0 → highlight is off the left edge
                    // phase 1 → highlight is off the right edge
                    .offset(x: geo.size.width * (phase * 3 - 1.5))
                }
                .clipped()
            )
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatCount(Self.maxSweeps, autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 12) {
        ShimmerView()
            .frame(width: 160, height: 160)
            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        ShimmerView()
            .frame(width: 48, height: 48)
            .clipShape(Circle())
    }
    .padding()
    .background(Color.black)
}
#endif
