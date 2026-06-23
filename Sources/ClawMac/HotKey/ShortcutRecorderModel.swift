import AppKit
import Carbon.HIToolbox

extension NSEvent.ModifierFlags {
    var carbonModifiers: UInt32 {
        var carbon: UInt32 = 0
        if contains(.command) { carbon |= UInt32(cmdKey) }
        if contains(.shift) { carbon |= UInt32(shiftKey) }
        if contains(.option) { carbon |= UInt32(optionKey) }
        if contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }
}

final class ShortcutRecorderModel: ObservableObject {
    @Published var isRecording: Bool = false
    private var monitor: Any?
    var onCapture: ((Int, UInt32) -> Void)?
    var onCancel: (() -> Void)?

    private static let modifierKeyCodes: Set<UInt16> = [
        54, 55, 56, 57, 58, 59, 60, 61, 62, 63
    ]

    func startMonitoring() {
        stopMonitoring()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event: event)
            return nil
        }
    }

    func stopMonitoring() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        isRecording = false
    }

    private func handle(event: NSEvent) {
        if event.keyCode == 53 {
            stopMonitoring()
            onCancel?()
            return
        }
        if Self.modifierKeyCodes.contains(event.keyCode) {
            return
        }
        let mods = event.modifierFlags.carbonModifiers
        let kc = Int(event.keyCode)
        stopMonitoring()
        onCapture?(kc, mods)
    }

    deinit {
        if let m = monitor {
            NSEvent.removeMonitor(m)
        }
    }
}
