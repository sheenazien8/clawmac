import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore

    @StateObject private var recorder = ShortcutRecorderModel()
    @State private var permissionAlertShown = Bool(false)

    var body: some View {
        Form {
            Section("Shortcut") {
                shortcutButton
                Button("Reset to Default") {
                    settingsStore.resetToDefault()
                }
                .buttonStyle(.link)

                if let error = settingsStore.lastErrorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            Section("App") {
                LabeledContent("Name", value: "Clawmac")
                LabeledContent("Version", value: appVersion)
                LabeledContent("Build", value: appBuild)
                Text("AI Assistant macOS app from the menu bar.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Quit Clawmac", role: .destructive) {
                    NSApp.terminate(nil)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 380)
        .alert("Input Monitoring Required", isPresented: $permissionAlertShown) {
            Button("Open System Settings") {
                openInputMonitoringSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clawmac needs the Input Monitoring permission to register the global shortcut. Open System Settings → Privacy & Security → Input Monitoring and enable Clawmac.")
        }
        .onChange(of: settingsStore.needsPermissionAlert) { _, newValue in
            if newValue {
                permissionAlertShown = true
                settingsStore.needsPermissionAlert = false
            }
        }
    }

    private var shortcutButton: some View {
        Button {
            if recorder.isRecording {
                recorder.stopMonitoring()
            } else {
                recorder.onCapture = { kc, mods in
                    settingsStore.setShortcut(keyCode: UInt32(kc), modifiers: mods)
                }
                recorder.onCancel = {}
                recorder.startMonitoring()
            }
        } label: {
            HStack {
                if recorder.isRecording {
                    Text("Press a key combo…")
                        .foregroundColor(.accentColor)
                    Spacer()
                    Text("Esc to cancel")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text(ShortcutFormatter.format(
                        keyCode: Int(settingsStore.shortcutKeyCode),
                        modifiers: settingsStore.shortcutModifiers
                    ))
                    .font(.system(.body, design: .monospaced))
                    Spacer()
                    Text("Click to record")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}
