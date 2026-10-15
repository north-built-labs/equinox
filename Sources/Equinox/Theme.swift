import SwiftUI

enum Theme {
    static let cyan = Color(red: 0.25, green: 0.88, blue: 1.0)
    static let violet = Color(red: 0.62, green: 0.38, blue: 1.0)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.25)
    static let background = Color(red: 0.055, green: 0.06, blue: 0.09)
    static let accent = LinearGradient(colors: [cyan, violet], startPoint: .leading, endPoint: .trailing)

    static func bandColor(_ index: Int) -> Color {
        Color(hue: (0.52 + Double(index % 8) * 0.045).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 1)
    }

    static func hz(_ f: Double) -> String {
        f >= 1000 ? String(format: f >= 10_000 ? "%.0fk" : "%.1fk", f / 1000) : String(format: "%.0f", f)
    }
}

struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 16
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.padding(padding).glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content.padding(padding)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.white.opacity(0.08)))
        }
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 16, padding: CGFloat = 14) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, padding: padding))
    }
}
