import AppKit
import DesignKit

/// Opens legal information from the signed app bundle, without a network request.
@MainActor
final class LegalInformation: NSObject {
    static let shared = LegalInformation()

    static var indexURL: URL? {
        Bundle.main.url(forResource: "index-" + BWText.settings.language, withExtension: "html", subdirectory: "Legal")
            ?? Bundle.main.url(forResource: "index-en", withExtension: "html", subdirectory: "Legal")
    }

    @objc func showAbout(_ sender: Any?) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let credits = NSMutableAttributedString(string: BWText["honkpassLegalSummary"] + "\n\n", attributes: attributes)
        if let url = Self.indexURL {
            credits.append(NSAttributedString(string: BWText["honkpassLicensesAndSource"],
                                              attributes: attributes.merging([.link: url]) { _, link in link }))
        }
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
        ])
    }

    @objc func showLicenses(_ sender: Any?) {
        guard let url = Self.indexURL else { return }
        NSWorkspace.shared.open(url)
    }
}
