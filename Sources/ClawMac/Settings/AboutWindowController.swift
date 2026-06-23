import AppKit
import SwiftUI

@MainActor
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    init() {
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About Clawmac"
        window.contentViewController = NSHostingController(rootView: AboutView())
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
