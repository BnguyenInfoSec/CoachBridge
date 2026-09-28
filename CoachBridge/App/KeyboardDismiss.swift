import Combine
import SwiftUI
import UIKit

extension View {
    /// A way out of the keyboard on forms with multi-line fields. Return inserts a new line in a
    /// vertical TextField, so "What the coach knows" had no way to leave it. Dragging the form
    /// down dismisses the keyboard, and a Done button sits in the navigation bar while it's up.
    ///
    /// The button is in the navigation bar, not above the keyboard: on iOS 27, in this tab
    /// layout, SwiftUI's `.keyboard` toolbar placement didn't render at all (checked in the
    /// simulator).
    func keyboardDismissible() -> some View { modifier(KeyboardDismissible()) }
}

private struct KeyboardDismissible: ViewModifier {
    @State private var keyboardUp = false

    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                if keyboardUp {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardUp = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardUp = false
            }
    }
}
