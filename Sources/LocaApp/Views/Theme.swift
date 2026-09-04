import AppKit
import SwiftUI

/// The palette, and the semantic names the views actually use.
///
/// Five colours are given; every surface, text level, and state colour is
/// derived from them. Views never reach for a hex value or a system colour —
/// they ask for a role (`Theme.surface`, `Theme.textSecondary`), so a palette
/// change is one edit here rather than a search through every file.
///
/// Each role resolves per appearance, so the window follows the system rather
/// than committing to one look. Two of the five swap jobs between the schemes:
/// `#2E2E40` is the ground in dark and the text in light, and `#F2F2F2` is the
/// reverse. The accent is nudged darker in light mode — same hue, enough
/// contrast to read as text on a near-white card, which `#F2490C` alone does
/// not quite manage.
enum Theme {
    // MARK: - The palette

    /// `#2E2E40` — the dark end of the palette.
    static let base = Color(hex: 0x2E2E40)
    /// `#F2F2F2` — the light end.
    static let paper = Color(hex: 0xF2F2F2)
    /// `#F2490C` — the accent. Selection, primary actions, the numbers that
    /// matter.
    static let accent = dynamic(light: Color(hex: 0xD8420B), dark: Color(hex: 0xF2490C))
    /// `#F2A488` — the quiet half of the accent, for supporting emphasis that
    /// should not compete with a primary action.
    static let accentSoft = dynamic(
        light: Color(hex: 0xF2A488).shaded(by: 0.34), dark: Color(hex: 0xF2A488))
    /// `#F21313` — reserved for danger. Never decoration: if this colour
    /// appears, something is wrong or about to be destroyed.
    static let danger = dynamic(
        light: Color(hex: 0xF21313).shaded(by: 0.18), dark: Color(hex: 0xF21313))

    // MARK: - Surfaces

    /// The sidebar. Recessed in both schemes, so the content pane reads as
    /// nearer without needing a border to say so.
    static let sidebar = dynamic(
        light: paper.shaded(by: 0.05), dark: base.shaded(by: 0.42))

    /// The content pane.
    static let surface = dynamic(
        light: paper.tinted(by: 0.42), dark: base.shaded(by: 0.18))

    /// Cards and rows sitting on the content pane.
    static let card = dynamic(light: .white, dark: base)

    /// A raised row — hovered, or selected without being the accent.
    static let cardRaised = dynamic(light: paper, dark: base.tinted(by: 0.08))

    /// Hairlines. Low contrast on purpose: the layout is separated by shade and
    /// spacing, and borders only stop two planes bleeding into each other.
    static let stroke = dynamic(light: base.opacity(0.13), dark: paper.opacity(0.09))

    // MARK: - Text

    static let text = dynamic(light: base, dark: paper)
    static let textSecondary = dynamic(light: base.opacity(0.66), dark: paper.opacity(0.62))
    static let textTertiary = dynamic(light: base.opacity(0.45), dark: paper.opacity(0.38))
    /// For text and glyphs sitting on `accent`.
    static let onAccent = dynamic(light: .white, dark: Color(hex: 0x1A1A22))

    // MARK: - States

    static let running = dynamic(light: Color(hex: 0x1E9E6A), dark: Color(hex: 0x3DD68C))
    static let idle = dynamic(light: base.opacity(0.22), dark: paper.opacity(0.28))
    /// The inset background of a text field.
    static let inset = dynamic(light: paper.shaded(by: 0.03), dark: base.shaded(by: 0.30))

    // MARK: - Metrics

    static let cornerRadius: CGFloat = 10
    static let cardRadius: CGFloat = 12
    static let sidebarWidth: CGFloat = 216

    // MARK: - Appearance

    /// Resolves per appearance through `NSColor`'s dynamic provider, which is
    /// what lets these stay `static let` constants and still change with the
    /// system. Reading `@Environment(\.colorScheme)` would push the choice into
    /// every view that draws.
    private static func dynamic(light: Color, dark: Color) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(isDark ? dark : light)
            })
    }
}

// MARK: - Colour helpers

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }

    /// Mixes towards black. Used to derive darker planes from a palette colour,
    /// so every surface stays in the same hue family.
    func shaded(by amount: Double) -> Color {
        blended(with: .black, amount: amount)
    }

    /// Mixes towards white.
    func tinted(by amount: Double) -> Color {
        blended(with: .white, amount: amount)
    }

    private func blended(with other: Color, amount: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .black
        let t = min(max(amount, 0), 1)
        return Color(
            .sRGB,
            red: Double(a.redComponent + (b.redComponent - a.redComponent) * t),
            green: Double(a.greenComponent + (b.greenComponent - a.greenComponent) * t),
            blue: Double(a.blueComponent + (b.blueComponent - a.blueComponent) * t),
            opacity: Double(a.alphaComponent))
    }
}

// MARK: - Reusable pieces

/// A panel with a hairline, for grouping rows on the content pane.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.stroke, lineWidth: 1))
    }
}

/// A small capsule label. `tone` carries the meaning, so a caller never has to
/// pick a colour.
struct Badge: View {
    enum Tone {
        case neutral, accent, warning, danger, good
    }

    let text: String
    var tone: Tone = .neutral
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
            }
            Text(text)
        }
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(foreground)
        .background(foreground.opacity(0.14), in: Capsule())
    }

    private var foreground: Color {
        switch tone {
        case .neutral: Theme.textSecondary
        case .accent: Theme.accent
        case .warning: Theme.accentSoft
        case .danger: Theme.danger
        case .good: Theme.running
        }
    }
}

/// The primary action. One per screen — that is the whole point of it looking
/// like this.
struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(
                Theme.accent.opacity(configuration.isPressed ? 0.82 : 1),
                in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// A secondary action: readable, but visibly not the thing to press.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Theme.text.opacity(configuration.isPressed ? 0.16 : 0.08),
                in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

extension ButtonStyle where Self == AccentButtonStyle {
    static var accent: AccentButtonStyle { AccentButtonStyle() }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
}
