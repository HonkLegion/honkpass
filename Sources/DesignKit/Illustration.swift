import AppKit
import SwiftUI

/// The SVG illustrations of the reference, generated once for each appearance
/// (libs/assets/src/svg/svgs, colours from the theme).
public struct Illustration: View {
    public enum Name: String, Sendable {
        case vault
        case gooseKey = "goose-key"
        case noResults = "no-results"
        case itemTypes = "item-types"
        case emptyTrash = "empty-trash"
        case favorites
        case twoFactorAuthenticator = "two-factor-auth-authenticator"
        case twoFactorWebAuthn = "two-factor-auth-webauthn"
        case emailCodeSent = "email-code-sent"
        case noCredentials = "no-credentials"
        case noSend = "no-send"
    }

    private let name: Name
    private let isTemplate: Bool
    @Environment(\.colorScheme) private var colorScheme

    public init(_ name: Name, isTemplate: Bool = false) {
        self.name = name
        self.isTemplate = isTemplate
    }

    public var body: some View {
        if let image = Self.image(name, dark: colorScheme == .dark) {
            Image(nsImage: image)
                .renderingMode(isTemplate ? .template : .original)
                .resizable()
                .aspectRatio(image.size, contentMode: .fit)
                .scaleEffect(name == .gooseKey ? 1.4 : 1)
                .accessibilityHidden(true)
        }
    }

    /// Whether DesignKit has the drawing for an appearance.
    public static func exists(_ name: Name, dark: Bool) -> Bool {
        resourceURL(name, dark: dark) != nil
    }

    private static func resourceURL(_ name: Name, dark: Bool) -> URL? {
        let file = name == .gooseKey ? name.rawValue : "\(name.rawValue)-\(dark ? "dark" : "light")"
        return Bundle.module.url(forResource: file, withExtension: name == .gooseKey ? "png" : "svg",
                                 subdirectory: "Resources/Illustrations")
    }

    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    private static func image(_ name: Name, dark: Bool) -> NSImage? {
        let file = "\(name.rawValue)-\(dark ? "dark" : "light")"
        if let cached = cache[file] { return cached }
        guard let url = resourceURL(name, dark: dark),
              let image = NSImage(contentsOf: url) else {
            assertionFailure("DesignKit illustration \(file) is missing")
            return nil
        }
        cache[file] = image
        return image
    }
}
