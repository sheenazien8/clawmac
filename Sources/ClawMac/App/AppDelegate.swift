import AppKit
import SwiftUI
import Combine

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var chatViewModel = ChatViewModel()
    var pairingManager = PairingManager()

    let settingsStore = SettingsStore.shared
    var hotKeyManager = HotKeyManager()
    var settingsWindowController: SettingsWindowController?
    var aboutWindowController: AboutWindowController?
    private var statusItemMenu: NSMenu?
    private var settingsCancellable: AnyCancellable?
    private var streamingIndicatorCancellable: AnyCancellable?
    private var lastRegisteredKeyCode: UInt32 = UInt32.max
    private var lastRegisteredModifiers: UInt32 = UInt32.max

    func applicationDidFinishLaunching(_ notification: Notification) {
        NativeBridgeServer.shared.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            if let url = Bundle.module.url(forResource: "OpenClawLogo", withExtension: "svg"),
               let image = NSImage(contentsOf: url) {
                image.size = NSSize(width: 18, height: 18)
                image.isTemplate = true
                image.accessibilityDescription = "Clawmac"
                button.image = image
            }

            setupStatusItemMenu()
            button.action = #selector(handleStatusItemClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let chatView = ChatView(viewModel: chatViewModel, pairingManager: pairingManager)
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 380, height: 600)
        popover?.behavior = .transient
        popover?.contentViewController = ChatHostingController(rootView: chatView)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePopoverDidShow(_:)),
            name: NSPopover.didShowNotification,
            object: popover
        )

        settingsCancellable = settingsStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.reregisterHotKeyIfNeeded()
                }
            }

        streamingIndicatorCancellable = chatViewModel.$isLoading
            .receive(on: RunLoop.main)
            .sink { [weak self] isLoading in
                DispatchQueue.main.async {
                    self?.updateStreamingIndicator(isLoading: isLoading)
                }
            }

        reregisterHotKeyIfNeeded(force: true)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillResignActive),
            name: NSApplication.willResignActiveNotification,
            object: nil
        )
    }

    private func setupStatusItemMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let openItem = NSMenuItem(title: "Open Chat", action: #selector(openChatFromMenu), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "About Clawmac", action: #selector(openAboutFromMenu), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Clawmac", action: #selector(quitAppFromMenu), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItemMenu = menu
    }

    private func reregisterHotKeyIfNeeded(force: Bool = false) {
        let kc = settingsStore.shortcutKeyCode
        let mods = settingsStore.shortcutModifiers
        if !force, kc == lastRegisteredKeyCode, mods == lastRegisteredModifiers {
            return
        }
        let result = hotKeyManager.register(keyCode: kc, modifiers: mods) { [weak self] in
            self?.togglePopover()
        }
        lastRegisteredKeyCode = kc
        lastRegisteredModifiers = mods

        switch result {
        case .success:
            settingsStore.lastErrorMessage = nil
            settingsStore.needsPermissionAlert = false
        case .permissionDenied:
            settingsStore.lastErrorMessage = nil
            settingsStore.needsPermissionAlert = true
        case .alreadyTaken:
            settingsStore.lastErrorMessage = "Shortcut already in use by another app — try a different combo."
            settingsStore.needsPermissionAlert = false
        case .failed(let code):
            settingsStore.lastErrorMessage = "Failed to register shortcut (code \(code))."
            settingsStore.needsPermissionAlert = false
        }
    }

    @objc private func handleAppWillResignActive() {
        if popover?.isShown == true {
            popover?.performClose(nil)
        }
    }

    func applicationWillResignActive(_ notification: Notification) {
        if popover?.isShown == true {
            popover?.performClose(nil)
        }
    }

    @objc func togglePopover() {
        if let button = statusItem?.button {
            if popover?.isShown == true {
                popover?.performClose(nil)
            } else {
                NSApp.activate(ignoringOtherApps: true)
                popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }

    private func updateStreamingIndicator(isLoading: Bool) {
        guard let button = statusItem?.button else { return }
        button.contentTintColor = isLoading ? .systemRed : nil
    }

    @objc private func handlePopoverDidShow(_ notification: Notification) {
        guard let view = popover?.contentViewController?.view else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak view] in
            guard let view = view else { return }
            ChatHostingController.focusFirstTextField(in: view)
        }
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
        let isOptionClick = event?.modifierFlags.contains(.option) ?? false
        if isRightClick || isOptionClick {
            showStatusItemMenu()
        } else {
            togglePopover()
        }
    }

    private func showStatusItemMenu() {
        guard let menu = statusItemMenu, let statusItem = statusItem else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: (statusItem.button?.bounds.maxY ?? 0) + 4), in: statusItem.button)
    }

    @objc private func openChatFromMenu() {
        togglePopover()
    }

    @objc private func openSettingsFromMenu() {
        openSettingsWindow()
    }

    @objc private func openAboutFromMenu() {
        openAboutWindow()
    }

    @objc private func quitAppFromMenu() {
        NSApp.terminate(nil)
    }

    private func openSettingsWindow() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(settingsStore: settingsStore)
        }
        settingsWindowController?.showWindow(nil)
    }

    private func openAboutWindow() {
        if aboutWindowController == nil {
            aboutWindowController = AboutWindowController()
        }
        aboutWindowController?.showWindow(nil)
    }
}
