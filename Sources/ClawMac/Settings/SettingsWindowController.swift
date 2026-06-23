import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init(settingsStore: SettingsStore) {
        NSApp.setActivationPolicy(.regular)
        let view = SettingsView(settingsStore: settingsStore)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Clawmac Settings"
        window.contentViewController = NSHostingController(rootView: view)
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.hidesOnDeactivate = false
        window.acceptsMouseMovedEvents = true
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeKey()
        DispatchQueue.main.async {
            self.window?.makeKey()
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
