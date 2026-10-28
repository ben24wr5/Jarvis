import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// One colour scheme for the whole app (background, title, orb, text box, setup and Settings).
struct Palette: Identifiable, Equatable {
    let id: String
    let name: String
    let bgCenter: UInt32, bgMid: UInt32, bgEdge: UInt32   // background glow, centre → edge
    let primary: UInt32      // main colour: lines, outer rings, rim, buttons
    let secondary: UInt32    // second colour: middle rings, ripples, sparks
    let tertiary: UInt32     // third colour: inner rings, arcs, rays
    let light: UInt32        // brightest: orb core, title text, highlights
    let deep: UInt32         // dark tone inside the orb
    let text: UInt32         // body text
    let muted: UInt32        // quieter text and icons

    static let all: [Palette] = [
        Palette(id: "default", name: "Default (Blue)", bgCenter: 0x062042, bgMid: 0x020A17, bgEdge: 0x01040A,
                primary: 0x2FA8FF, secondary: 0x56C6FF, tertiary: 0x7FD8FF, light: 0xBFF0FF, deep: 0x0D3C78,
                text: 0x9FC4DA, muted: 0x6F9CB8),
        Palette(id: "redgold", name: "Red & Gold", bgCenter: 0x2A0606, bgMid: 0x120303, bgEdge: 0x060101,
                primary: 0xE0262E, secondary: 0xF5B82E, tertiary: 0xFF6A4F, light: 0xFFE6A8, deep: 0x5A0E10,
                text: 0xE8C9A0, muted: 0xA9806A),
        Palette(id: "gold", name: "Full Gold", bgCenter: 0x2A1F06, bgMid: 0x120D03, bgEdge: 0x060401,
                primary: 0xF2B632, secondary: 0xFFD36B, tertiary: 0xD99A1E, light: 0xFFF1C4, deep: 0x5A4110,
                text: 0xE6D3A3, muted: 0xA88F5C),
        Palette(id: "redgoldblue", name: "Red, Gold & Blue", bgCenter: 0x0A1430, bgMid: 0x060A1A, bgEdge: 0x02040A,
                primary: 0xE0262E, secondary: 0xF5B82E, tertiary: 0x2FA8FF, light: 0xFFF1C4, deep: 0x1A2A5A,
                text: 0xD8D4E0, muted: 0x8C93AE),
        Palette(id: "pink", name: "Full Pink", bgCenter: 0x2E0A22, bgMid: 0x160512, bgEdge: 0x070207,
                primary: 0xFF4FA8, secondary: 0xFF8CC6, tertiary: 0xFF2E8E, light: 0xFFD6EC, deep: 0x5A1240,
                text: 0xF0C2DA, muted: 0xB07A98),
        Palette(id: "pinkpurple", name: "Pink & Purple", bgCenter: 0x220A33, bgMid: 0x10051A, bgEdge: 0x05020A,
                primary: 0xFF4FA8, secondary: 0xA855F7, tertiary: 0xD88CFF, light: 0xF5D6FF, deep: 0x3E1260,
                text: 0xE2C8F0, muted: 0xA486B8),
        Palette(id: "redblack", name: "Red & Black", bgCenter: 0x1A0303, bgMid: 0x080101, bgEdge: 0x000000,
                primary: 0xE0262E, secondary: 0xFF4A4A, tertiary: 0xB3141B, light: 0xFFB3B3, deep: 0x3A0606,
                text: 0xD9A3A3, muted: 0x8F5C5C),
        Palette(id: "redblackwhite", name: "Red, Black & White", bgCenter: 0x1A0303, bgMid: 0x080101, bgEdge: 0x000000,
                primary: 0xE0262E, secondary: 0xFFFFFF, tertiary: 0xFF4A4A, light: 0xFFFFFF, deep: 0x3A0606,
                text: 0xEDEDED, muted: 0x9A9A9A),
        Palette(id: "purplewhite", name: "Purple & White", bgCenter: 0x1E0A33, bgMid: 0x0E051A, bgEdge: 0x04020A,
                primary: 0xA855F7, secondary: 0xFFFFFF, tertiary: 0xC99BFF, light: 0xFFFFFF, deep: 0x3A1663,
                text: 0xE9E0F5, muted: 0xA08CB8),
        Palette(id: "emerald", name: "Emerald", bgCenter: 0x04261A, bgMid: 0x02120C, bgEdge: 0x010604,
                primary: 0x10B981, secondary: 0x34D399, tertiary: 0x059669, light: 0xD1FAE5, deep: 0x064E3B,
                text: 0xA7D9C4, muted: 0x6B9F89)
    ]
}

/// Remembers the chosen theme and tells every screen to redraw when it changes.
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    private static let key = "theme"

    @Published var current: Palette {
        didSet { UserDefaults.standard.set(current.id, forKey: Self.key) }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.key)
        current = Palette.all.first { $0.id == saved } ?? Palette.all[0]
    }
}

enum Theme {
    static var p: Palette { ThemeStore.shared.current }

    static var deep: Color { Color(hex: p.bgEdge) }
    static var accent: Color { Color(hex: p.primary) }
    static var second: Color { Color(hex: p.secondary) }
    static var title: Color { Color(hex: p.light) }
    static var soft: Color { Color(hex: p.text) }
    static var muted: Color { Color(hex: p.muted) }
    static var button: Color { Color(hex: p.primary) }
    static var fieldFill: Color { Color(hex: p.deep, opacity: 0.45) }
    static var fieldBorder: Color { Color(hex: p.primary, opacity: 0.3) }

    static var background: some View {
        ZStack {
            deep
            RadialGradient(
                colors: [Color(hex: p.bgCenter), Color(hex: p.bgMid), deep],
                center: UnitPoint(x: 0.5, y: 0.52),
                startRadius: 0,
                endRadius: 820
            )
        }
        .ignoresSafeArea()
    }
}

/// The thin glowing line either side of the title.
struct TitleLine: Shape {
    var mirrored: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        if mirrored {
            p.move(to: CGPoint(x: rect.maxX, y: rect.minY + 3))
            p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.1, y: rect.minY + 3))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - 2))
        } else {
            p.move(to: CGPoint(x: rect.minX, y: rect.minY + 3))
            p.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.1, y: rect.minY + 3))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 2))
        }
        return p
    }
}

struct TitleView: View {
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        HStack(spacing: 28) {
            TitleLine(mirrored: false)
                .stroke(Theme.accent, lineWidth: 1.5)
                .shadow(color: Theme.accent, radius: 4)
                .frame(width: 300, height: 22)
            Text("OLED")
                .font(.system(size: 56, weight: .light, design: .default))
                .tracking(22)
                .padding(.leading, 22)
                .foregroundColor(Theme.title)
                .shadow(color: Theme.accent.opacity(0.65), radius: 14)
                .accessibilityLabel("O L E D")
            TitleLine(mirrored: true)
                .stroke(Theme.accent, lineWidth: 1.5)
                .shadow(color: Theme.accent, radius: 4)
                .frame(width: 300, height: 22)
        }
    }
}
