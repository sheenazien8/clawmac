import SwiftUI

// MARK: - macOS Standard Theme
enum OpenClawTheme {
    // macOS System Colors
    static let primary = Color.accentColor  // System accent color
    static let primaryStart = Color.blue
    static let primaryEnd = Color.blue.opacity(0.8)
    
    // Background - Use system colors
    static let background = Color(.windowBackgroundColor)
    static let surface = Color(.controlBackgroundColor)
    static let surfaceHighlight = Color(.textBackgroundColor)
    
    // Text - Use system colors
    static let textPrimary = Color(.labelColor)
    static let textSecondary = Color(.secondaryLabelColor)
    static let textMuted = Color(.tertiaryLabelColor)
    
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
                Color.white.opacity(0.8),
                Color.white.opacity(0.6)
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
            .background(.thinMaterial)
            .cornerRadius(16)
    }
}

struct GlowModifier: ViewModifier {
    let color: Color
    
    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(0.2), radius: 4, x: 0, y: 2)
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
