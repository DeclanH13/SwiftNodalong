import SwiftUI

/// Minimal left/right pagination row for a `TabView(.page(indexDisplayMode:
/// .never))` carousel — bare chevron glyphs (no background circle, no
/// border), dimmed via `textTertiary` and `.disabled(...)` at either end
/// rather than hidden, matching `SpotlightCarousel`'s own established arrow
/// style exactly (that carousel already looked right; this factors the same
/// pattern out for reuse instead of inventing a second, more prominent one).
///
/// Sits in its own row ABOVE the paged content, not floating as an overlay
/// on top of it — a floating corner overlay (tried once for
/// `DiscographyPageGrid`) collided with the last row's caption text on a
/// short page. A dedicated row has no content to collide with by
/// construction.
struct PageArrowsRow: View {
    @Binding var pageIndex: Int
    let pageCount: Int
    /// Optional center label (e.g. `SpotlightCarousel`'s "Today"/date text).
    /// `nil` collapses to just the two arrows with a `Spacer` between them.
    var label: String? = nil

    var body: some View {
        HStack {
            Button {
                withAnimation { pageIndex -= 1 }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(pageIndex == 0 ? Color.nodalong.textTertiary : Color.nodalong.textPrimary)
            }
            .disabled(pageIndex == 0)

            Spacer()

            if let label {
                Text(label)
                    .font(Font.nodalong.subheadlineMedium)
                    .foregroundStyle(Color.nodalong.textPrimary)
                Spacer()
            }

            Button {
                withAnimation { pageIndex += 1 }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(pageIndex == pageCount - 1 ? Color.nodalong.textTertiary : Color.nodalong.textPrimary)
            }
            .disabled(pageIndex == pageCount - 1)
        }
    }
}
