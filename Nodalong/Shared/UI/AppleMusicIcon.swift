import SwiftUI

/// A stylized "linked eighth notes" glyph, procedurally drawn — evokes Apple
/// Music's icon without reproducing Apple's own trademarked artwork (no
/// bundled image asset exists for it, and none is embedded here). Matches
/// this project's established preference for procedural rendering over
/// binary assets (see `AvatarView`).
private struct NoteGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        // Design space is a 24x24 box; scale proportionally into `rect`.
        let scale = min(rect.width, rect.height) / 24
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }
        func noteHead(center: CGPoint, radius: CGFloat) -> CGRect {
            CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        }

        var path = Path()
        path.addEllipse(in: noteHead(center: pt(6, 18), radius: 3.6 * scale))
        path.addEllipse(in: noteHead(center: pt(16.5, 15), radius: 3.6 * scale))
        path.addRect(CGRect(x: pt(8.7, 5.5).x, y: pt(8.7, 5.5).y, width: 2.1 * scale, height: 13 * scale))
        path.addRect(CGRect(x: pt(19.2, 2.5).x, y: pt(19.2, 2.5).y, width: 2.1 * scale, height: 13 * scale))
        path.move(to: pt(8.7, 5.5))
        path.addLine(to: pt(21.3, 2.5))
        path.addLine(to: pt(21.3, 6.2))
        path.addLine(to: pt(8.7, 9.2))
        path.closeSubpath()
        return path
    }
}

/// The small badge shown beside "Connect/Connected/Preview Apple Music" —
/// a white rounded-square containing a solid red `NoteGlyph`. Deliberately
/// solid, not an SF Symbol outline glyph.
struct AppleMusicIcon: View {
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Color.white)
            .frame(width: size, height: size)
            .overlay(
                NoteGlyph()
                    .fill(Color.nodalong.appleMusicRed)
                    .padding(size * 0.18)
            )
    }
}

#if DEBUG
#Preview {
    AppleMusicIcon(size: 44)
        .padding()
        .background(Color.nodalong.appleMusicRed)
}
#endif
