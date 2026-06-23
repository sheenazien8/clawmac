import AppKit
import SwiftUI

final class ChatHostingController: NSHostingController<ChatView> {
    override func viewDidAppear() {
        super.viewDidAppear()
        Self.focusFirstTextField(in: view)
    }

    static func focusFirstTextField(in view: NSView, maxAttempts: Int = 8) {
        guard let window = view.window else { return }
        window.makeKey()

        func attemptFocus(attempt: Int) {
            guard attempt < maxAttempts else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 + 0.1 * Double(attempt)) {
                guard let window = view.window, window.isVisible else { return }
                window.makeKey()
                if let textField = findTextField(in: view) {
                    if window.makeFirstResponder(textField) {
                        print("✅ Autofocus succeeded on attempt \(attempt + 1)")
                    } else {
                        print("⚠️ makeFirstResponder returned false on attempt \(attempt + 1)")
                        if attempt < maxAttempts - 1 {
                            attemptFocus(attempt: attempt + 1)
                        }
                    }
                } else {
                    print("⚠️ NSTextField not found on attempt \(attempt + 1)")
                    if attempt < maxAttempts - 1 {
                        attemptFocus(attempt: attempt + 1)
                    }
                }
            }
        }

        attemptFocus(attempt: 0)
    }

    private static func findTextField(in view: NSView) -> NSTextField? {
        if let textField = view as? NSTextField { return textField }
        for subview in view.subviews {
            if let found = findTextField(in: subview) { return found }
        }
        return nil
    }
}
