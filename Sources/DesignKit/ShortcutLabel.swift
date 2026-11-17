import SwiftUI

/// The same native key typography in saved shortcuts and their recorder.
public struct ShortcutLabel: View {
    private let shortcut: BWKeyShortcut?

    public init(_ shortcut: BWKeyShortcut?) {
        self.shortcut = shortcut
    }

    public var body: some View {
        Text(shortcut?.display ?? "")
            .font(BWFont.shortcut)
            .foregroundStyle(.theme(.fgHeading))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: true)
    }
}
