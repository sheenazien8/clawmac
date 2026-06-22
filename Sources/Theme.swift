import SwiftUI

// MARK: - OpenClaw Theme
enum OpenClawTheme {
    // Base Colors - Lobster Red
    static let primaryStart = Color(hex: "#ff4d4d")
    static let primaryEnd = Color(hex: "#991b1b")
    static let primary = Color(hex: "#e11d48")
    
    // Background
    static let background = Color(hex: "#0a0a0f")
    static let surface = Color(hex: "#12121a")
    static let surfaceHighlight = Color(hex: "#1e1e2e")
    
    // Text
    static let textPrimary = Color.white
    static let textSecondary = Color(hex: "#a1a1aa")
    static let textMuted = Color(hex: "#71717a")
    
    // Gradients
    static var primaryGradient: LinearGradient {
        LinearGradient(
            colors: [primaryStart, primaryEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    
    static var glassGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.1),
                Color.white.opacity(0.05)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Color Extension
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - View Modifiers
struct GlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial)
            .background(OpenClawTheme.glassGradient)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .cornerRadius(16)
    }
}

struct GlowModifier: ViewModifier {
    let color: Color
    
    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(0.3), radius: 8, x: 0, y: 4)
    }
}

extension View {
    func glass() -> some View {
        modifier(GlassModifier())
    }
    
    func glow(color: Color = OpenClawTheme.primary) -> some View {
        modifier(GlowModifier(color: color))
    }
}
