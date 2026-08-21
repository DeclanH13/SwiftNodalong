import SwiftUI
import NodalongKit

/// Emoji + colour picker for the user's Nodalong avatar.
///
/// Two scrollable grids:
/// 1. **Emoji** — pick an animal from the curated `userAvatarEmojis` set
/// 2. **Background colour** — pick a hex from `userAccentColors`
///
/// Both bindings update live; the parent view can render an `AvatarView`
/// alongside this picker to preview changes in real time. Used by
/// `RegisterView` (initial pick during sign-up) and `EditProfileView`
/// (later customisation).
struct AvatarPickerView: View {
    @Binding var selectedEmoji: String
    @Binding var selectedColor: String

    /// Colour for the "Animal"/"Background" section labels. Defaults to
    /// `textSecondary`, which is correct on `EditProfileView`'s `bgBase`
    /// surface — but this picker is ALSO shown on `RegisterView`, which
    /// sits on `bgDeep` (a mid-purple in both appearances), where dark ink
    /// only reaches ~2:1 and the labels are effectively invisible. That
    /// caller passes the `textOnAccent` family instead. Parameterised
    /// rather than changed outright so the EditProfile case is untouched.
    var labelColor: Color = Color.nodalong.textSecondary

    private let emojiColumns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 12), count: 6)
    private let colorColumns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 12), count: 5)

    var body: some View {
        VStack(spacing: 16) {
            emojiGrid
            colorGrid
        }
    }

    // MARK: - Emoji grid

    private var emojiGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Animal")
                .font(Font.nodalong.captionSemibold)
                .foregroundStyle(labelColor)
                .padding(.horizontal, 4)

            LazyVGrid(columns: emojiColumns, spacing: 10) {
                ForEach(userAvatarEmojis, id: \.self) { emoji in
                    let isSelected = selectedEmoji == emoji
                    Button {
                        selectedEmoji = emoji
                    } label: {
                        Text(emoji)
                            // Emoji, not text -- stays on the system font,
                            // matching `AvatarView`. Quicksand has no emoji
                            // glyphs, so routing it through the brand face
                            // would only risk odd metrics for no benefit.
                            .font(.system(size: 28))
                            .frame(width: 44, height: 44)
                            .background(
                                Circle()
                                    .fill(isSelected
                                          ? Color.nodalong.purpleMid.opacity(0.25)
                                          : Color.clear)
                            )
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        isSelected ? Color.nodalong.purpleAccent : Color.clear,
                                        lineWidth: 2
                                    )
                            )
                            .scaleEffect(isSelected ? 1.08 : 1.0)
                            .animation(.spring(response: 0.25), value: isSelected)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Colour grid

    private var colorGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Background")
                .font(Font.nodalong.captionSemibold)
                .foregroundStyle(labelColor)
                .padding(.horizontal, 4)

            LazyVGrid(columns: colorColumns, spacing: 12) {
                ForEach(userAccentColors, id: \.self) { hex in
                    let isSelected = selectedColor == hex
                    Button {
                        selectedColor = hex
                    } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 36, height: 36)
                            .overlay(
                                // Deliberately absolute white, not an
                                // adaptive token — needs to read as a
                                // selection ring against arbitrary avatar
                                // swatch colors, not the app's background.
                                Circle()
                                    .strokeBorder(
                                        isSelected ? Color.white : Color.clear,
                                        lineWidth: 3
                                    )
                            )
                            .scaleEffect(isSelected ? 1.15 : 1.0)
                            .animation(.spring(response: 0.2), value: isSelected)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

#if DEBUG
private struct AvatarPickerPreviewWrapper: View {
    @State private var emoji = "🐱"
    @State private var color = userAccentColors[0]
    var body: some View {
        VStack(spacing: 24) {
            AvatarView(emoji: emoji, colorHex: color, size: 80)
            AvatarPickerView(selectedEmoji: $emoji, selectedColor: $color)
        }
        .padding()
        .background(Color.black)
    }
}

#Preview {
    AvatarPickerPreviewWrapper()
}
#endif
