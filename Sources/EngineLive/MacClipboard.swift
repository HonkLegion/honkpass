import AppKit
import Engine

/// The general pasteboard of macOS.
public struct MacClipboard: ClipboardPort {
    public init() {}

    @MainActor
    public func copy(_ text: String, isSensitive: Bool) async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if isSensitive {
            // The convention of nspasteboard.org: clipboard managers do not record such an entry.
            pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }
    }

    @MainActor
    public func clear(ifStill text: String) async {
        let pasteboard = NSPasteboard.general
        if pasteboard.string(forType: .string) == text { pasteboard.clearContents() }
    }

    @MainActor
    public func read() async -> String? {
        NSPasteboard.general.string(forType: .string)
    }
}
