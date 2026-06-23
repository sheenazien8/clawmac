import AppKit
import Carbon.HIToolbox

private let kHotKeySignature: OSType = 0x636C6177

private let hotKeyCallback: EventHandlerUPP = { (_, _, userData) -> OSStatus in
    guard let userData = userData else { return noErr }
    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        manager.fire()
    }
    return noErr
}

enum HotKeyRegistrationResult {
    case success
    case permissionDenied
    case alreadyTaken
    case failed(OSStatus)
}

@MainActor
final class HotKeyManager {
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var eventHandler: EventHandlerRef?
    private let hotKeyID = EventHotKeyID(signature: kHotKeySignature, id: 1)
    private var trigger: (() -> Void)?

    deinit {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
        }
    }

    func register(keyCode: UInt32, modifiers: UInt32, onTrigger: @escaping @MainActor () -> Void) -> HotKeyRegistrationResult {
        unregister()

        guard CGRequestListenEventAccess() else {
            return .permissionDenied
        }

        trigger = onTrigger

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userDataPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let installStatus = withUnsafePointer(to: &eventType) { ptr -> OSStatus in
            InstallEventHandler(
                GetEventDispatcherTarget(),
                hotKeyCallback,
                1,
                ptr,
                userDataPtr,
                &eventHandler
            )
        }

        guard installStatus == noErr else {
            print("⚠️ HotKeyManager: failed to install event handler (\(installStatus))")
            return .failed(installStatus)
        }

        var ref: EventHotKeyRef?
        let regStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )

        guard regStatus == noErr else {
            print("⚠️ HotKeyManager: failed to register hot key (\(regStatus))")
            if let handler = eventHandler {
                RemoveEventHandler(handler)
                eventHandler = nil
            }
            if regStatus == OSStatus(eventHotKeyExistsErr) {
                return .alreadyTaken
            }
            return .failed(regStatus)
        }

        hotKeyRef = ref
        print("✅ HotKeyManager: registered keyCode=\(keyCode) modifiers=\(modifiers)")
        return .success
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
        trigger = nil
    }

    fileprivate func fire() {
        trigger?()
    }
}
