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

enum Theme {
    static let deep = Color(hex: 0x01040A)
    static let accent = Color(hex: 0x2FA8FF)
    static let title = Color(hex: 0x7FD8FF)
    static let soft = Color(hex: 0x9FC4DA)
    static let muted = Color(hex: 0x6F9CB8)
    static let button = Color(hex: 0x1D8FE0)

    static var background: some View {
        ZStack {
            deep
            RadialGradient(
                colors: [Color(hex: 0x062042), Color(hex: 0x020A17), deep],
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
