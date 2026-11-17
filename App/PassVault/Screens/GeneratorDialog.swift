import DesignKit
import Engine
import Observation
import SwiftUI
import VaultModel

/// The open generator: its options and the value it has made. The lock throws it away.
@MainActor @Observable
final class GeneratorSession {
    enum Purpose {
        /// From the side navigation or the application menu.
        case standalone
        /// For the password of the item form: a password or a passphrase.
        case password(ItemForm)
        /// For the user name of the item form.
        case username(ItemForm)
        /// For the password of the form of a Send.
        case sendPassword(SendForm)
    }

    let purpose: Purpose
    var options: GeneratorOptions
    var value = ""
    /// The first website of the item whose form opened the generator. A catch-all address can
    /// start with its name.
    let website: String?

    init(purpose: Purpose, options: GeneratorOptions) {
        self.purpose = purpose
        if case .username(let form) = purpose, case .login(let login) = form.draft.content {
            // The first website: the address of an app is none.
            website = login.websites.first { !$0.address.isEmpty && $0.app == nil }?.address
        } else {
            website = nil
        }
        var options = options
        switch purpose {
        case .standalone: break
        case .password, .sendPassword: if options.kind == .username { options.kind = .password }
        case .username: options.kind = .username
        }
        self.options = options
    }
}

/// The generator. Reference: docs/reference/generator-*.png. Source: apps/desktop/src/app/tools/generator
/// (the dialog), apps/desktop/src/vault/app/vault/credential-generator-dialog (the one of the item form)
/// and libs/tools/generator/components (its content).
///
/// A forwarded email alias is left out (PLAN.md, allowed deviations).
struct GeneratorDialog: View {
    let model: AppModel
    let navigation: VaultNavigation
    let preferences: AppPreferences
    @Bindable var session: GeneratorSession

    private var kind: GeneratorKind { session.options.kind }

    var body: some View {
        BWDialog(title: BWText["generator"], size: .large, hasAltGround: true, onClose: close) {
            VStack(alignment: .leading, spacing: 0) {
                kindToggle
                if case .standalone = session.purpose, !preferences.hidesGeneratorNudge { nudge }
                valueCard
                switch kind {
                case .password: passwordOptions
                case .passphrase: passphraseOptions
                case .username: usernameOptions
                }
                historyItem
            }
        } footer: {
            footer
        }
        .onExitCommand(perform: close)
        // A value for the options as they are, and a new one whenever they change. The options
        // are kept with the settings of the account.
        .task(id: session.options) {
            await saveOptions()
            await generate()
        }
    }

    // MARK: Parts

    /// Share the Settings tabs, with only the kinds available for this generator's purpose.
    @ViewBuilder
    private var kindToggle: some View {
        let password = (GeneratorKind.password, BWText["password"])
        let passphrase = (GeneratorKind.passphrase, BWText["passphrase"])
        switch session.purpose {
        case .standalone:
            BWTabs([password, passphrase, (.username, BWText["username"])], selection: $session.options.kind)
                .padding(.bottom, Metric.space(4))
        case .password, .sendPassword:
            BWTabs([password, passphrase], selection: $session.options.kind)
                .padding(.bottom, Metric.space(4))
        case .username:
            EmptyView()
        }
    }

    /// nudge-generator-spotlight: shown until the user closes it.
    private var nudge: some View {
        BWCallout(title: BWText["generatorNudgeTitle"], onDismiss: { preferences.hidesGeneratorNudge = true }) {
            Text(BWText["generatorNudgeBodyOne"] + " ") + Text(Image(systemName: BWIcon.generate.systemName)).font(.system(size: TextStyle.sm.size))
                + Text(" " + BWText["generatorNudgeBodyTwo"])
        }
    }

    /// bit-card "tw-flex tw-justify-between tw-mb-4": the value, then the buttons that make a new one and copy it.
    private var valueCard: some View {
        BWCard {
            HStack(alignment: .center, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    BWColorPassword(session.value, style: .base)
                    if kind == .passphrase {
                        // p "tw-mb-0 tw-mt-2 tw-text-sm tw-text-muted"
                        Text("\(BWText["length"]): \(session.value.count)")
                            .textStyle(.sm)
                            .foregroundStyle(.theme(.textMuted))
                            .padding(.top, Metric.space(2))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // "tw-flex tw-items-center tw-space-x-1"
                HStack(spacing: Metric.space(1)) {
                    BWIconButton(.generate, label: BWText[generateKey]) { Task { await generate() } }
                    BWIconButton(.clone, label: BWText[copyKey], action: copy)
                        .disabled(session.value.isEmpty)
                }
            }
        }
        .padding(.bottom, Metric.space(4))
    }

    private var generateKey: String {
        switch kind {
        case .password: "generatePassword"
        case .passphrase: "generatePassphrase"
        case .username: "generateUsername"
        }
    }

    private var copyKey: String {
        switch kind {
        case .password: "copyPassword"
        case .passphrase: "copyPassphrase"
        case .username: "copyUsername"
        }
    }

    /// password-settings.component.html
    private var passwordOptions: some View {
        let options = $session.options.password
        let hint = BWText["spinboxBoundariesHint", String(PasswordOptions.lengthRange.lowerBound), String(PasswordOptions.lengthRange.upperBound)]
            + BWText["passwordLengthRecommendationHint", String(PasswordOptions.recommendedLength)]
        return VStack(alignment: .leading, spacing: 0) {
            BWSectionHeader(BWText["options"])
            BWCard {
                NumberField(BWText["length"], value: options.length, range: PasswordOptions.lengthRange, hint: hint, bottomMargin: 0)
            }
            .padding(.bottom, Metric.space(4))
            BWCard {
                VStack(alignment: .leading, spacing: 0) {
                    // div "tw-mb-4"
                    Text(BWText["include"])
                        .textStyle(.base)
                        .padding(.bottom, Metric.space(4))
                    // "tw-mb-4 tw-flex tw-flex-wrap tw-gap-4 sm:tw-gap-8"
                    HStack(spacing: Metric.space(8)) {
                        BWCheckbox(BWText["uppercaseLabel"], isOn: options.uppercase)
                        BWCheckbox(BWText["lowercaseLabel"], isOn: options.lowercase)
                        BWCheckbox(BWText["numbersLabel"], isOn: options.numbers)
                        BWCheckbox("!@#$%^&*", isOn: options.special)
                    }
                    .padding(.bottom, Metric.space(4))
                    // div "tw-flex": two fields "tw-basis-1/2", the first with "tw-mr-4"
                    HStack(alignment: .top, spacing: Metric.space(4)) {
                        NumberField(BWText["minNumbers"], value: options.minNumbers, range: PasswordOptions.minimumRange)
                        NumberField(BWText["minSpecial"], value: options.minSpecial, range: PasswordOptions.minimumRange)
                    }
                    BWCheckbox(BWText["avoidAmbiguous"], isOn: options.avoidAmbiguous)
                }
            }
            // bit-section: "tw-mb-5", which the "tw-mb-4" of its last card falls into.
            .padding(.bottom, Metric.space(5))
        }
    }

    /// passphrase-settings.component.html
    private var passphraseOptions: some View {
        let options = $session.options.passphrase
        let hint = BWText["spinboxBoundariesHint", String(PassphraseOptions.wordsRange.lowerBound), String(PassphraseOptions.wordsRange.upperBound)]
            + BWText["passphraseNumWordsRecommendationHint", String(PassphraseOptions.recommendedWords)]
        return VStack(alignment: .leading, spacing: 0) {
            BWSectionHeader(BWText["options"])
            BWCard {
                NumberField(BWText["numWords"], value: options.words, range: PassphraseOptions.wordsRange, hint: hint, bottomMargin: 0)
            }
            .padding(.bottom, Metric.space(4))
            BWCard {
                VStack(alignment: .leading, spacing: 0) {
                    CommittedField(BWText["wordSeparator"], text: options.separator, maxLength: 1)
                    BWCheckbox(BWText["capitalize"], isOn: options.capitalize)
                        .padding(.bottom, Metric.space(4))
                    BWCheckbox(BWText["includeNumber"], isOn: options.includeNumber)
                }
            }
            // bit-section: "tw-mb-5", which the "tw-mb-4" of its last card falls into.
            .padding(.bottom, Metric.space(5))
        }
    }

    /// The options of a user name in credential-generator.component.html and username-generator.
    private var usernameOptions: some View {
        let options = $session.options.username
        let kinds: [BWSelect<UsernameOptions.Kind>.Option] = [
            .init(.plusAddressedEmail, BWText["plusAddressedEmail"]), .init(.catchallEmail, BWText["catchallEmail"]),
            .init(.randomWord, BWText["randomWord"]),
        ]
        return VStack(alignment: .leading, spacing: 0) {
            BWSectionHeader(BWText["options"])
            BWCard {
                VStack(alignment: .leading, spacing: 0) {
                    BWSelect(BWText["type"], selection: options.kind, options: kinds)
                    switch session.options.username.kind {
                    case .randomWord:
                        // username-settings: two bit-form-control, each with its "tw-mb-4".
                        BWCheckbox(BWText["capitalize"], isOn: options.capitalize)
                            .padding(.bottom, Metric.space(4))
                        BWCheckbox(BWText["includeNumber"], isOn: options.includeNumber)
                            .padding(.bottom, Metric.space(4))
                    case .plusAddressedEmail:
                        CommittedField(BWText["email"], text: options.email)
                    case .catchallEmail:
                        // catchall-settings: bit-radio-group "type" with its two choices, then the domain.
                        VStack(alignment: .leading, spacing: 0) {
                            BWFieldLabel(BWText["type"])
                                .padding(.bottom, Metric.space(1))
                            BWRadio(BWText["random"], isOn: !session.options.username.catchallUsesWebsiteName) {
                                session.options.username.catchallUsesWebsiteName = false
                            }
                            BWRadio(BWText["websiteName"], isOn: session.options.username.catchallUsesWebsiteName) {
                                session.options.username.catchallUsesWebsiteName = true
                            }
                        }
                        .padding(.bottom, Metric.space(4))
                        CommittedField(BWText["domainName"], text: options.domain)
                    }
                }
            }
            // bit-section: "tw-mb-5", which the "tw-mb-4" of its last card falls into.
            .padding(.bottom, Metric.space(5))
        }
    }

    /// bit-item with "generator history" and an arrow: the text in the colour of a link
    /// ("tw-font-semibold", "tw-text-fg-brand hover:tw-text-fg-brand-strong hover:tw-underline").
    private var historyItem: some View {
        HistoryLink { navigation.showsGeneratorHistory = true }
    }

    private struct HistoryLink: View {
        let action: () -> Void
        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: Metric.space(4)) {
                    Text(BWText["generatorHistory"])
                        .underline(isHovered)
                        .textStyle(.sm.weight(600))
                        .foregroundStyle(.theme(isHovered ? .fgBrandStrong : .fgBrand))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    IconView(.angleRight, size: TextStyle.sm.size)
                        .foregroundStyle(.theme(.fgBrand))
                }
                .padding(.horizontal, Metric.space(3))
                .padding(.vertical, Metric.space(2))
                .frame(minHeight: Metric.space(9) - 2)
                .padding(1)
                .background(BWControlShape().fill(.theme(isHovered ? .bgBrandSofter : .bgPrimary)))
                .overlay(BWControlShape().strokeBorder(.theme(.borderBase), lineWidth: 1))
                .contentShape(BWControlShape())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .pointerStyle(.link)
            .padding(.bottom, Metric.space(1.5))
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch session.purpose {
        case .standalone:
            BWButton(BWText["close"], isBlock: false, action: close)
        case .password(let form):
            BWButton(BWText[kind == .passphrase ? "useThisPassphrase" : "useThisPassword"], kind: .primary, isBlock: false) {
                if case .login(var login) = form.draft.content {
                    login.password = session.value
                    form.draft.content = .login(login)
                }
                close()
            }
            .disabled(session.value.isEmpty)
        case .sendPassword(let form):
            BWButton(BWText[kind == .passphrase ? "useThisPassphrase" : "useThisPassword"], kind: .primary, isBlock: false) {
                form.password = session.value
                close()
            }
            .disabled(session.value.isEmpty)
        case .username(let form):
            BWButton(BWText[session.options.username.kind == .randomWord ? "useThisUsername" : "useThisEmail"], kind: .primary,
                     isBlock: false) {
                if case .login(var login) = form.draft.content {
                    login.username = session.value
                    form.draft.content = .login(login)
                }
                close()
            }
            .disabled(session.value.isEmpty)
        }
    }

    // MARK: Actions

    private func generate() async {
        let request: GeneratorRequest = switch kind {
        case .password: .password(session.options.password)
        case .passphrase: .passphrase(session.options.passphrase)
        case .username: .username(session.options.username, website: session.website)
        }
        // Options that give no value (a plus address without an address) leave the card empty.
        session.value = (try? await model.generate(request)) ?? ""
    }

    /// The generator of the item form does not change which kind the generator itself starts with.
    private func saveOptions() async {
        var settings = model.state.settings
        var options = session.options
        if case .standalone = session.purpose {} else { options.kind = settings.generator.kind }
        guard settings.generator != options else { return }
        settings.generator = options
        try? await model.setSettings(settings)
    }

    private func copy() {
        let label = BWText[kind == .password ? "password" : kind == .passphrase ? "passphrase" : "username"]
        Task {
            guard (try? await model.copy(text: session.value, isSensitive: kind != .username)) != nil else { return }
            navigation.toasts.show(.success, message: BWText["valueCopied", label])
        }
    }

    private func close() {
        navigation.generator = nil
    }
}

/// A number field of the generator: `input type="number"` that takes its value when the user
/// leaves it or presses Return, inside its limits.
private struct NumberField: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var hint: String?
    var bottomMargin = Metric.space(4)
    @State private var text = ""
    @FocusState private var isFocused: Bool

    init(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, hint: String? = nil, bottomMargin: CGFloat = Metric.space(4)) {
        self.label = label
        _value = value
        self.range = range
        self.hint = hint
        self.bottomMargin = bottomMargin
    }

    var body: some View {
        BWFormField(label, isFocused: isFocused, hint: hint, bottomMargin: bottomMargin) {
            BWTextInput(text: $text)
                .focused($isFocused)
                .onSubmit(commit)
        }
        .onAppear { text = String(value) }
        .onChange(of: value) { text = String(value) }
        .onChange(of: isFocused) { if !isFocused { commit() } }
    }

    private func commit() {
        let number = Int(text.filter(\.isNumber)) ?? value
        value = min(max(number, range.lowerBound), range.upperBound)
        text = String(value)
    }
}

/// A text field of the generator that takes its value when the user leaves it or presses Return.
private struct CommittedField: View {
    let label: String
    @Binding var value: String
    var maxLength: Int?
    @State private var text = ""
    @FocusState private var isFocused: Bool

    init(_ label: String, text: Binding<String>, maxLength: Int? = nil) {
        self.label = label
        _value = text
        self.maxLength = maxLength
    }

    var body: some View {
        BWFormField(label, isFocused: isFocused) {
            BWTextInput(text: $text)
                .focused($isFocused)
                .onSubmit(commit)
        }
        .onAppear { text = value }
        .onChange(of: isFocused) { if !isFocused { commit() } }
    }

    private func commit() {
        if let maxLength { text = String(text.prefix(maxLength)) }
        value = text
    }
}

/// The earlier passwords of an item. Source: libs/vault/src/components/password-history and
/// password-history-view. No reference picture yet.
struct PasswordHistoryDialog: View {
    let model: AppModel
    let navigation: VaultNavigation
    let itemID: String
    @State private var entries: [PasswordHistoryEntry]?

    var body: some View {
        BWDialog(title: BWText["passwordHistory"], hasAltGround: true, onClose: close) {
            VStack(alignment: .leading, spacing: 0) {
                if let entries, entries.isEmpty {
                    Text(BWText["noPasswordsInList"])
                        .textStyle(.body)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Metric.space(6))
                }
                ForEach(Array((entries ?? []).enumerated()), id: \.offset) { _, entry in
                    row(entry)
                }
            }
        } footer: {
            BWButton(BWText["close"], kind: .primary, isBlock: false, action: close)
        }
        .onExitCommand(perform: close)
        .task {
            entries = (try? await model.passwordHistory(of: itemID)) ?? []
        }
    }

    /// bit-item: div "tw-pl-3 tw-py-2" with the coloured password and the date, then the copy button.
    private func row(_ entry: PasswordHistoryEntry) -> some View {
        let radius = Metric.containerCornerRadius
        return HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                BWColorPassword(entry.password, style: .base)
                // "tw-text-sm tw-text-muted", the date as Angular's "medium"
                Text(ItemPanel.medium(entry.lastUsed))
                    .textStyle(.sm)
                    .foregroundStyle(.theme(.textMuted))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Metric.space(3))
            .padding(.vertical, Metric.space(2))
            BWIconButton(.clone, label: BWText["copyPassword"]) {
                Task {
                    guard (try? await model.copy(text: entry.password, isSensitive: true)) != nil else { return }
                    navigation.copied(BWText["valueCopied", BWText["password"]])
                }
            }
        }
        .padding(1)
        .background(RoundedRectangle(cornerRadius: radius).fill(.theme(.bgPrimary)))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.theme(.borderBase), lineWidth: 1))
        .padding(.bottom, Metric.space(1.5))
    }

    private func close() {
        navigation.passwordHistoryItemID = nil
    }
}

/// What the generator has made, the newest first, with a button that copies each value.
/// Source: libs/tools/generator/components/src/credential-generator-history-dialog and
/// credential-generator-history. No reference picture yet.
struct GeneratorHistoryDialog: View {
    let model: AppModel
    let navigation: VaultNavigation
    @State private var history: [GeneratedValue]?

    var body: some View {
        BWDialog(title: BWText["generatorHistory"], hasAltGround: true, onClose: close) {
            VStack(alignment: .leading, spacing: 0) {
                if let history, history.isEmpty {
                    // bit-empty-credential-history
                    StatusLockup(illustration: .noCredentials, title: BWText["nothingToShow"],
                                 description: BWText["nothingGeneratedRecently"]) { EmptyView() }
                        .frame(maxWidth: .infinity)
                }
                ForEach(Array((history ?? []).enumerated()), id: \.offset) { _, entry in
                    row(entry)
                }
            }
        } footer: {
            BWButton(BWText["clearHistory"], kind: .primary, isBlock: false, action: clear)
                .disabled(history?.isEmpty != false)
        }
        .onExitCommand(perform: close)
        .task { await load() }
    }

    /// bit-item: the coloured value "tw-font-mono", the date as Angular's "medium" under it, then the copy button.
    private func row(_ entry: GeneratedValue) -> some View {
        let radius = Metric.containerCornerRadius
        return HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                BWColorPassword(entry.value, style: .sm)
                Text(ItemPanel.medium(entry.date))
                    .textStyle(.xs)
                    .foregroundStyle(.theme(.textMuted))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Metric.space(3))
            .padding(.vertical, Metric.space(2))
            BWIconButton(.clone, label: BWText[copyKey(entry.kind)]) {
                Task {
                    guard (try? await model.copy(text: entry.value, isSensitive: entry.kind != .username)) != nil else { return }
                    navigation.toasts.show(.success, message: BWText["valueCopied", BWText[labelKey(entry.kind)]])
                }
            }
        }
        .padding(1)
        .background(RoundedRectangle(cornerRadius: radius).fill(.theme(.bgPrimary)))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.theme(.borderBase), lineWidth: 1))
        .padding(.bottom, Metric.space(1.5))
    }

    private func copyKey(_ kind: GeneratorKind) -> String {
        switch kind {
        case .password: "copyPassword"
        case .passphrase: "copyPassphrase"
        case .username: "copyUsername"
        }
    }

    private func labelKey(_ kind: GeneratorKind) -> String {
        switch kind {
        case .password: "password"
        case .passphrase: "passphrase"
        case .username: "username"
        }
    }

    private func load() async {
        history = (try? await model.generatorHistory()) ?? []
    }

    /// Asks first, as the reference: "clear generator history".
    private func clear() {
        navigation.question = .init(kind: .warning, title: BWText["clearGeneratorHistoryTitle"],
                                    text: BWText["clearGeneratorHistoryDescription"], acceptTitle: BWText["clearHistory"]) {
            Task {
                guard (try? await model.clearGeneratorHistory()) != nil else {
                    navigation.toasts.show(.error, message: BWText["errorOccurred"])
                    return
                }
                await load()
            }
        }
    }

    private func close() {
        navigation.showsGeneratorHistory = false
    }
}
