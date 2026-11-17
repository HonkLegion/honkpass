import AppKit
import DesignKit
import SwiftUI

/// "Type shortcut": the dialog of the reference that takes a new keyboard shortcut
/// (libs/angular/src/desktop-native/components/autotype-shortcut.component.html), here for the
/// shortcut that opens quick access and for the one that fills. It opens with the shortcut in use. Its sentence about
/// the modifier keys of Windows is left out; what counts as a shortcut on a Mac is
/// `BWKeyShortcut.isValid`. "Invalid shortcut" stands for a key that is none, and for a
/// shortcut the system does not give because another app has it.
struct ShortcutDialog: View {
    @Bindable var preferences: AppPreferences
    let which: AppPreferences.Shortcut
    let onClose: () -> Void
    /// The keys that were pressed last; the shortcut in use until a key was pressed.
    @State private var typed: BWKeyShortcut?
    @State private var showsError: Bool

    init(preferences: AppPreferences, which: AppPreferences.Shortcut, onClose: @escaping () -> Void) {
        self.preferences = preferences
        self.which = which
        self.onClose = onClose
        _typed = State(initialValue: preferences.shortcut(which))
        // The shortcut in use was refused when the app started.
        _showsError = State(initialValue: !preferences.isAvailable(which))
    }

    var body: some View {
        BWDialog(title: BWText["typeShortcut"], onClose: onClose) {
            BWFormField(BWText["typeShortcut"], isFocused: true, error: showsError ? BWText["invalidShortcut"] : nil,
                        bottomMargin: 0) {
                // The key label matches settings; the view under it hears the keys.
                ShortcutLabel(typed)
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                    .background(ShortcutRecorder(onKey: { shortcut in
                        typed = shortcut
                        showsError = false
                    }, onSubmit: save, onCancel: onClose))
                    .accessibilityLabel(BWText["typeShortcut"])
                    .accessibilityValue(typed?.display ?? "")
            }
        } footer: {
            BWButton(BWText["save"], kind: .primary, isBlock: false, action: save)
            BWButton(BWText["cancel"], isBlock: false, action: onClose)
        }
        // The shortcut in use does not answer while a new one is typed.
        .onAppear { preferences.isRecordingShortcut = true }
        .onDisappear { preferences.isRecordingShortcut = false }
    }

    private func save() {
        guard let typed, preferences.set(typed, for: which) else {
            showsError = true
            return
        }
        onClose()
    }
}

/// Hears the keys of a shortcut: every key with its modifiers, also the ones that are a
/// command of the application menu. Return and Escape without a modifier save and cancel.
private struct ShortcutRecorder: NSViewRepresentable {
    let onKey: (BWKeyShortcut) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> Recorder {
        let view = Recorder()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: Recorder, context: Context) {
        view.onKey = onKey
        view.onSubmit = onSubmit
        view.onCancel = onCancel
    }

    final class Recorder: NSView {
        var onKey: ((BWKeyShortcut) -> Void)?
        var onSubmit: (() -> Void)?
        var onCancel: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // After the dialog is drawn: the keyboard is with this view from then on.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        }

        /// A key with Command, which would else be a command of the application menu.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard event.type == .keyDown, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
            record(event)
            return true
        }

        override func keyDown(with event: NSEvent) {
            let isPlain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            switch (event.keyCode, isPlain) {
            case (36, true), (76, true): onSubmit?()
            case (53, true): onCancel?()
            default: record(event)
            }
        }

        private func record(_ event: NSEvent) {
            var modifiers: BWKeyShortcut.Modifiers = []
            if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
            if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
            if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
            if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
            onKey?(BWKeyShortcut(keyCode: event.keyCode, modifiers: modifiers, keyName: event.charactersIgnoringModifiers ?? ""))
        }
    }
}
