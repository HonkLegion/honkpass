import SwiftUI

/// `bit-select` in a `bit-form-field`: libs/components/src/select on ng-select, styled by
/// libs/components/src/multi-select/scss/bw.theme.scss. The closed control is a field container
/// with the chosen label and an arrow; a click opens the list under it. With the focus, the
/// arrows, Return and the space bar open it too, and what is typed leaves only the rows that
/// contain it (ng-select is "searchable" unless told otherwise).
///
/// The list is drawn by the nearest `bwDropdownHost()` above this view, over everything else,
/// as the reference appends it to the page. `BWDialog` is such a host.
public struct BWSelect<Value: Hashable>: View {
    public struct Option {
        public let value: Value
        public let label: String
        /// `icon` of bit-option: before the label, in the list and in the closed control.
        public let icon: BWIcon?
        /// The closed control shows this option in the colour of a placeholder: an option
        /// without a value that stands for "nothing chosen" ("[&_.ng-value]:tw-text-fg-body-subtle").
        public let isPlaceholder: Bool

        public init(_ value: Value, _ label: String, icon: BWIcon? = nil, isPlaceholder: Bool = false) {
            self.value = value
            self.label = label
            self.icon = icon
            self.isPlaceholder = isPlaceholder
        }
    }

    private let label: String
    private let options: [Option]
    private let isRequired: Bool
    private let hint: String?
    private let bottomMargin: CGFloat
    private let isNative: Bool
    private let placeholder: String?
    @Binding private var selection: Value
    @State private var isOpen: Bool
    @State private var isHovered = false
    /// What was typed since the list opened. It stands in the control in place of the chosen label.
    @State private var search = ""
    /// The list was open at least once: only then is there a keyboard to take back.
    @State private var hadList = false
    @FocusState private var hasFocus: Bool
    @Environment(\.isEnabled) private var isEnabled

    /// The search of ng-select: the label contains the text, whatever the case and the accents.
    private var shown: [Option] {
        search.isEmpty ? options : options.filter {
            $0.label.range(of: search, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private var chosen: Option? { options.first { $0.value == selection } }
    private var chosenLabel: String { chosen?.label ?? "" }

    /// - Parameters:
    ///   - bottomMargin: "tw-mb-4" unless the reference overrides it on the field.
    ///   - isNative: the closed control looks like a `select bitInput`, which the browser of
    ///     the reference draws itself: the text of a desktop input and a thin arrow.
    ///   - placeholder: what the closed control says while the chosen value is none of the
    ///     options. bit-select says "-- Select --" then (`selectPlaceholder`).
    ///   - startsOpen: the list is open from the start. For a picture of it.
    public init(_ label: String, selection: Binding<Value>, options: [Option], isRequired: Bool = false,
                hint: String? = nil, bottomMargin: CGFloat = Metric.space(4), isNative: Bool = false,
                placeholder: String? = nil, startsOpen: Bool = false) {
        _isOpen = State(initialValue: startsOpen)
        _hadList = State(initialValue: startsOpen)
        self.label = label
        _selection = selection
        self.options = options
        self.isRequired = isRequired
        self.hint = hint
        self.bottomMargin = bottomMargin
        self.isNative = isNative
        self.placeholder = placeholder
    }

    public var body: some View {
        // "tw-flex tw-flex-col tw-gap-2"
        VStack(alignment: .leading, spacing: Metric.space(2)) {
            BWFieldLabel(label, isRequired: isRequired)
            control
            if let hint { BWHint(hint) }
        }
        .padding(.bottom, bottomMargin)
    }

    private var control: some View {
        // ".ng-select-focused": the border of the focus, open or not.
        BWFieldContainer(isFocused: isOpen || hasFocus, isHovered: isHovered && isEnabled) {
            HStack(spacing: 0) {
                // .ng-value-container: "padding-inline: 0.75rem 0"; the text is "tw-text-sm/5".
                // A select of the browser has the font of the desktop inputs ("font-size: 14px" in
                // apps/desktop/src/scss/base.scss); its text starts four pixels further in than
                // the label of a bit-select (measured in docs/reference/export-*.png).
                // ng-label-tmp: "tw-flex tw-items-center tw-gap-2" around the icon and the label.
                // ".ng-placeholder" has "color: var(--color-fg-body-subtle)".
                let showsPlaceholder = search.isEmpty && (chosen?.isPlaceholder ?? true)
                HStack(spacing: Metric.space(2)) {
                    if search.isEmpty, let icon = chosen?.icon { SelectIcon(icon) }
                    Text(search.isEmpty ? (chosen?.label ?? placeholder ?? "") : search)
                        .lineLimit(1)
                        .textStyle(isNative ? .body : .smTight)
                }
                .foregroundStyle(.theme(isEnabled ? (showsPlaceholder ? .fgBodySubtle : .fgHeading) : .fgInactive))
                .padding(.leading, Metric.space(3) + (isNative ? 4 : 0))
                .frame(maxWidth: .infinity, alignment: .leading)
                if isNative {
                    NativeSelectArrow()
                        .foregroundStyle(.theme(isEnabled ? .fgHeading : .fgInactive))
                        .padding(.trailing, 14)
                } else {
                    // .ng-arrow-wrapper: "width: 25px; padding-inline: 0 0.75rem", the arrow in the middle of the rest.
                    SelectArrow(isOpen: isOpen)
                        .foregroundStyle(.theme(isEnabled ? .fgHeading : .fgInactive))
                        .frame(width: 25 - Metric.space(3))
                        .padding(.trailing, Metric.space(3))
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if isEnabled { isOpen.toggle() } }
        .onHover { isHovered = $0 }
        .focusable(isEnabled, interactions: .edit)
        .focusEffectDisabled()
        .focused($hasFocus)
        // The keys of the closed select. The open list has the keyboard itself.
        .onKeyPress { press in
            guard !isOpen, !press.modifiers.contains(.command) else { return .ignored }
            switch press.key {
            case .downArrow, .upArrow, .return, .space:
                isOpen = true
                return .handled
            default:
                let typed = BWDropdownRequest.text(of: press)
                guard !typed.isEmpty else { return .ignored }
                search = typed
                isOpen = true
                return .handled
            }
        }
        // The list is gone: the search ends, and the keyboard is on the select again.
        .onChange(of: isOpen) { _, isOpen in
            if !isOpen {
                search = ""
                hasFocus = true
            }
        }
        // The request above can come before the list has let the keyboard go: the select asks
        // a few times more, for a quarter of a second.
        .task(id: isOpen) {
            guard !isOpen, hadList else { return }
            for _ in 0..<3 where !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                if !hasFocus { hasFocus = true }
            }
        }
        .onChange(of: isOpen) { _, isOpen in
            if isOpen { hadList = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(label)
        .accessibilityValue(chosen?.label ?? placeholder ?? "")
        .accessibilityAction { if isEnabled { isOpen.toggle() } }
        .anchorPreference(key: BWDropdownPreference.self, value: .bounds) { anchor in
            guard isOpen else { return nil }
            return BWDropdownRequest(
                anchor: anchor,
                rows: shown.map { option in
                    BWDropdownRequest.Row(label: option.label, icon: option.icon, isSelected: option.value == selection) {
                        selection = option.value
                        isOpen = false
                    }
                },
                search: $search,
                dismiss: { isOpen = false })
        }
    }
}

/// `bit-icon` with `fixedWidth` beside the label of an option: the size of the text ("tw-text-sm")
/// in a box 18/14 of that wide ("bwi-fw").
private struct SelectIcon: View {
    let icon: BWIcon

    init(_ icon: BWIcon) {
        self.icon = icon
    }

    var body: some View {
        IconView(icon, size: TextStyle.sm.size)
            .frame(width: TextStyle.sm.size * 18 / 14)
    }
}

/// The arrow that the browser draws in a `select`: 8.5 by 4.75 pixels, one pixel thick, its middle
/// 19 pixels from the edge of the field (measured in docs/reference/export-*.png).
private struct NativeSelectArrow: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0.5, y: 0.5))
            path.addLine(to: CGPoint(x: 4.25, y: 4.25))
            path.addLine(to: CGPoint(x: 8, y: 0.5))
        }
        .stroke(style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        .frame(width: 8.5, height: 4.75)
        .accessibilityHidden(true)
    }
}

/// `.ng-arrow`: a box of 8 pixels with a border of 2 on its right and bottom, turned by 45 degrees
/// ("transform: translateY(-2px) rotate(45deg)"); open, it points up ("translateY(0) rotate(-135deg)").
private struct SelectArrow: View {
    let isOpen: Bool

    var body: some View {
        // The two visible sides along the middle of their borders: 7 pixels each.
        let arm = 7 / 2.0.squareRoot()
        Path { path in
            path.move(to: CGPoint(x: 6 - arm, y: 4 - arm / 2))
            path.addLine(to: CGPoint(x: 6, y: 4 + arm / 2))
            path.addLine(to: CGPoint(x: 6 + arm, y: 4 - arm / 2))
        }
        .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .butt, lineJoin: .round))
        .frame(width: 12, height: 8)
        .scaleEffect(y: isOpen ? -1 : 1)
        // The arrow is the lower half of the turned box, which is raised by 2 pixels; open, it
        // is the upper half of the box in the middle of the field.
        .offset(y: isOpen ? -2.8 : 0.8)
        .accessibilityHidden(true)
    }
}

// MARK: The open list

/// What an open select asks its host to draw.
struct BWDropdownRequest {
    struct Row {
        let label: String
        var icon: BWIcon?
        let isSelected: Bool
        let choose: () -> Void
    }

    let anchor: Anchor<CGRect>
    let rows: [Row]
    /// What was typed to find a row; the rows are the ones that contain it.
    let search: Binding<String>
    let dismiss: () -> Void

    /// The text a key types, without the keys that type none (arrows, function keys, controls).
    static func text(of press: KeyPress) -> String {
        guard press.modifiers.isDisjoint(with: [.command, .control]) else { return "" }
        return String(press.characters.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
        }.map(Character.init))
    }
}

struct BWDropdownPreference: PreferenceKey {
    static var defaultValue: BWDropdownRequest? { nil }

    static func reduce(value: inout BWDropdownRequest?, nextValue: () -> BWDropdownRequest?) {
        value = value ?? nextValue()
    }
}

public extension View {
    /// Draws the open list of the selects inside this view over it. A click beside the list closes it.
    func bwDropdownHost() -> some View {
        overlayPreferenceValue(BWDropdownPreference.self) { request in
            GeometryReader { proxy in
                if let request {
                    let field = proxy[request.anchor]
                    let height = BWDropdownList.height(rows: max(request.rows.count, 1))
                    // The list opens under the field, or over it when there is no room under it.
                    let opensUp = field.maxY + 2 + height > proxy.size.height && field.minY - 2 - height >= 0
                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(perform: request.dismiss)
                        BWDropdownList(rows: request.rows, search: request.search, dismiss: request.dismiss)
                            .frame(width: field.width)
                            .offset(x: field.minX, y: opensUp ? field.minY - 2 - height : field.maxY + 2)
                    }
                    .onExitCommand(perform: request.dismiss)
                    .bwEscapeLayer(close: request.dismiss)
                }
            }
        }
    }
}

/// `.ng-dropdown-panel`: "background-color: var(--color-bg-primary); border: 1px solid var(--color-border-light);
/// border-radius: 0.5rem; padding: 0.5rem" with the shadow of "tw-shadow-md"; the options scroll after 240 pixels.
private struct BWDropdownList: View {
    let rows: [BWDropdownRequest.Row]
    let search: Binding<String>
    let dismiss: () -> Void
    /// `.ng-option-marked`: the row the arrow keys and the pointer are on. It is the chosen row
    /// when the list opens, and it stays where the pointer left it.
    @State private var marked: Int?
    /// The marked row has to be in sight: at the start and after an arrow key, not under the pointer.
    @State private var scrollRequest = 0
    @FocusState private var hasFocus: Bool

    init(rows: [BWDropdownRequest.Row], search: Binding<String>, dismiss: @escaping () -> Void) {
        self.rows = rows
        self.search = search
        self.dismiss = dismiss
        _marked = State(initialValue: rows.firstIndex(where: \.isSelected) ?? (rows.isEmpty ? nil : 0))
    }

    private static let rowHeight = 2 * Metric.space(2) + 1.25 * Metric.rem
    private static let rowGap: CGFloat = 4
    private static let maxItemsHeight: CGFloat = 240

    private static func itemsHeight(rows: Int) -> CGFloat {
        CGFloat(rows) * rowHeight + CGFloat(max(rows - 1, 0)) * rowGap
    }

    static func height(rows: Int) -> CGFloat {
        min(itemsHeight(rows: rows), maxItemsHeight) + 2 * Metric.space(2) + 2
    }

    var body: some View {
        let radius = Metric.containerCornerRadius
        let items = VStack(spacing: Self.rowGap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                Option(row: row, isMarked: marked == index) { marked = index }
                    .id(index)
            }
            if rows.isEmpty {
                // `notFoundText` of ng-select, which bit-select leaves at the English text of the
                // library: an ".ng-option-disabled" row.
                Text("No items found")
                    .lineLimit(1)
                    .textStyle(.smTight.weight(500))
                    .foregroundStyle(.theme(.fgInactive))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Metric.space(2))
            }
        }
        // One container whatever is in it: a search that makes a long list short must not take
        // the keyboard away with the scroll area.
        VStack(spacing: 0) {
            if Self.itemsHeight(rows: rows.count) > Self.maxItemsHeight {
                BWScrollView(scrollTarget: marked.map { BWScrollTarget(id: $0, request: scrollRequest) }) { items }
                    .frame(height: Self.maxItemsHeight)
            } else {
                items
            }
        }
        .padding(Metric.space(2))
        .padding(1)
        .background(RoundedRectangle(cornerRadius: radius).fill(.theme(.bgPrimary))
            .shadow(color: .black.opacity(0.1), radius: 3, x: 0, y: 4))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.theme(.borderLight), lineWidth: 1))
        // ng-select: the arrows move the mark and go round at the ends, Return takes the marked
        // row, Escape and Tab close the list.
        .focusable(interactions: .edit)
        .focusEffectDisabled()
        .focused($hasFocus)
        .onAppear { hasFocus = true }
        // A request that comes too early is not honoured, and the select itself takes the
        // keyboard when its dialog opens with the list: the list asks for half a second, until
        // it has the keyboard. It does not ask later, so that a list that is closing does not
        // take the keyboard from the select again.
        .task {
            for _ in 0..<6 where !Task.isCancelled {
                if !hasFocus { hasFocus = true }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
        .onKeyPress { press in
            // The shortcuts of the application menu stay what they are.
            guard !press.modifiers.contains(.command) else { return .ignored }
            switch press.key {
            case .downArrow: move(1)
            case .upArrow: move(-1)
            case .return:
                if let marked, rows.indices.contains(marked) { rows[marked].choose() }
            case .escape, .tab: dismiss()
            case .delete:
                if !search.wrappedValue.isEmpty { search.wrappedValue.removeLast() }
            // Every other key types into the search of the select.
            default: search.wrappedValue += BWDropdownRequest.text(of: press)
            }
            return .handled
        }
        // Other rows after a search: the mark is on the first of them (`markFirst`).
        .onChange(of: rows.map(\.label)) {
            marked = rows.isEmpty ? nil : 0
            scrollRequest += 1
        }
    }

    private func move(_ step: Int) {
        marked = KeyboardList.step(from: marked, by: step, canChoose: rows.map { _ in true })
        scrollRequest += 1
    }

    /// `.ng-option`: "padding: 0.5rem; border-radius: 0.5rem; font-weight: 500; color: var(--color-fg-body)";
    /// marked or chosen "var(--color-bg-brand-softer)" with the text in "fg-heading", both "bg-brand-soft".
    private struct Option: View {
        let row: BWDropdownRequest.Row
        let isMarked: Bool
        /// The pointer came over the row: ng-select marks it (`onItemHover`).
        let mark: () -> Void

        var body: some View {
            Button(action: row.choose) {
                // ng-option-tmp: "tw-flex tw-items-center tw-gap-2" around the icon and the label.
                HStack(spacing: Metric.space(2)) {
                    if let icon = row.icon { SelectIcon(icon) }
                    Text(row.label)
                        .lineLimit(1)
                        .textStyle(.smTight.weight(500))
                }
                .foregroundStyle(.theme(row.isSelected || isMarked ? .fgHeading : .fgBody))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Metric.space(2))
                .background(RoundedRectangle(cornerRadius: Metric.containerCornerRadius).fill(.theme(background)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { if $0 { mark() } }
            .accessibilityAddTraits(row.isSelected ? .isSelected : [])
        }

        private var background: ThemeColor {
            switch (row.isSelected, isMarked) {
            case (true, true): .bgBrandSoft
            case (true, false), (false, true): .bgBrandSofter
            case (false, false): .clear
            }
        }
    }
}
