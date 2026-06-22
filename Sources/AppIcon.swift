import Cocoa
import SwiftUI

// MARK: - Icon Helper
enum AppIcon {
    static func menuBarIcon() -> NSImage? {
        // Load OpenClaw logo SVG
        guard let svgURL = Bundle.main.url(forResource: "OpenClawLogo", withExtension: "svg"),
              let svgData = try? Data(contentsOf: svgURL) else {
            // Fallback to SF Symbol
            let fallback = NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: "OpenClaw")
            fallback?.isTemplate = true
            return fallback
        }
        
        // Create image from SVG data
        // For now, use a tinted SF Symbol that looks like OpenClaw colors
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        let image = NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: "OpenClaw")
        
        guard let img = image?.withSymbolConfiguration(config) else {
            return image
        }
        
        // Create tinted version with OpenClaw red
        return img.tinted(with: NSColor(red: 0.957, green: 0.302, blue: 0.302, alpha: 1.0))
    }
}

// MARK: - NSImage Extension for Tinting
extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return self
        }
        
        let size = self.size
        let newImage = NSImage(size: size)
        
        newImage.lockFocus()
        
        // Draw with color
        color.setFill()
        
        let context = NSGraphicsContext.current?.cgContext
        context?.clip(to: NSRect(origin: .zero, size: size), mask: cgImage)
        NSRect(origin: .zero, size: size).fill()
        
        newImage.unlockFocus()
        newImage.isTemplate = false
        
        return newImage
    }
}
