import AppKit
import SwiftUI

final class ChatHostingController: NSHostingController<ChatView> {
    override func viewDidAppear() {
        super.viewDidAppear()

        guard let window = view.window else { return }
        window.makeKey()

        func attemptFocus(attempt: Int) {
            guard attempt < 5 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1 * Double(attempt + 1)) { [weak self] in
                guard let self = self, let window = self.view.window, window.isVisible else { return }
                window.makeKey()
                if let textField = Self.findTextField(in: self.view) {
                    if window.makeFirstResponder(textField) {
                        print("✅ Autofocus succeeded on attempt \(attempt + 1)")
                    } else {
                        print("⚠️ makeFirstResponder returned false on attempt \(attempt + 1)")
                    }
                } else {
                    print("⚠️ NSTextField not found on attempt \(attempt + 1)")
                    if attempt < 4 {
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
