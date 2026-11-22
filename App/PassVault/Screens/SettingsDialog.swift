import AppKit
import DesignKit
import Engine
import EngineLive
import SwiftUI
import VaultModel

/// Both shortcut settings share the checkbox alignment and the existing field appearance.
private struct ShortcutSettingRow: View {
    let title: String
    @Binding var isOn: Bool
    let shortcut: BWKeyShortcut
    let isAvailable: Bool
    var hint: String? = nil
    let edit: () -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.space(1)) {
            HStack(alignment: .center, spacing: Metric.space(4)) {
                BWCheckbox(title, isOn: $isOn)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: edit) {
                    BWFieldContainer(isFocused: isFocused, isHovered: isHovered) {
                        ShortcutLabel(shortcut)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, Metric.space(3))
                    }
                }
                .buttonStyle(.plain)
                .frame(width: Metric.shortcutFieldWidth)
                .focused($isFocused)
                .focusEffectDisabled()
                .onHover { isHovered = $0 }
                .pointerStyle(.link)
                .help(BWText["editShortcut"])
                .accessibilityLabel(title + ": " + BWText["editShortcut"])
                .accessibilityValue(shortcut.display)
            }
            if let hint {
                BWHint(hint).padding(.leading, Metric.space(8) - 1)
            }
            if isOn && !isAvailable {
                HStack(alignment: .firstTextBaseline, spacing: Metric.space(1)) {
                    IconView(.error, size: TextStyle.xs.size)
                    Text(BWText["invalidShortcut"]).textStyle(.xs)
                }
                .foregroundStyle(.theme(.fgDanger))
                .padding(.leading, Metric.space(8) - 1)
            }
        }
        .padding(.bottom, Metric.space(4))
    }
}

/// The settings dialog: three tabs for the security of the account, its options and the app.
/// Reference: docs/reference/settings-*.png. Source: apps/desktop/src/app/accounts/settings-dialog.component.html
/// and libs/key-management-ui/src/session-timeout.
///
/// Every control acts at once; there is no button to save. The controls of features PassVault
/// does not have yet are shown disabled, and the timeout "never" is left out (PLAN.md, allowed deviations).
struct SettingsDialog: View {
    enum Tab: Hashable {
        case security, options, app
    }

    let model: AppModel
    @Bindable var navigation: VaultNavigation
    @Bindable var preferences: AppPreferences
    let account: Account

    /// The timeout select shows "custom", with the two number fields under it.
    @State private var isCustomTimeout = false
    @State private var customHours = ""
    @State private var customMinutes = ""
    @FocusState private var focusedField: CustomField?
    @State private var openHelp: HelpTopic?
    /// The dialog that sets the PIN lies over this one.
    @State private var isSettingPin: Bool
    /// The key of the vault is on its way to the Keychain, or out of it.
    @State private var isChangingTouchID = false

    private enum CustomField {
        case hours, minutes
    }

    private enum HelpTopic {
        case websiteIcons, quickCopy
    }

    private var settings: EngineSettings { model.state.settings }
    private var tab: Tab { navigation.settingsTab ?? .security }

    init(model: AppModel, navigation: VaultNavigation, preferences: AppPreferences, account: Account) {
        self.model = model
        self.navigation = navigation
        self.preferences = preferences
        self.account = account
        _isSettingPin = State(initialValue: navigation.settingsStartWithPinDialog)
        _openHelp = State(initialValue: navigation.settingsStartWithHelp ? .websiteIcons : nil)
    }

    var body: some View {
        BWDialog(title: BWText["settingsTitle", account.email], size: .large, onClose: close) {
            VStack(alignment: .leading, spacing: 0) {
                BWTabs([(Tab.security, BWText["security"]), (Tab.options, BWText["accountPreferences"]),
                        (Tab.app, BWText["appPreferences"])],
                       selection: Binding(get: { tab }, set: { navigation.settingsTab = $0 }))
                // div "tw-pt-5" around the body of the chosen tab
                Group {
                    switch tab {
                    case .security: security
                    case .options: options
                    case .app: app
                    }
                }
                .padding(.top, Metric.space(5))
            }
        }
        .onExitCommand(perform: close)
        .onAppear(perform: showCurrentTimeout)
        .overlay {
            if isSettingPin {
                SetPinDialog(model: model, toasts: navigation.toasts) { isSettingPin = false }
            }
        }
    }

    private func setPinWanted(_ isWanted: Bool) {
        if isWanted {
            isSettingPin = true
        } else {
            Task {
                do {
                    try await model.removePin()
                } catch {
                    navigation.toasts.show(.error, title: BWText["errorOccurred"], message: BWText["unexpectedError"])
                }
            }
        }
    }

    private func close() {
        navigation.settingsTab = nil
    }

    /// Sends a changed copy of the settings to the engine. The controls show what the engine
    /// publishes, so a change that could not be saved is not shown as made.
    private func change(_ change: (inout EngineSettings) -> Void) {
        var changed = settings
        change(&changed)
        Task {
            do {
                try await model.setSettings(changed)
            } catch {
                navigation.toasts.show(.error, title: BWText["errorOccurred"], message: BWText["unexpectedError"])
            }
        }
    }

    // MARK: Security

    /// bit-session-timeout-settings, then the unlock methods.
    private var security: some View {
        VStack(alignment: .leading, spacing: 0) {
            // bit-section-header with h2 bitTypography="h6", without a card after it: no padding.
            Text(BWText["sessionTimeoutHeader"])
                .textStyle(.sm.weight(500))
                .foregroundStyle(.theme(.textMain))
            // bit-session-timeout-input: div "tw-mb-4"; the select has a margin only above the custom fields.
            VStack(alignment: .leading, spacing: 0) {
                BWSelect(BWText["vaultTimeout1"], selection: timeoutChoice, options: TimeoutChoice.options,
                         bottomMargin: isCustomTimeout ? Metric.space(4) : 0, startsOpen: navigation.settingsStartWithOpenList)
                if isCustomTimeout { customTimeout }
            }
            .padding(.bottom, Metric.space(4))
            // bit-form-field [disableMargin]="true". The control has the validator "required", hence the mark.
            BWSelect(BWText["sessionTimeoutSettingsAction"], selection: timeoutAction,
                     options: [.init(TimeoutAction.logOut, BWText["logOut"]), .init(TimeoutAction.lock, BWText["lock"])],
                     isRequired: true, bottomMargin: 0)
            // bit-form-control class="tw-mt-4" with its own "tw-mb-4". Ticking it opens the dialog
            // that sets the PIN; unticking removes the PIN without a question, as in the reference.
            BWCheckbox(BWText["unlockWithPin"], isOn: Binding(get: { model.state.pin.isSet || isSettingPin }, set: setPinWanted))
                .padding(.top, Metric.space(4))
                .padding(.bottom, Metric.space(4))
            // "@if (supportsBiometric())": only on a Mac that can ask for Touch ID now. Ticked,
            // it has the hint and, indented ("tw-ms-5"), "ask for Touch ID on app start".
            if model.state.biometrics.isAvailable {
                let isOn = model.state.biometrics.isEnabled
                BWCheckbox(BWText["unlockWithTouchId"], isOn: Binding(get: { isOn }, set: setTouchIDWanted),
                           hint: isOn ? BWText["additionalTouchIdSettings"] : nil)
                    .disabled(isChangingTouchID)
                    .padding(.bottom, Metric.space(4))
                if isChangingTouchID {
                    HStack(spacing: Metric.space(2)) {
                        ProgressView().controlSize(.small)
                        Text(BWText["loading"]).textStyle(.sm)
                    }
                    .padding(.leading, Metric.space(5))
                    .padding(.bottom, Metric.space(4))
                }
                if isOn {
                    BWCheckbox(BWText["autoPromptTouchId"],
                               isOn: Binding(get: { settings.asksForBiometricsOnStart },
                                             set: { asks in change { $0.asksForBiometricsOnStart = asks } }))
                        .padding(.leading, Metric.space(5))
                        .padding(.bottom, Metric.space(4))
                }
            }
        }
        // A keyboard with Touch ID may have come or gone since the engine last looked.
        .task { await model.refreshBiometrics() }
    }

    /// `updateBiometric`: ticked, the key of the vault goes to the Keychain behind Touch ID;
    /// unticked, it is removed. What could not be done is said, and the box shows what holds.
    private func setTouchIDWanted(_ isWanted: Bool) {
        guard !isChangingTouchID else { return }
        isChangingTouchID = true
        Task {
            defer { isChangingTouchID = false }
            do {
                try await model.setBiometricUnlock(isWanted)
            } catch EngineError.invalidState, EngineError.cancelled {
                // The vault has locked meanwhile.
            } catch EngineError.biometrics(.unavailable) {
                navigation.toasts.show(.error, title: BWText["errorEnableBiometricTitle"], message: BWText["biometricsNotAvailableDesc"])
            } catch {
                navigation.toasts.show(.error, title: BWText["errorEnableBiometricTitle"], message: BWText["unexpectedError"])
            }
        }
    }

    /// div "tw-grid tw-grid-cols-12 tw-gap-4": hours and minutes, each half of the row.
    private var customTimeout: some View {
        HStack(alignment: .top, spacing: Metric.space(4)) {
            BWFormField(BWText["hours"], isFocused: focusedField == .hours, bottomMargin: 0) {
                BWTextInput(text: $customHours).focused($focusedField, equals: .hours)
            }
            BWFormField(BWText["minutes"], isFocused: focusedField == .minutes, bottomMargin: 0) {
                BWTextInput(text: $customMinutes).focused($focusedField, equals: .minutes)
            }
        }
        .onChange(of: customHours) { applyCustomTimeout() }
        .onChange(of: customMinutes) { applyCustomTimeout() }
    }

    /// The options of the timeout select, in the order of the reference
    /// (session-timeout-settings-component.service.ts, filtered for desktop).
    private enum TimeoutChoice: Hashable {
        case minutes(Int)
        case onIdle, onSleep, onLocked, onRestart, custom

        static let presets: [(minutes: Int, key: String)] = [
            (1, "oneMinute"), (5, "fiveMinutes"), (15, "fifteenMinutes"), (30, "thirtyMinutes"), (60, "oneHour"), (240, "fourHours"),
        ]

        static var options: [BWSelect<TimeoutChoice>.Option] {
            presets.map { .init(.minutes($0.minutes), BWText[$0.key]) } + [
                .init(.onIdle, BWText["onIdle"]), .init(.onSleep, BWText["onSleep"]), .init(.onLocked, BWText["onLocked"]),
                .init(.onRestart, BWText["sessionTimeoutOnRestart"]), .init(.custom, BWText["custom"]),
            ]
        }

        init(_ timeout: VaultTimeout) {
            switch timeout {
            case .afterInactivity(let minutes): self = Self.presets.contains { $0.minutes == minutes } ? .minutes(minutes) : .custom
            case .onSystemIdle: self = .onIdle
            case .onSleep: self = .onSleep
            case .onSystemLock: self = .onLocked
            // PassVault never keeps the vault open over a restart, so "never" is "on restart" here.
            case .onRestart, .never: self = .onRestart
            }
        }
    }

    private var timeoutChoice: Binding<TimeoutChoice> {
        Binding {
            isCustomTimeout ? .custom : TimeoutChoice(settings.lockPolicy.timeout)
        } set: { choice in
            switch choice {
            case .custom:
                // The fields start with the current time, or with eight hours after a timeout without one.
                let current: Int = if case .afterInactivity(let minutes) = settings.lockPolicy.timeout { minutes } else { 8 * 60 }
                isCustomTimeout = true
                customHours = String(current / 60)
                customMinutes = String(current % 60)
                change { $0.lockPolicy.timeout = .afterInactivity(minutes: current) }
            case .minutes(let minutes): setTimeout(.afterInactivity(minutes: minutes))
            case .onIdle: setTimeout(.onSystemIdle)
            case .onSleep: setTimeout(.onSleep)
            case .onLocked: setTimeout(.onSystemLock)
            case .onRestart: setTimeout(.onRestart)
            }
        }
    }

    private func setTimeout(_ timeout: VaultTimeout) {
        isCustomTimeout = false
        change { $0.lockPolicy.timeout = timeout }
    }

    private func showCurrentTimeout() {
        guard case .afterInactivity(let minutes) = settings.lockPolicy.timeout, TimeoutChoice(settings.lockPolicy.timeout) == .custom else { return }
        isCustomTimeout = true
        customHours = String(minutes / 60)
        customMinutes = String(minutes % 60)
    }

    /// The custom time is taken while it is valid: whole hours, minutes up to 59, and not zero in all.
    private func applyCustomTimeout() {
        guard isCustomTimeout, let hours = Int(customHours), let minutes = Int(customMinutes),
              hours >= 0, (0...59).contains(minutes), hours * 60 + minutes > 0, hours <= 24 * 365 else { return }
        change { $0.lockPolicy.timeout = .afterInactivity(minutes: hours * 60 + minutes) }
    }

    /// "Log out" is confirmed first, as in the reference.
    private var timeoutAction: Binding<TimeoutAction> {
        Binding {
            settings.lockPolicy.action
        } set: { action in
            guard action != settings.lockPolicy.action else { return }
            if action == .logOut {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = BWText["vaultTimeoutLogOutConfirmationTitle"]
                alert.informativeText = BWText["vaultTimeoutLogOutConfirmation"]
                alert.addButton(withTitle: BWText["yes"])
                alert.addButton(withTitle: BWText["cancel"])
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            change { $0.lockPolicy.action = action }
        }
    }

    // MARK: Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 0) {
            BWSelect(BWText["hpVaultSyncInterval"], selection: Binding(get: { settings.syncInterval },
                     set: { interval in change { $0.syncInterval = interval } }), options: [
                .init(.disabled, BWText["never"]), .init(.fiveMinutes, BWText["fiveMinutes"]),
                .init(.fifteenMinutes, BWText["fifteenMinutes"]), .init(.thirtyMinutes, BWText["thirtyMinutes"]),
                .init(.oneHour, BWText["oneHour"]),
            ])
            BWSelect(BWText["clearClipboard"], selection: clipboardClearing, options: [
                .init(ClipboardClearing.never, BWText["never"]),
                .init(.after(seconds: 10), BWText["tenSeconds"]),
                .init(.after(seconds: 20), BWText["twentySeconds"]),
                .init(.after(seconds: 30), BWText["thirtySeconds"]),
                .init(.after(seconds: 60), BWText["oneMinute"]),
                .init(.after(seconds: 120), BWText["twoMinutes"]),
                .init(.after(seconds: 300), BWText["fiveMinutes"]),
            ], hint: BWText["clearClipboardDesc"])
            BWCheckbox(BWText["minimizeOnCopyToClipboard"], isOn: $preferences.minimizesOnCopy,
                       hint: BWText["minimizeOnCopyToClipboardDesc"])
                .padding(.bottom, Metric.space(4))
            BWCheckbox("Gravatar", isOn: Binding(get: { settings.usesGravatar }, set: { value in change { $0.usesGravatar = value } }),
                       hint: BWText["hpGravatarHint"])
                .padding(.bottom, Metric.space(4))
            BWCheckbox(BWText["showIconsChangePasswordUrls"],
                       isOn: Binding(get: { settings.showsWebsiteIcons }, set: { isOn in change { $0.showsWebsiteIcons = isOn } }),
                       help: help(.websiteIcons, "permitCipherDetailsDescription", "https://bitwarden.com/help/website-icons/"))
                .padding(.bottom, Metric.space(4))
        }
    }

    private var clipboardClearing: Binding<ClipboardClearing> {
        Binding(get: { settings.clipboardClearing }, set: { clearing in change { $0.clipboardClearing = clearing } })
    }

    // MARK: App

    /// The settings of the app for all accounts. Two rows of the reference are left out, since
    /// PassVault has nothing they could turn on: "hardware acceleration", a setting of the
    /// browser engine the reference runs in, and the browser integration of DuckDuckGo.
    @State private var updateMode: MacAppUpdater.Mode = .notify

    private var updatePreference: some View {
        BWSelect(BWText["hpUpdateMode"], selection: Binding(get: { updateMode }, set: { mode in
            guard let updater = preferences.updater else { return }
            updater.setMode(mode)
            updateMode = updater.mode ?? .notify
        }), options: [.init(.manual, BWText["hpUpdateManual"]),
                      .init(.notify, BWText["hpUpdateNotify"]),
                      .init(.install, BWText["hpUpdateInstall"])])
        .onAppear { updateMode = preferences.updater?.mode ?? .notify }
        .disabled(preferences.updater?.mode == nil)
    }

    private var app: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                updatePreference
                BWCheckbox(BWText["runInBackground"],
                           isOn: Binding(get: { preferences.runsInBackground }, set: { preferences.runsInBackground = $0 }),
                           hint: BWText["runInBackgroundDescMac"])
                    .padding(.bottom, Metric.space(4))
                BWCheckbox(BWText["openAtLogin"],
                           isOn: Binding(get: { preferences.isOpenAtLoginOn }, set: { preferences.setOpenAtLogin?($0) }),
                           hint: BWText["openAtLoginDesc"])
                    .disabled(preferences.setOpenAtLogin == nil)
                    .padding(.bottom, Metric.space(4))
                // settings-dialog.component.html: the agent, and how it asks while it is on.
                BWCheckbox(BWText["enableSshAgent"],
                           isOn: Binding(get: { settings.sshAgent.isEnabled }, set: { isOn in change { $0.sshAgent.isEnabled = isOn } }),
                           hint: BWText["enableSshAgentDesc"])
                    .padding(.bottom, Metric.space(4))
                if settings.sshAgent.isEnabled {
                    BWSelect(BWText["sshAgentPromptBehavior"],
                             selection: Binding(get: { settings.sshAgent.prompt }, set: { prompt in change { $0.sshAgent.prompt = prompt } }),
                             options: [.init(.always, BWText["sshAgentPromptBehaviorAlways"]),
                                       .init(.never, BWText["sshAgentPromptBehaviorNever"]),
                                       .init(.rememberUntilLock, BWText["sshAgentPromptBehaviorRememberUntilLock"])],
                             hint: BWText["sshAgentPromptBehaviorDesc"])
                }
                BWCheckbox(BWText["allowScreenshots"],
                           isOn: Binding(get: { preferences.allowsScreenshots }, set: { allows in
                               preferences.allowsScreenshots = allows
                               if !allows { navigation.asksWhetherWindowIsVisible = true }
                           }),
                           hint: BWText["allowScreenshotsDesc"])
                    .padding(.bottom, Metric.space(4))
                BWCheckbox(BWText["showQuickCopyActionsInVault"],
                           isOn: Binding(get: { preferences.showsQuickCopyActions }, set: { preferences.showsQuickCopyActions = $0 }),
                           help: help(.quickCopy, "showQuickCopyActionsDetailsDescription",
                                      "https://bitwarden.com/help/auto-fill-browser/#copy-credentials"))
                    .padding(.bottom, Metric.space(4))
            }
            systemAutoFill
            quickAccessShortcut
            fillShortcut
            BWSelect(BWText["theme"], selection: $preferences.theme, options: [
                .init(AppPreferences.Theme.system, BWText["default"]),
                .init(.light, BWText["light"]),
                .init(.dark, BWText["dark"]),
            ], hint: BWText["themeDesc"])
            BWSelect(BWText["language"], selection: $preferences.language, options: Self.languages, hint: BWText["languageDesc"])
        }
    }

    private var quickAccessShortcut: some View {
        ShortcutSettingRow(title: BWText["autofillShortcut"], isOn: $preferences.isQuickAccessShortcutOn,
                           shortcut: preferences.quickAccessShortcut, isAvailable: preferences.isQuickAccessShortcutAvailable) {
            navigation.editedShortcut = .quickAccess
        }
    }

    /// The switch of the system's AutoFill, which the reference does not have: its extension
    /// reaches the app without a part that the user has to allow (PLAN.md, "Differences from the
    /// reference"). On, PassVault is among the background items of the system and the system
    /// asks the user to turn the extension on; the link opens the settings of the system for it.
    private var systemAutoFill: some View {
        VStack(alignment: .leading, spacing: Metric.space(1)) {
            BWCheckbox(BWText["overrideDefaultBrowserAutoFillSettings"],
                       isOn: Binding(get: { preferences.isAutoFillOn }, set: { preferences.setAutoFillOn?($0) }),
                       hint: BWText["usePasskeysDesc"])
                .disabled(preferences.setAutoFillOn == nil)
            BWLink(BWText["autofillSettings"], size: TextStyle.xs.size) { preferences.openAutoFillSettings?() }
                .disabled(preferences.openAutoFillSettings == nil)
        }
        .padding(.bottom, Metric.space(4))
    }

    private var fillShortcut: some View {
        ShortcutSettingRow(title: BWText["enableAutotypeGaShortcut"], isOn: $preferences.isFillShortcutOn,
                           shortcut: preferences.fillShortcut, isAvailable: preferences.isFillShortcutAvailable,
                           hint: preferences.isFillShortcutOn ? BWText["important"] + " " + BWText["enableAutotypeShortcutDescription"] : nil) {
            navigation.editedShortcut = .fill
        }
    }

    /// "default", then every language of the app as "code - name", in the order of the labels.
    private static var languages: [BWSelect<String?>.Option] {
        let named = BWText.languageNames
            .map { (code: $0.key, label: "\($0.key) - \($0.value)") }
            .sorted { $0.label.localizedCompare($1.label) == .orderedAscending }
        return [.init(nil, BWText["default"])] + named.map { .init(Optional($0.code), $0.label) }
    }

    // MARK: Help

    /// The popover behind a question mark (permit-cipher-details-popover and
    /// show-quick-copy-actions-details-popover): "about this setting", the explanation and the
    /// link "learn more", which opens the help page of the reference in the browser.
    private func help(_ topic: HelpTopic, _ textKey: String, _ page: String) -> BWHelp {
        BWHelp(isOpen: Binding(get: { openHelp == topic }, set: { openHelp = $0 ? topic : nil }),
               label: BWText["aboutThisSetting"], title: BWText["aboutThisSetting"], text: BWText[textKey],
               position: .aboveCenter, linkTitle: BWText["learnMore"]) {
            if let url = URL(string: page) { NSWorkspace.shared.open(url) }
        }
    }
}
