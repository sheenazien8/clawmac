import Foundation
import AppKit
import Carbon.HIToolbox

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var shortcutKeyCode: UInt32
    @Published var shortcutModifiers: UInt32
    @Published var lastErrorMessage: String?
    @Published var needsPermissionAlert: Bool = false

    private let defaults = UserDefaults.standard
    private let keyCodeKey = "globalShortcutKeyCode"
    private let modifiersKey = "globalShortcutModifiers"

    static let defaultKeyCode: UInt32 = 47
    static let defaultModifiers: UInt32 = UInt32(cmdKey | shiftKey)

    init() {
        if defaults.object(forKey: keyCodeKey) != nil {
            var savedKey = UInt32(defaults.integer(forKey: keyCodeKey))
            var savedMods = UInt32(defaults.integer(forKey: modifiersKey))
            if savedKey == 49, savedMods == UInt32(cmdKey | shiftKey) {
                savedKey = Self.defaultKeyCode
                savedMods = Self.defaultModifiers
                defaults.set(Int(savedKey), forKey: keyCodeKey)
                defaults.set(Int(savedMods), forKey: modifiersKey)
                defaults.synchronize()
            }
            self.shortcutKeyCode = savedKey
            self.shortcutModifiers = savedMods
        } else {
            self.shortcutKeyCode = Self.defaultKeyCode
            self.shortcutModifiers = Self.defaultModifiers
            defaults.set(Int(Self.defaultKeyCode), forKey: keyCodeKey)
            defaults.set(Int(Self.defaultModifiers), forKey: modifiersKey)
            defaults.synchronize()
        }
    }

    func setShortcut(keyCode: UInt32, modifiers: UInt32) {
        shortcutKeyCode = keyCode
        shortcutModifiers = modifiers
        defaults.set(Int(keyCode), forKey: keyCodeKey)
        defaults.set(Int(modifiers), forKey: modifiersKey)
    }

    func resetToDefault() {
        setShortcut(keyCode: Self.defaultKeyCode, modifiers: Self.defaultModifiers)
    }
}
