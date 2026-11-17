import SwiftUI

/// Native type and selection treatment for HonkPass's floating glass picker.
public enum QuickAccessStyle {
    public static let title = Font.system(size: 14, weight: .semibold)
    public static let subtitle = Font.system(size: 12)
    public static let caption = Font.system(size: 11)
    public static let menu = Font.system(size: 13)
    public static let search = Font.system(size: 23)
    public static let selection = Color.primary.opacity(0.08)
    public static let hover = Color.primary.opacity(0.04)

    public static func panelHeight(rowCount: Int, isUnlocked: Bool, showsQuestion: Bool = false) -> CGFloat {
        if showsQuestion { return Metric.quickAccessQuestionHeight }
        guard isUnlocked else { return Metric.quickAccessLockedHeight }
        guard rowCount > 0 else { return Metric.quickAccessHeight }
        return min(Metric.quickAccessHeight, Metric.quickAccessChromeHeight
                   + CGFloat(max(2, rowCount)) * Metric.quickAccessRowHeight)
    }
}

/// Borderless search on the panel's system glass. It retains the existing focus requests
/// and the first-Escape-clears behavior without drawing an opaque field over the material.
public struct QuickAccessSearchField: View {
    @Binding private var text: String
    private let focusRequest: Int
    @FocusState private var isFocused: Bool

    public init(text: Binding<String>, focusRequest: Int) {
        _text = text
        self.focusRequest = focusRequest
    }

    public var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(QuickAccessStyle.search)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(BWText["honkpassQuickSearch"], text: $text)
                .textFieldStyle(.plain)
                .font(QuickAccessStyle.search)
                .foregroundStyle(.primary)
                .focused($isFocused)
                .onKeyPress(.escape, phases: .down) { press in
                    guard press.modifiers.isEmpty, !text.isEmpty else { return .ignored }
                    clear()
                    return .handled
                }
            if !text.isEmpty {
                Button(action: clear) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(BWText["clearSearchTooltip"])
                    .accessibilityLabel(BWText["resetSearch"])
            }
            Illustration(.gooseKey, isTemplate: true)
                .foregroundStyle(.primary)
                .frame(width: 24, height: 24)
        }
        .padding(.horizontal, Metric.quickAccessInset)
        .frame(height: Metric.quickAccessSearchHeight)
        .onAppear { isFocused = true }
        .onChange(of: focusRequest) { isFocused = true }
    }

    private func clear() {
        text = ""
        isFocused = true
    }
}
