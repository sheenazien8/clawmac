import SwiftUI
import AppKit

struct AboutView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: appIconImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)

            Text("Clawmac")
                .font(.title)
                .fontWeight(.semibold)

            Text("Version \(appVersion) (\(appBuild))")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("AI Assistant macOS app from the menu bar.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Open on GitHub") {
                if let url = URL(string: "https://github.com/sheenazien8/clawmac/releases/latest") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.link)

            Spacer()

            Text("© 2026 sheenazien8")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(28)
        .frame(width: 360, height: 360)
    }

    private func appIconImage() -> NSImage {
        if let url = Bundle.module.url(forResource: "OpenClawLogo", withExtension: "svg"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 96, height: 96)
            return image
        }
        if let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) {
            return image
        }
        return NSImage()
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}
