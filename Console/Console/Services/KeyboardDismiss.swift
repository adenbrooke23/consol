import SwiftUI
import UIKit

// Tap-anywhere-to-dismiss-the-keyboard, done at the window level so it works
// across every screen without touching individual views:
//  • cancelsTouchesInView = false: buttons, rows, and gestures behave exactly
//    as before; this recognizer only adds an endEditing side effect.
//  • touches inside a text field are excluded, so tapping the field to place
//    the caret never fights the keyboard.
// Install once via `.background(KeyboardDismissInstaller())` on the root view.

struct KeyboardDismissInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { InstallerView() }
    func updateUIView(_ uiView: UIView, context: Context) {}

    final class InstallerView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window,
                  window.gestureRecognizers?.contains(where: { $0 is DismissTap }) != true
            else { return }
            let tap = DismissTap(target: window, action: #selector(UIView.endEditing(_:)))
            window.addGestureRecognizer(tap)
        }
    }

    final class DismissTap: UITapGestureRecognizer, UIGestureRecognizerDelegate {
        override init(target: Any?, action: Selector?) {
            super.init(target: target, action: action)
            cancelsTouchesInView = false
            delegate = self
        }

        // Never steal the tap that goes into a text field.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let v = view {
                if v is UITextField || v is UITextView { return false }
                view = v.superview
            }
            return true
        }

        // Coexist with every other recognizer (rows, scrolls, buttons).
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
