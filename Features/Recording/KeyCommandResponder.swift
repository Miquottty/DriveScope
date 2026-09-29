import SwiftUI
import UIKit

/// Hardware-keyboard commands that take priority over the system's own use of a key (iPad HUD and Replay).
///
/// SwiftUI's `keyboardShortcut` can't set `wantsPriorityOverSystemBehavior`, and plain ← / → belong to the keyboard
/// focus system, so those shortcuts were silently swallowed. This view becomes first responder while it is on screen
/// and serves its commands through UIKit. Being first responder also anchors the responder chain inside the
/// presented screen, so SwiftUI shortcuts on its buttons (above it in the chain) answer from the first key press.
struct KeyCommandResponder: UIViewRepresentable {
    struct Command {
        var input: String
        var modifiers: UIKeyModifierFlags = []
        /// Shown in the ⌘-hold shortcut overlay.
        var title: String
        var action: () -> Void
    }

    var commands: [Command] = []

    func makeUIView(context: Context) -> ResponderView {
        ResponderView()
    }

    func updateUIView(_ view: ResponderView, context: Context) {
        view.commands = commands
    }

    final class ResponderView: UIView {
        var commands: [Command] = []

        override var canBecomeFirstResponder: Bool { true }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            // After the presentation settles; a view mid-transition may be refused.
            Task { @MainActor [weak self] in
                guard let self, self.window != nil, !self.isFirstResponder else { return }
                self.becomeFirstResponder()
            }
        }

        override var keyCommands: [UIKeyCommand]? {
            commands.enumerated().map { index, command in
                let key = UIKeyCommand(
                    title: command.title, action: #selector(runCommand(_:)), input: command.input,
                    modifierFlags: command.modifiers, propertyList: index)
                key.wantsPriorityOverSystemBehavior = true
                // ← / → mean earlier / later in every language.
                key.allowsAutomaticMirroring = false
                return key
            }
        }

        @objc private func runCommand(_ sender: UIKeyCommand) {
            guard let index = sender.propertyList as? Int, commands.indices.contains(index) else { return }
            commands[index].action()
        }
    }
}
