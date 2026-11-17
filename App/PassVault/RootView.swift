import DesignKit
import Engine
import SwiftUI

// The window content: one of the screens in Screens/, chosen by the engine state alone.

struct RootView: View {
    let model: AppModel
    let flow: LogInFlow
    let navigation: VaultNavigation
    let preferences: AppPreferences
    @Environment(\.controlActiveState) private var activeState
    /// The notices this window has shown and the engine has not taken off its list yet.
    @State private var shownNotices: Set<EngineNotice> = []

    var body: some View {
        VStack(spacing: 0) {
            // The strip at the top of the reference window; the window buttons sit on it.
            WindowTopBar(model: model, navigation: navigation)
            Group {
                if model.state.activity == .starting {
                    Color.clear
                } else {
                    switch model.state.session {
                    case .loggedOut:
                        if let challenge = model.state.twoStep {
                            TwoStepScreen(model: model, flow: flow, toasts: navigation.toasts, challenge: challenge)
                        } else {
                            LogInScreen(model: model, flow: flow, toasts: navigation.toasts)
                        }
                    case .locked(let account): LockScreen(model: model, toasts: navigation.toasts, account: account)
                    case .unlocked(let account): VaultScreen(model: model, navigation: navigation, preferences: preferences, account: account)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .disabled(model.state.activity == .loggingIn || model.state.activity == .loadingVault)
            .overlay {
                if model.state.session == .loggedOut,
                   model.state.activity == .loggingIn || model.state.activity == .loadingVault {
                    LoginProgressScreen(phase: model.state.authenticationPhase ?? .authenticating)
                }
            }
        }
        .background(.theme(.bgTertiary))
        // This is only an opening effect. The session switch above removes vault views on lock.
        .overlay { VaultOpeningCover(isUnlocked: model.state.session.isUnlocked) }
        // The open menu of a row and the open list of a select of the item form lie over the
        // whole window, behind a dialog.
        .bwMenuHost()
        .bwDropdownHost()
        .bwPopoverHost()
        // A dialog covers the whole window, the strip too.
        .overlay {
            if flow.isServerDialogOpen, !model.state.session.isUnlocked {
                ServerDialog(flow: flow)
            } else if flow.isTwoStepMethodDialogOpen, let challenge = model.state.twoStep {
                TwoStepMethodsDialog(flow: flow, challenge: challenge)
            } else if navigation.protectedAction != nil, model.state.session.isUnlocked {
                MasterPasswordPrompt(model: model, navigation: navigation)
            } else if let form = navigation.itemForm, form.asksForSSHKeyPassword, model.state.session.isUnlocked {
                SSHKeyPasswordDialog(model: model, navigation: navigation, form: form)
            } else if let form = navigation.itemForm, form.isAppPickerOpen, model.state.session.isUnlocked {
                RunningAppsPicker(model: model, navigation: navigation, form: form)
            } else if let form = navigation.itemForm, let dialog = form.fieldDialog, model.state.session.isUnlocked {
                CustomFieldDialog(form: form, dialog: dialog)
            } else if navigation.showsGeneratorHistory, model.state.session.isUnlocked {
                GeneratorHistoryDialog(model: model, navigation: navigation)
            } else if let session = navigation.generator, model.state.session.isUnlocked {
                GeneratorDialog(model: model, navigation: navigation, preferences: preferences, session: session)
            } else if let itemID = navigation.passwordHistoryItemID, model.state.session.isUnlocked {
                PasswordHistoryDialog(model: model, navigation: navigation, itemID: itemID)
            } else if let itemID = navigation.decryptionFailureItemID, model.state.session.isUnlocked {
                DecryptionFailureDialog(model: model, navigation: navigation, itemID: itemID)
            } else if let itemID = navigation.attachmentsItemID, model.state.session.isUnlocked {
                AttachmentsDialog(model: model, navigation: navigation, itemID: itemID)
            } else if let itemIDs = navigation.bulkMoveItemIDs, model.state.session.isUnlocked {
                BulkMoveDialog(model: model, navigation: navigation, itemIDs: itemIDs)
            } else if let itemID = navigation.assignItemID, model.state.session.isUnlocked {
                AssignCollectionsDialog(model: model, navigation: navigation, itemID: itemID)
            } else if let dialog = navigation.folderDialog, model.state.session.isUnlocked {
                FolderDialog(model: model, navigation: navigation, dialog: dialog)
            } else if navigation.settingsTab != nil, case .unlocked(let account) = model.state.session {
                SettingsDialog(model: model, navigation: navigation, preferences: preferences, account: account)
            } else if navigation.isExporting, model.state.session.isUnlocked {
                ExportDialog(model: model, navigation: navigation)
            } else if navigation.isImporting, model.state.session.isUnlocked {
                ImportDialog(model: model, navigation: navigation)
            } else if let result = navigation.importResult, model.state.session.isUnlocked {
                ImportSuccessDialog(result: result) { navigation.importResult = nil }
            }
        }
        // "Type shortcut", which "edit shortcut" of the settings opens: over the settings dialog.
        .overlay {
            if let which = navigation.editedShortcut {
                ShortcutDialog(preferences: preferences, which: which) { navigation.editedShortcut = nil }
            }
        }
        // The question of an action lies over the dialog it was asked from.
        .overlay {
            if let question = navigation.question, model.state.session.isUnlocked {
                BWSimpleDialog(kind: question.kind, title: question.title, text: question.text,
                               acceptTitle: question.acceptTitle) { accepted in
                    navigation.question = nil
                    if accepted { question.onAccept() }
                }
            }
        }
        // "Your account's fingerprint phrase" (libs/auth/src/angular/fingerprint-dialog): the
        // words with hyphens, "learn more", which opens the help of Bitwarden, and "close".
        .overlay {
            if let words = navigation.fingerprintPhrase {
                BWSimpleDialog(kind: .info, title: BWText["yourAccountsFingerprint"] + ":", text: words.joined(separator: "-"),
                               acceptTitle: BWText["learnMore"], cancelTitle: BWText["close"]) { wantsMore in
                    navigation.fingerprintPhrase = nil
                    if wantsMore, let help = URL(string: "https://bitwarden.com/help/fingerprint-phrase/") {
                        NSWorkspace.shared.open(help)
                    }
                }
            }
        }
        // After the capture of the window was turned off, the reference asks whether the window is
        // still seen: a user at a remote screen who sees it no more gets the capture back.
        .overlay {
            if navigation.asksWhetherWindowIsVisible {
                BWSimpleDialog(kind: .info, title: BWText["confirmWindowStillVisibleTitle"],
                               text: BWText["confirmWindowStillVisibleContent"], acceptTitle: BWText["ok"], hasCancel: false) { isSeen in
                    navigation.asksWhetherWindowIsVisible = false
                    if !isSeen { preferences.allowsScreenshots = true }
                }
                .task {
                    // Ten seconds without an answer count as "not seen".
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled, navigation.asksWhetherWindowIsVisible else { return }
                    navigation.asksWhetherWindowIsVisible = false
                    preferences.allowsScreenshots = true
                }
            }
        }
        // Toasts lie over everything, a dialog too.
        .overlay(alignment: .topTrailing) {
            ToastStack(center: navigation.toasts)
        }
        .ignoresSafeArea()
        // What the engine did by itself is told once, and only while the user can see the window.
        .onChange(of: model.state.notices, initial: true) { showNotices() }
        .onChange(of: activeState) { showNotices() }
        // Reset the form only after this window observes the successful session transition.
        .onChange(of: model.state.session.isUnlocked) { _, isUnlocked in
            if isUnlocked { flow.twoStepEnded() }
        }
        // A log-in that waited too long for its second step is given up by the engine.
        .onChange(of: model.state.twoStep == nil) { _, hasEnded in
            guard hasEnded else {
                flow.twoStepEndedByUser = false
                return
            }
            if !flow.twoStepEndedByUser, !model.state.session.isUnlocked {
                navigation.toasts.show(.error, title: BWText["errorOccurred"], message: BWText["sessionTimeout"])
            }
            flow.twoStepEnded()
        }
    }

    /// The notices of the engine as toasts, in the words Bitwarden has for the nearest case.
    private func showNotices() {
        shownNotices.formIntersection(model.state.notices)
        guard activeState != .inactive else { return }
        for notice in model.state.notices where !shownNotices.contains(notice) {
            shownNotices.insert(notice)
            switch notice {
            case .sessionExpired:
                // app.component.ts, displayLogoutReason: "sessionExpired".
                navigation.toasts.show(.warning, title: BWText["loggedOut"], message: BWText["loginExpired"])
            case .storedAccountUnreadable:
                navigation.toasts.show(.error, title: BWText["errorOccurred"], message: BWText["loggedOutDesc"])
            case .storedSettingsUnreadable:
                navigation.toasts.show(.error, title: BWText["errorOccurred"],
                                       message: BWText["settings"] + ": " + BWText["unexpectedError"])
            case .storeUnavailable:
                navigation.toasts.show(.error, title: BWText["errorOccurred"], message: BWText["unexpectedError"])
            case .sshAgentUnlockRequired:
                // The independent SSH window presents the unlock flow.
                break
            case .sshAgentUnlockTimedOut:
                navigation.toasts.show(.error, message: BWText["sshAgentUnlockTimeout"])
            case .sshAgentUnavailable:
                navigation.toasts.show(.error, title: BWText["errorOccurred"],
                                       message: BWText["enableSshAgent"] + ": " + BWText["unexpectedError"])
            }
            Task { await model.dismiss(notice) }
        }
    }
}
