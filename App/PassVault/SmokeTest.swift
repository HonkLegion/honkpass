#if DEBUG
import AppKit
import AutoFillBridge
import DesignKit
import Engine
import EngineFakes
import EngineLive
import VaultModel

/// `--smoke-test` runs this in the real app and exits with 0 or 1.
/// It checks what unit tests cannot: the app's life cycle with a closed main window.
/// With `--fake-backend` it uses the fake account. Without it, it logs in to the development
/// server named by PASSVAULT_SMOKE_SERVER, PASSVAULT_SMOKE_EMAIL and PASSVAULT_SMOKE_PASSWORD.
@MainActor
struct SmokeTest {
    let model: AppModel
    let navigation: VaultNavigation
    let mainWindow: MainWindowController
    let statusItem: StatusItemController
    let quickAccess: QuickAccessPanelController
    let preferences: AppPreferences
    /// The field that the fake backend fills. nil on the local server, where nothing is filled.
    let fakeActiveField: FakeActiveField?
    /// The SSH agent without a socket: the test asks through it what an SSH client would ask.
    let fakeSSHAgent: FakeSSHAgent?
    /// The Keychain behind Touch ID that is none: the test says what the user answers.
    let fakeBiometrics: FakeBiometricKeys?
    /// The server of the fake backend. nil on the local server.
    let fakeServer: FakeServer?
    let sshApprovalWindow: SSHApprovalWindowController

    func run() {
        Task {
            var failures = 0
            func check(_ passed: Bool, _ what: String) {
                print(passed ? "ok    \(what)" : "FAIL  \(what)")
                if !passed { failures += 1 }
            }

            guard let account = credentials else {
                print("FAIL  the smoke test needs --fake-backend or the PASSVAULT_SMOKE_ variables")
                exit(1)
            }
            await wait { model.state.activity == nil }
            check(model.state.session == .loggedOut, "the engine starts logged out")
            check(mainWindow.isVisible, "the main window is open")
            check(NSApp.activationPolicy() == .regular, "the open main window keeps HonkPass in the Dock")
            check(statusItem.isInstalled, "the menu bar item is installed")
            check(statusItem.menuActions == [.show, .quickAccess, .autofill, .lock, .settings, .exit],
                  "the native menu bar menu offers all requested actions in order")
            let updateItem = NSApp.mainMenu?.items.first?.submenu?.items.first {
                $0.action == #selector(AppDelegate.checkForUpdates(_:))
            }
            NSApp.mainMenu?.items.first?.submenu?.update()
            check(updateItem != nil && updateItem?.isEnabled == false,
                  "manual updates are wired but disabled in synthetic runs")
            check(LegalInformation.indexURL.map { FileManager.default.fileExists(atPath: $0.path) } == true,
                  "offline licenses are available from the app bundle")
            check(Self.holdsItsLaunchAgent, "the app holds the launch agent of AutoFill it would register, signed as it asks")

            try? await model.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
            if let twoStep = model.prefill?.twoStep {
                // `--two-step`: the fake account asks for a code first.
                await wait { model.state.twoStep != nil }
                await settle()
                check(model.state.twoStep?.methods == twoStep.methods && !model.state.session.isUnlocked,
                      "the right master password asks for the second step")
                check(showsTextField && !showsPasswordField, "the window shows the two-step screen")
                try? await model.submitTwoStepCode("000000", method: .authenticator, rememberDevice: false)
                check(model.state.twoStep != nil && !model.state.session.isUnlocked, "a wrong code does not log in")
                try? await model.submitTwoStepCode(twoStep.code, method: .authenticator, rememberDevice: false)
            }
            await wait { model.state.session.isUnlocked }
            await settle()
            check(model.state.session.isUnlocked, "log-in unlocks the vault")
            check(showsItemList, "the window shows the item list")
            mainWindow.window.miniaturize(nil)
            await wait { mainWindow.window.isMiniaturized }
            check(mainWindow.window.isMiniaturized && NSApp.activationPolicy() == .regular,
                  "minimizing the main window retains its Dock entry")
            mainWindow.show()
            await settle()
            check(!mainWindow.window.isMiniaturized && mainWindow.isVisible && NSApp.activationPolicy() == .regular,
                  "showing the main window restores it from the Dock")
            mainWindow.close()
            mainWindow.show()
            await settle()
            check(mainWindow.isVisible && NSApp.activationPolicy() == .regular,
                  "immediate reopening cannot leave the main window without a Dock entry")
            await FileWorkSmokeChecks.run(model: model, check: check)

            let originalFrame = mainWindow.window.frame
            mainWindow.window.setContentSize(NSSize(width: 1200, height: 800))
            navigation.isSideNavigationCollapsed = false
            await settle()
            let expandedFrames = navigationScrollFrames
            navigation.isSideNavigationCollapsed = true
            var collapsedSamples: [CGFloat] = []
            for _ in 0..<35 {
                try? await Task.sleep(for: .milliseconds(10))
                if let first = navigationScrollFrames.first { collapsedSamples.append(first.width) }
            }
            let collapsedFrames = navigationScrollFrames
            navigation.isSideNavigationCollapsed = false
            var expandedSamples: [CGFloat] = []
            for _ in 0..<35 {
                try? await Task.sleep(for: .milliseconds(10))
                if let first = navigationScrollFrames.first { expandedSamples.append(first.width) }
            }
            if expandedFrames.count >= 2, collapsedFrames.count >= 2 {
                let wide = expandedFrames[0].width
                let narrow = collapsedFrames[0].width
                let motionReduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                let between: (CGFloat) -> Bool = { $0 > narrow + 1 && $0 < wide - 1 }
                check(wide > narrow && (motionReduced || (collapsedSamples.contains(where: between) && expandedSamples.contains(where: between))),
                      "the navigation animates its width in both directions unless Reduce Motion is enabled")
                check(abs((expandedFrames[1].minX - collapsedFrames[1].minX) - (wide - narrow)) < 2,
                      "the list receives the space released by the navigation")
            } else {
                check(false, "the navigation and list expose scroll frames for the animation check")
            }
            mainWindow.window.setFrame(originalFrame, display: true)
            await settle()

            let scrollAreas = count(NSScrollView.self)
            let item = model.state.vault.items.first { $0.type == .login && !$0.isInTrash }
            navigation.openItemID = item?.id
            await settle()
            check(item != nil && count(NSScrollView.self) == scrollAreas + 1, "an item opens in a panel beside the list")
            let opened = await (try? model.item(id: item?.id ?? ""))
            check(opened?.name == item?.name && opened?.type == .login, "the engine gives the open item with its fields")

            // The keyboard in an open menu: the first item has the focus, the arrows go round,
            // Return chooses and Escape closes. Nothing here is written to the server.
            navigation.isNewMenuOpen = true
            await settle()
            mainWindow.window.press(.down)
            mainWindow.window.press(.return)
            await wait { navigation.itemForm != nil }
            var isCardForm = false
            if case .card = navigation.itemForm?.draft.content { isCardForm = true }
            check(isCardForm && !navigation.isNewMenuOpen, "arrow down and Return choose the second item of an open menu")
            // The new form has put the cursor into its name field: the menu takes the keyboard from it.
            await settle()
            navigation.isNewMenuOpen = true
            await settle()
            mainWindow.window.press(.up)
            mainWindow.window.press(.return)
            await wait { navigation.folderDialog != nil }
            check(navigation.folderDialog == .add && !navigation.isNewMenuOpen && navigation.itemForm?.draft.name == "",
                  "arrow up goes from the first item of a menu to the last one, and the keys stay out of the form under it")
            navigation.folderDialog = nil
            navigation.itemForm = nil
            await settle()
            navigation.isNewMenuOpen = true
            await settle()
            mainWindow.window.press(.escape)
            await wait { !navigation.isNewMenuOpen }
            check(!navigation.isNewMenuOpen && navigation.itemForm == nil && navigation.folderDialog == nil,
                  "Escape closes an open menu and chooses nothing")
            // Escape in the search field empties a search that has a text.
            navigation.search = "zz"
            navigation.searchFocusRequest += 1
            await settle()
            mainWindow.window.press(.escape, givesContentTheKeyboard: false)
            await wait { navigation.search.isEmpty }
            check(navigation.search.isEmpty, "Escape in the search of the vault empties the search")
            navigation.search = ""
            await settle()

            // Closing the drawer in a narrow window restores the list's former search focus.
            let frameBeforeNarrowSearch = mainWindow.window.frame
            mainWindow.window.setContentSize(NSSize(width: 600, height: 500))
            navigation.openItemID = item?.id
            await settle()
            mainWindow.window.makeFirstResponder(nil)
            navigation.openItemID = nil
            await settle()
            check((mainWindow.window.firstResponder as? NSTextView)?.isFieldEditor == true,
                  "closing a narrow item panel restores keyboard focus to vault search")

            navigation.openItemID = item?.id
            await settle()
            navigation.searchFocusRequest += 1
            await wait { navigation.openItemID == nil }
            await settle()
            check(navigation.openItemID == nil && (mainWindow.window.firstResponder as? NSTextView)?.isFieldEditor == true,
                  "search requested behind a narrow detail reveals and focuses the list header")

            let searchForm = ItemForm(mode: .new, draft: ItemDraft(new: .login))
            searchForm.draft.name = "Synthetic unsaved search check"
            navigation.itemForm = searchForm
            await settle()
            navigation.searchFocusRequest += 1
            await wait { navigation.question != nil }
            check(navigation.question != nil && navigation.itemForm === searchForm && searchForm.isDirty,
                  "search behind a narrow dirty editor asks before discarding its changes")
            navigation.question = nil
            navigation.itemForm = nil
            await settle()
            mainWindow.window.setFrame(frameBeforeNarrowSearch, display: true)
            await settle()

            // Escape while the keyboard is in no view, as after a click beside a field: the
            // window gets the key and closes the dialog on top. The settings keep nothing
            // when they are only opened.
            navigation.settingsTab = .app
            await settle()
            mainWindow.window.makeFirstResponder(nil)
            mainWindow.window.press(.escape, givesContentTheKeyboard: false)
            await wait { navigation.settingsTab == nil }
            check(navigation.settingsTab == nil, "Escape closes a dialog while the keyboard is in no view")
            navigation.settingsTab = nil
            await settle()

            if model.prefill != nil, let item {
                // The actions of the row menu and of the panel. Only on the fake backend: the
                // items of the development server stay as they are.
                let listed = { @MainActor in model.state.vault.items.first { $0.id == item.id } }
                navigation.openMenuItemID = item.id
                await settle()
                check(navigation.openMenuItemID == item.id && model.state.session.isUnlocked, "the menu of a row is open")
                navigation.openMenuItemID = nil

                // The copy menu of an SSH key: private key, public key, fingerprint. The second
                // item goes to the clipboard of the fake backend, and the window says which.
                if let key = model.state.vault.items.first(where: { $0.type == .sshKey && !$0.isInTrash }) {
                    navigation.openCopyMenuItemID = key.id
                    await settle()
                    mainWindow.window.press(.down)
                    mainWindow.window.press(.return)
                    let said = BWText["valueCopied", BWText["sshPublicKey"]]
                    await wait { navigation.toasts.toasts.contains { $0.message == said } }
                    check(navigation.openCopyMenuItemID == nil && navigation.toasts.toasts.contains { $0.message == said },
                          "the copy menu of an SSH key copies its public key")
                }
                ItemActions(model: model, navigation: navigation).toggleFavorite(item)
                await wait { listed()?.isFavorite == !item.isFavorite }
                check(listed()?.isFavorite == !item.isFavorite, "the menu of a row changes the favourite mark")

                let panel = ItemActions(model: model, navigation: navigation, isPanel: true)
                panel.delete(item)
                await settle()
                check(navigation.question != nil && listed()?.isInTrash == false, "\"delete\" in the panel asks first")
                let question = navigation.question
                navigation.question = nil
                question?.onAccept()
                await wait { listed()?.isInTrash == true && navigation.openItemID == nil }
                check(listed()?.isInTrash == true && navigation.openItemID == nil,
                      "the answer \"yes\" moves the item to the trash and closes its panel")
                if let trashed = listed() { panel.restore(trashed) }
                await wait { listed()?.isInTrash == false }
                check(listed()?.isInTrash == false, "\"restore\" takes the item out of the trash")
                navigation.openItemID = item.id
                await settle()

                // The form of the item, saved through the same actions as the buttons of the window.
                panel.edit(item)
                await wait { navigation.itemForm != nil }
                check(navigation.itemForm?.mode == .edit && navigation.itemForm?.draft.name == item.name,
                      "\"edit\" opens the form with the content of the item")
                navigation.itemForm?.draft.name = ""
                if let form = navigation.itemForm { panel.save(form) }
                await settle()
                check(navigation.itemForm?.showsNameError == true && listed()?.name == item.name, "a form without a name is not saved")
                navigation.itemForm?.draft.name = item.name + ", edited"
                if let form = navigation.itemForm { panel.save(form) }
                await wait { navigation.itemForm == nil }
                check(listed()?.name == item.name + ", edited" && navigation.openItemID == item.id,
                      "the saved form shows the changed item in its panel")

                ItemActions(model: model, navigation: navigation).add(.secureNote)
                navigation.itemForm?.draft.name = "A new note"
                navigation.itemForm?.draft.notes = "A fake note of the smoke test."
                if let form = navigation.itemForm { panel.save(form) }
                await wait { navigation.itemForm == nil }
                // The window model follows the engine a moment later.
                await wait { model.state.vault.items.contains { $0.name == "A new note" } && navigation.openItemID != item.id }
                let added = model.state.vault.items.first { $0.name == "A new note" }
                check(added?.type == .secureNote && navigation.openItemID == added?.id, "the form of a new item adds it and shows it")
                navigation.openItemID = item.id
                await settle()
            }

            if model.prefill != nil {
                // A folder through the actions of its dialog, on the fake backend only.
                let folders = FolderActions(model: model, navigation: navigation)
                navigation.folderDialog = .add
                await folders.save(id: nil, name: "Smoke folder")
                // The window model follows the engine a moment later.
                await wait { model.state.vault.folders.contains { $0.name == "Smoke folder" } }
                let added = model.state.vault.folders.first { $0.name == "Smoke folder" }
                check(added != nil && navigation.folderDialog == nil, "the folder dialog adds a folder and closes")
                if let added {
                    // A folder named after it with a slash lies under it in the tree.
                    await folders.save(id: nil, name: "Smoke folder/Inner")
                    await wait { model.state.vault.folders.contains { $0.name == "Smoke folder/Inner" } }
                    let parent = model.state.vault.folderTree.first { $0.id == added.id }
                    check(parent?.children.map(\.name) == ["Inner"], "a folder with a slash in its name lies under its parent in the tree")
                    if let inner = model.state.vault.folders.first(where: { $0.name == "Smoke folder/Inner" }) {
                        try? await model.deleteFolder(id: inner.id)
                        await wait { !model.state.vault.folders.contains { $0.id == inner.id } }
                    }
                    await folders.save(id: added.id, name: "Smoke folder, renamed")
                    await wait { model.state.vault.folders.contains { $0.name == "Smoke folder, renamed" } }
                    check(model.state.vault.folders.contains { $0.id == added.id && $0.name == "Smoke folder, renamed" },
                          "the folder dialog renames a folder")
                    navigation.filter = .folder(added.id)
                    folders.delete(added)
                    check(navigation.question != nil, "\"delete folder\" asks first")
                    let question = navigation.question
                    navigation.question = nil
                    question?.onAccept()
                    await wait { !model.state.vault.folders.contains { $0.id == added.id } }
                    await settle()
                    check(!model.state.vault.folders.contains { $0.id == added.id } && navigation.filter == .allItems,
                          "the answer \"yes\" deletes the folder and the list shows all items")
                }
                // Several ticked rows through the actions of the bar, on the fake backend only.
                let bulk = ItemActions(model: model, navigation: navigation)
                let chosen = Array(model.state.vault.items.filter { !$0.isInTrash && !$0.isArchived }.prefix(2))
                navigation.checkedItemIDs = Set(chosen.map(\.id))
                await settle()
                bulk.bulkDelete(chosen)
                let deleteQuestion = navigation.question
                navigation.question = nil
                check(deleteQuestion?.kind == .danger, "\"delete\" in the bar of bulk actions asks first")
                deleteQuestion?.onAccept()
                await wait { model.state.vault.items.filter { item in chosen.contains { $0.id == item.id } }.allSatisfy(\.isInTrash) }
                let trashed = model.state.vault.items.filter { item in chosen.contains { $0.id == item.id } }
                check(trashed.count == 2 && trashed.allSatisfy(\.isInTrash) && navigation.checkedItemIDs.isEmpty,
                      "the answer moves both items to the trash and unticks them")
                bulk.bulkRestore(trashed)
                await wait { model.state.vault.items.filter { item in chosen.contains { $0.id == item.id } }.allSatisfy { !$0.isInTrash } }
                check(model.state.vault.items.filter { item in chosen.contains { $0.id == item.id } }.allSatisfy { !$0.isInTrash },
                      "\"restore\" takes both out of the trash")
                if let folder = model.state.vault.folders.first {
                    bulk.sendBulk(.moveToFolder(folder.id), of: chosen, done: "movedItems")
                    await wait { model.state.vault.items.filter { item in chosen.contains { $0.id == item.id } }.allSatisfy { $0.folderID == folder.id } }
                    check(model.state.vault.items.filter { item in chosen.contains { $0.id == item.id } }.allSatisfy { $0.folderID == folder.id },
                          "\"add to folder\" moves both items to the folder")
                }

                // A file through the actions of the attachments dialog: a synthetic one in the temporary folder.
                if let item {
                    let panel = ItemActions(model: model, navigation: navigation, isPanel: true)
                    let source = FileManager.default.temporaryDirectory.appending(path: "passvault-smoke-\(UUID().uuidString).txt")
                    let content = Data("A synthetic attachment of the smoke test.".utf8)
                    try? content.write(to: source)
                    defer { try? FileManager.default.removeItem(at: source) }
                    navigation.attachmentsItemID = item.id
                    // The fake server stops half way: the engine says how much has gone.
                    await fakeServer?.holdNextUpload()
                    let upload = Task { await panel.upload(source, toItem: item.id) }
                    if let fakeServer {
                        await fakeServer.uploadIsHeld()
                        await wait { model.state.upload?.percent == 50 }
                        check(model.state.upload == AttachmentUpload(itemID: item.id, percent: 50),
                              "while a file goes, the engine says how much of it has gone")
                        await fakeServer.releaseUpload()
                    }
                    let uploaded = await upload.value
                    await wait { model.state.vault.items.first { $0.id == item.id }?.attachmentCount == 1 }
                    let files = await (try? model.item(id: item.id).attachments) ?? []
                    check(uploaded && files.map(\.fileName) == [source.lastPathComponent], "the attachments dialog adds a file to the item")
                    // The state of the engine reaches the window through its stream, a moment after the command.
                    await wait { model.state.upload == nil }
                    check(model.state.upload == nil, "after the upload no file is said to be on its way")
                    if let file = files.first {
                        let fetched = await panel.fetch(file, ofItem: item.id)
                        check(fetched?.data == content, "the file comes back with its content")
                        panel.deleteAttachment(file, ofItem: item.id)
                        let question = navigation.question
                        navigation.question = nil
                        question?.onAccept()
                        await wait { model.state.vault.items.first { $0.id == item.id }?.attachmentCount == 0 }
                        check(question != nil && model.state.vault.items.first { $0.id == item.id }?.attachmentCount == 0,
                              "\"delete attachment\" asks first and removes the file")
                    }
                    check(!(await panel.upload(nil, toItem: item.id)), "an upload without a chosen file is refused")
                    navigation.attachmentsItemID = nil
                }

                // An SSH key from the clipboard of the fake backend, which is not the one of the Mac.
                let keyActions = ItemActions(model: model, navigation: navigation)
                keyActions.add(.sshKey)
                await wait { navigation.itemForm != nil }
                if let form = navigation.itemForm {
                    try? await model.copy(text: "fake-ssh-key:mine", isSensitive: true)
                    keyActions.importSSHKey(into: form)
                    await wait { form.draft.content == .sshKey(SSHKeyContent(privateKey: "fake-private-key-mine",
                        publicKey: "ssh-ed25519 fake-public-key-mine", fingerprint: "SHA256:fake-mine")) }
                    if case .sshKey(let key) = form.draft.content {
                        check(key.fingerprint == "SHA256:fake-mine", "the form of an SSH key takes a key from the clipboard")
                    }
                    try? await model.copy(text: "fake-encrypted-ssh-key:synthetic-passphrase:locked", isSensitive: true)
                    keyActions.importSSHKey(into: form)
                    await wait { form.asksForSSHKeyPassword }
                    check(form.asksForSSHKeyPassword, "an encrypted key asks for its password")
                    keyActions.importSSHKey(into: form, password: "synthetic-passphrase")
                    await wait { !form.asksForSSHKeyPassword }
                    if case .sshKey(let key) = form.draft.content {
                        check(key.fingerprint == "SHA256:fake-locked" && !form.asksForSSHKeyPassword,
                              "the right password takes the encrypted key and closes the question")
                    }
                }
                navigation.itemForm = nil

                // A catch-all address that starts with the name of the website of a login form.
                var loginDraft = ItemDraft(new: .login)
                loginDraft.content = .login(ItemDraft.Login(websites: [ItemDraft.Website(address: "https://shop.example.com/login")]))
                var addressOptions = GeneratorOptions()
                addressOptions.username.kind = .catchallEmail
                addressOptions.username.domain = "example.org"
                addressOptions.username.catchallUsesWebsiteName = true
                let addressSession = GeneratorSession(purpose: .username(ItemForm(mode: .new, draft: loginDraft)), options: addressOptions)
                navigation.generator = addressSession
                await wait { !addressSession.value.isEmpty }
                check(addressSession.value == "shop.example.com@example.org", "the generator of a login form makes an address from its website")
                navigation.generator = nil

                // The generator, with the fake one of the fake backend: it shows what was asked for.
                var options = GeneratorOptions()
                options.password.length = 9
                let session = GeneratorSession(purpose: .standalone, options: options)
                navigation.generator = session
                await wait { !session.value.isEmpty }
                check(session.value == "Ab3Ab3Ab3", "the generator dialog shows a value for its options")
                session.options.kind = .passphrase
                await wait { session.value.contains("-") }
                check(session.value == "fake-fake-fake-fake-fake-fake" && model.state.settings.generator.kind == .passphrase,
                      "a changed option gives a new value and is kept with the settings")
                navigation.generator = nil
                let known = await (try? model.timesLeaked(password: "password"))
                check((known ?? 0) > 0, "the check of a leaked password answers, here from the fake service")
            }

            // The real generator of the SDK on the local server run, the fake one else.
            let generated = GeneratorSession(purpose: .standalone, options: GeneratorOptions())
            navigation.generator = generated
            await wait { !generated.value.isEmpty }
            check(generated.value.count == 14, "the generator makes a password of fourteen characters")
            let kept = await (try? model.generatorHistory()) ?? []
            check(kept.first?.value == generated.value && kept.first?.kind == .password, "the history of the generator has the new value first")

            // A form is open when the vault locks.
            if let item { ItemActions(model: model, navigation: navigation, isPanel: true).edit(item) }
            await wait { navigation.itemForm != nil }
            check(navigation.itemForm != nil, "the form of an item opens")

            // The rows of the form change places, as the handles of the form move them.
            if let form = navigation.itemForm, case .login(var login) = form.draft.content {
                login.websites = [ItemDraft.Website(address: "https://first.example"), ItemDraft.Website(address: "https://second.example")]
                form.draft.content = .login(login)
                form.openMatchDetection = [0]
                form.moveWebsite(from: 0, to: 1)
                if case .login(let moved) = form.draft.content {
                    check(moved.websites.map(\.address) == ["https://second.example", "https://first.example"]
                        && form.openMatchDetection == [1], "a website of the form moves with its open match detection")
                }
                form.draft = form.original
                form.openMatchDetection = []
            }

            // A form with changes asks before it gives way; a form without changes does not.
            var hasLeft = false
            navigation.leaveForm { hasLeft = true }
            check(hasLeft && navigation.question == nil, "a form without changes gives way without a question")
            navigation.itemForm?.draft.name += ", changed"
            hasLeft = false
            navigation.leaveForm { hasLeft = true }
            check(!hasLeft && navigation.question != nil, "a form with changes asks before it gives way")
            navigation.question = nil
            check(navigation.itemForm?.isDirty == true, "the answer \"no\" keeps the form with its changes")
            navigation.leaveForm { hasLeft = true }
            let leave = navigation.question
            navigation.question = nil
            leave?.onAccept()
            check(hasLeft, "the answer \"yes\" lets the form go")
            if let form = navigation.itemForm { form.draft = form.original }

            var changed = model.state.settings
            changed.clipboardClearing = .after(seconds: 10)
            try? await model.setSettings(changed)
            await wait { model.state.settings == changed }
            check(model.state.settings == changed, "changed settings are saved and published")
            // The fingerprint phrase of the account menu, and the capture of the window.
            check(performMenuItem(#selector(AppDelegate.showFingerprintPhrase(_:))), "the menu has \"fingerprint phrase\" for an open vault")
            await wait { navigation.fingerprintPhrase != nil }
            check(navigation.fingerprintPhrase?.count == 5, "\"fingerprint phrase\" shows the five words of the account")
            navigation.fingerprintPhrase = nil
            preferences.allowsScreenshots = false
            check(mainWindow.window.sharingType == .none && quickAccess.window.sharingType == .none,
                  "without \"allow screen capture\" the windows are kept out of screenshots")
            preferences.allowsScreenshots = true
            check(mainWindow.window.sharingType == .readOnly, "with it they can be captured again")
            // Export and import of the file menu open their dialogs; an import adds its items.
            check(performMenuItem(#selector(AppDelegate.exportVault(_:))) && navigation.isExporting, "the menu opens \"export\"")
            navigation.isExporting = false
            check(performMenuItem(#selector(AppDelegate.importVault(_:))) && navigation.isImporting, "the menu opens \"import\"")
            navigation.isImporting = false
            let itemsBeforeImport = model.state.vault.items.count
            let csv = "folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n"
                + "Example Temporary Folder,,login,Example Temporary Imported,,,,https://imported.example,imported-user,synthetic,\n"
            if let read = try? VaultImportFormat.bitwardenCSV.read(Data(csv.utf8)) {
                try? await model.importVault(read)
                await wait { model.state.vault.items.count == itemsBeforeImport + 1 }
                let imported = model.state.vault.items.first { $0.name == "Example Temporary Imported" }
                let folder = model.state.vault.folders.first { $0.name == "Example Temporary Folder" }
                check(imported != nil && folder != nil && imported?.folderID == folder?.id,
                      "an import of a CSV export adds its login in its folder")
                // It leaves the vault as it found it.
                if let imported {
                    try? await model.change(.moveToTrash, of: imported.id)
                    try? await model.change(.deletePermanently, of: imported.id)
                }
                if let folder { try? await model.deleteFolder(id: folder.id) }
                await wait { model.state.vault.items.count == itemsBeforeImport }
            } else {
                check(false, "the reader reads a CSV export")
            }
            // The Sends: the form of a new text Send makes one, its row opens its view with a
            // link, and it is deleted again.
            navigation.showSends(nil)
            await settle()
            check(navigation.page == .sends, "the side navigation shows the Sends")
            let sendActions = SendActions(model: model, navigation: navigation)
            sendActions.add(.text)
            if let form = navigation.sendForm {
                sendActions.save(form)
                check(form.showsErrors && navigation.sendForm === form, "a Send without a name and a text is not saved")
                form.name = "Example Temporary Smoke Send"
                form.text = "synthetic"
                form.deletion = .hours(1)
                sendActions.save(form)
                await wait { navigation.sendForm == nil && model.state.vault.sends.contains { $0.name == form.name } }
            }
            let madeSend = model.state.vault.sends.first { $0.name == "Example Temporary Smoke Send" }
            check(madeSend != nil && navigation.sendForm == nil, "the form of a new Send makes it and closes")
            if let madeSend {
                sendActions.open(madeSend)
                await wait { navigation.sendForm?.original?.id == madeSend.id }
                let shown = navigation.sendForm
                check(shown?.isEditing == false && shown?.original?.linkPath?.contains("/") == true && shown?.text == "synthetic",
                      "the row of a Send opens its view with its link and its text")
                try? await model.deleteSend(id: madeSend.id)
                await wait { !model.state.vault.sends.contains { $0.id == madeSend.id } }
                check(!model.state.vault.sends.contains { $0.id == madeSend.id }, "a Send is deleted")
            }
            navigation.sendForm = nil
            navigation.showVault(.allItems)
            await settle()
            // Organizations, where the account has one (the fake one has): "assign to collections"
            // of a row gives a new item to the organization, and the list of the organization shows it.
            if let organization = model.state.vault.organizations.first,
               let collection = model.state.vault.assignableCollections(of: organization.id).first {
                var draft = ItemDraft(new: .secureNote)
                draft.name = "Example Temporary Shared Note"
                let noteID = try? await model.save(draft)
                await wait { model.state.vault.items.contains { $0.name == draft.name } }
                if let noteID, let note = model.state.vault.items.first(where: { $0.id == noteID }) {
                    let actions = ItemActions(model: model, navigation: navigation)
                    actions.assignToCollections(note)
                    check(navigation.assignItemID == noteID, "the menu of a row opens \"assign to collections\"")
                    actions.assign(note, to: organization, collectionIDs: [collection.id])
                    await wait { navigation.assignItemID == nil }
                    navigation.owner = .organization(organization.id)
                    await settle()
                    let shown = model.state.vault.items(in: .allItems, owner: navigation.owner).map(\.id)
                    check(shown.contains(noteID) && model.state.vault.items.first { $0.id == noteID }?.collectionIDs == [collection.id],
                          "an assigned item belongs to the organization and shows in its vault")
                    navigation.owner = .all
                    try? await model.change(.moveToTrash, of: noteID)
                    try? await model.change(.deletePermanently, of: noteID)
                    await wait { !model.state.vault.items.contains { $0.id == noteID } }
                }
            }
            // The SSH agent: turned on in the settings it offers the key of the vault, the use of
            // the key asks in a dialog, and "authorize" lets it sign.
            if let fakeSSHAgent {
                var withAgent = model.state.settings
                withAgent.sshAgent = SSHAgentSettings(isEnabled: true, prompt: .always)
                try? await model.setSettings(withAgent)
                var keys: [SSHAgentIdentity] = []
                for _ in 0..<100 where keys.isEmpty {
                    try? await Task.sleep(for: .milliseconds(50))
                    keys = await fakeSSHAgent.requests?.sshIdentities() ?? []
                }
                check(keys.map(\.name) == ["Example SSH Key"], "the SSH agent offers the SSH key of the vault")
                if let key = keys.first, let client = await fakeSSHAgent.requests {
                    mainWindow.close()
                    let asking = Task {
                        await client.sshSignature(for: SSHSignRequest(publicKeyBlob: key.publicKeyBlob, data: Data("synthetic".utf8),
                                                                      processName: "ssh", namespace: "git"))
                    }
                    await wait { model.state.sshApproval != nil && sshApprovalWindow.window?.isVisible == true }
                    let approval = model.state.sshApproval
                    check(approval?.keyName == "Example SSH Key" && approval?.action == .signGit,
                          "a use of the key asks with the dialog \"confirm SSH key usage\"")
                    check(sshApprovalWindow.window?.isVisible == true && !mainWindow.isVisible,
                          "SSH approval has its own glass window while the main window stays closed")
                    check(NSApp.activationPolicy() == .accessory,
                          "SSH approval works without restoring the Dock entry")
                    @MainActor func visibleText(_ view: NSView) -> [String] {
                        guard !view.isHiddenOrHasHiddenAncestor else { return [] }
                        return ((view as? NSTextField).map { [$0.stringValue] } ?? [])
                            + view.subviews.flatMap { visibleText($0) }
                    }
                    let visible = sshApprovalWindow.window?.contentView.map { visibleText($0) } ?? []
                    check(visible.contains(approval?.keyName ?? "") && approval?.publicKeyFingerprint != nil
                            && visible.contains(approval?.publicKeyFingerprint ?? ""),
                          "the requested SSH key and public fingerprint are visible without expanding a control")
                    NSApp.activate(ignoringOtherApps: true)
                    await wait { NSApp.isActive }
                    sshApprovalWindow.window?.makeKeyAndOrderFront(nil)
                    await wait { NSApp.isActive && sshApprovalWindow.window?.isKeyWindow == true }
                    check(NSApp.isActive && sshApprovalWindow.window?.isKeyWindow == true,
                          "the SSH window receives keyboard focus before keyboard approval")
                    sshApprovalWindow.window?.press(.return, givesContentTheKeyboard: false)
                    await settle()
                    check(model.state.sshApproval?.id == approval?.id, "an initial Return never approves a new SSH request")
                    check(sshApprovalWindow.window?.hasCenteredFingerprint() == true,
                          "the public fingerprint and Copy control stay centered after the initial Return")
                    // Activation can leave no initial control focused. Exercise Tab navigation
                    // until the actual Authorize control owns focus, rather than assuming one step.
                    var reachedAuthorize = false
                    for _ in 0..<6 {
                        sshApprovalWindow.window?.press(.tab, givesContentTheKeyboard: false)
                        if (sshApprovalWindow.window?.firstResponder as? NSButton)?.title == BWText["authorize"] {
                            reachedAuthorize = true
                            break
                        }
                    }
                    check(reachedAuthorize, "Tab navigation reaches the Authorize control before Return")
                    if reachedAuthorize { sshApprovalWindow.window?.press(.return, givesContentTheKeyboard: false) }
                    await wait { model.state.sshApproval == nil }
                    if let pending = model.state.sshApproval { await model.cancelSSHRequest(id: pending.id) }
                    let signature = await asking.value
                    check(signature?.isEmpty == false && model.state.sshApproval == nil, "\"authorize\" lets the key sign")

                    let denied = Task {
                        await client.sshSignature(for: SSHSignRequest(publicKeyBlob: key.publicKeyBlob, data: Data("synthetic".utf8)))
                    }
                    await wait { sshApprovalWindow.window?.isVisible == true }
                    sshApprovalWindow.window?.performClose(nil)
                    await wait { model.state.sshApproval == nil }
                    if let pending = model.state.sshApproval { await model.cancelSSHRequest(id: pending.id) }
                    check(await denied.value == nil && !mainWindow.isVisible, "closing the independent SSH window denies its request")

                    await model.lock()
                    await wait { !model.state.session.isUnlocked }
                    let lockedRequest = Task {
                        await client.sshSignature(for: SSHSignRequest(publicKeyBlob: key.publicKeyBlob, data: Data("synthetic".utf8), processName: "ssh"))
                    }
                    await wait { model.state.sshUnlockRequest != nil && sshApprovalWindow.window?.isUnlocking == true }
                    check(sshApprovalWindow.window?.isVisible == true && !mainWindow.isVisible && model.state.sshApproval == nil,
                          "a locked SSH request opens its own unlock flow without the main window or key data")
                    try? await model.unlock(masterPassword: account.masterPassword)
                    await wait { model.state.sshApproval != nil && sshApprovalWindow.window?.isUnlocking == false }
                    check(model.state.sshApproval != nil && !mainWindow.isVisible,
                          "unlocking the SSH flow leaves the required signing consent pending")
                    check(sshApprovalWindow.window?.hasCenteredFingerprint() == true,
                          "the public fingerprint and Copy control stay centered after unlock")
                    sshApprovalWindow.window?.press(.escape, givesContentTheKeyboard: false)
                    await wait { model.state.sshApproval == nil }
                    if let pending = model.state.sshApproval { await model.cancelSSHRequest(id: pending.id) }
                    check(await lockedRequest.value == nil, "Escape denies the SSH request after unlock")
                }
                withAgent.sshAgent = .default
                try? await model.setSettings(withAgent)
                await wait { model.state.settings.sshAgent == .default }
                mainWindow.show()
            }
            // The keyboard in the open list of a select: the list opens on the chosen row.
            // One dialog is drawn at a time, and the generator is still open.
            navigation.generator = nil
            await settle()
            changed.lockPolicy.timeout = .afterInactivity(minutes: 15)
            try? await model.setSettings(changed)
            await wait { model.state.settings == changed }
            navigation.settingsStartWithOpenList = true
            navigation.settingsTab = .security
            await settle()
            mainWindow.window.press(.down)
            mainWindow.window.press(.down)
            mainWindow.window.press(.return)
            await wait { model.state.settings.lockPolicy.timeout == .afterInactivity(minutes: 60) }
            check(model.state.settings.lockPolicy.timeout == .afterInactivity(minutes: 60),
                  "two arrows down and Return choose the second next row of an open list")
            // The closed select has the keyboard again: an arrow opens its list, and what is
            // typed leaves the rows that contain it, here the one of four hours.
            await settle()
            mainWindow.window.press(.down)
            await settle()
            mainWindow.window.press(.text("4"))
            await settle()
            mainWindow.window.press(.return)
            await wait { model.state.settings.lockPolicy.timeout == .afterInactivity(minutes: 240) }
            check(model.state.settings.lockPolicy.timeout == .afterInactivity(minutes: 240),
                  "an arrow opens a closed select, and a typed text and Return choose the row that contains it")
            navigation.settingsStartWithOpenList = false
            await settle()

            // A new shortcut for quick access, typed into the dialog that "edit shortcut" of the
            // settings opens. A test run takes no shortcut from the system; the dialog and what
            // it keeps are what is tried.
            navigation.settingsTab = .app
            await settle()
            navigation.isEditingShortcut = true
            await settle()
            check(navigation.isEditingShortcut && preferences.isRecordingShortcut,
                  "while a shortcut is typed, the one in use is given back")
            mainWindow.window.press(.text("k"))
            mainWindow.window.press(.return)
            await settle()
            check(preferences.quickAccessShortcut == .quickAccess && preferences.isRecordingShortcut,
                  "a key without Command, Control or Option is no shortcut, and the dialog stays")
            mainWindow.window.press(.command("k"))
            mainWindow.window.press(.return)
            await wait { !preferences.isRecordingShortcut }
            check(preferences.quickAccessShortcut.display == "⌘K" && !preferences.isRecordingShortcut && !navigation.isEditingShortcut,
                  "a typed shortcut is kept, and the dialog closes")
            // The enable switch persists independently of the shortcut value and the fill switch.
            let shortcutSuite = "HonkPass.shortcut-test." + UUID().uuidString
            if let defaults = UserDefaults(suiteName: shortcutSuite) {
                defer { defaults.removePersistentDomain(forName: shortcutSuite) }
                let saved = AppPreferences(defaults: defaults)
                check(saved.isQuickAccessShortcutOn, "quick access stays enabled when no switch preference exists")
                var changes = 0
                saved.onQuickAccessShortcutChanged = { changes += 1 }
                saved.quickAccessShortcut = BWKeyShortcut(keyCode: 40, modifiers: [.command], keyName: "k")
                saved.isQuickAccessShortcutOn = false
                let restored = AppPreferences(defaults: defaults)
                check(!restored.isQuickAccessShortcutOn && restored.quickAccessShortcut.display == "⌘K"
                      && !restored.isFillShortcutOn && changes == 2,
                      "disabling quick access persists, retains its keys and requests hotkey registration to update")
                saved.isQuickAccessShortcutOn = true
                saved.isRecordingShortcut = true
                saved.isRecordingShortcut = false
                check(changes == 5 && AppPreferences(defaults: defaults).isQuickAccessShortcutOn,
                      "enabling and recording notify the hotkey owner, and enabling persists")
            }
            navigation.settingsTab = .security
            await settle()
            check(navigation.settingsTab == .security && model.state.session.isUnlocked, "the settings dialog is open")

            mainWindow.close()
            await settle()
            check(!mainWindow.isVisible, "the main window is closed")
            check(NSApp.activationPolicy() == .accessory, "closing the main window removes HonkPass from the Dock")
            check(statusItem.isInstalled, "the menu bar item is still installed")
            check(model.state.session.isUnlocked, "the engine is still unlocked without a window")
            check(!model.state.vault.items.isEmpty, "the engine still holds the vault")
            check(!quickAccess.state.isPresented && quickAccessScrollAreas == 0,
                  "hidden quick access builds no vault list after login")

            // Quick access: a window of its own on the same engine, over a closed main window.
            // It stays open while the user works in another app during the test.
            quickAccess.closesWithoutKeyboard = false
            // First without a field to fill, as with an app in front that has none: Return shows the item.
            await fakeActiveField?.setField(nil)
            let quickRows = model.state.vault.quickAccessRows(search: "").map(\.item)
            let loginPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                                     styleMask: [.titled], backing: .buffered, defer: false)
            loginPanel.title = "Synthetic login"
            loginPanel.level = .modalPanel
            loginPanel.hidesOnDeactivate = false
            loginPanel.isReleasedWhenClosed = false
            loginPanel.center()
            loginPanel.orderFrontRegardless()
            _ = statusItem.perform(.quickAccess)
            await settle()
            // Use the window server's visible stacking order, including nonactivating panels.
            let ordered = ((CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]) ?? []).compactMap { $0[kCGWindowNumber as String] as? Int }
            let quickIndex = ordered.firstIndex(of: quickAccess.window.windowNumber)
            let loginIndex = ordered.firstIndex(of: loginPanel.windowNumber)
            let aboveLogin = quickAccess.window.level > loginPanel.level && quickAccess.window.worksWhenModal
                && (quickIndex ?? Int.max) < (loginIndex ?? -1)
            if !aboveLogin {
                print("Window order: quick=\(String(describing: quickIndex)) login=\(String(describing: loginIndex)) levels=\(quickAccess.window.level.rawValue),\(loginPanel.level.rawValue) modal=\(quickAccess.window.worksWhenModal)")
            }
            check(aboveLogin,
                  "Quick Access opens above a modal login panel")
            loginPanel.close()
            check(quickAccess.isShown && !mainWindow.isVisible,
                  "the menu bar Quick Access action opens the panel while the main window stays closed")
            check(NSApp.activationPolicy() == .accessory, "Quick Access leaves HonkPass out of the Dock")
            check(quickAccess.window.contentView is NSGlassEffectView
                  && quickAccess.window.frame.width == Metric.quickAccessWidth,
                  "compact quick access uses a native Liquid Glass surface at the approved width")
            check(quickAccess.hasFittingContent, "the glass and hosted content fit the compact window after resizing")
            // The menu action uses the same Spotlight-style placement as the shortcut.
            let panelFrame = quickAccess.window.frame
            let panelScreen = NSScreen.screens.first { $0.frame.intersects(panelFrame) }?.visibleFrame
            check(panelScreen.map {
                let top = $0.maxY - max(($0.height - panelFrame.height) * 0.2, 0)
                return $0.contains(panelFrame) && abs($0.midX - panelFrame.midX) <= 1 && abs(top - panelFrame.maxY) <= 1
            } == true, "the menu bar opens quick access in the screen's upper center")
            quickAccess.close()
            await settle()
            check(!quickAccess.isShown && !mainWindow.isVisible, "closing Quick Access leaves the main window closed")
            check(!quickAccess.state.isPresented && quickAccessScrollAreas == 0,
                  "closing quick access removes its list from the view hierarchy")
            quickAccess.toggle()
            await settle()
            check(quickAccess.window.frame == panelFrame,
                  "the shortcut and menu bar action open quick access at the same position")
            quickAccess.closesWithoutKeyboard = true
            // Send the native key-window transition directly. The app need not own the
            // active desktop while an unattended smoke run is in progress.
            quickAccess.window.resignKey()
            await wait { !quickAccess.isShown && quickAccessScrollAreas == 0 }
            check(!quickAccess.isShown && !quickAccess.state.isPresented && quickAccessScrollAreas == 0,
                  "losing keyboard focus closes quick access and removes its content")
            check(model.state.session.isUnlocked, "closing quick access on focus loss leaves the vault unlocked")
            quickAccess.closesWithoutKeyboard = false
            quickAccess.close()
            _ = statusItem.perform(.quickAccess)
            await settle()
            quickAccess.window.press(.escape)
            await wait { !quickAccess.isShown }
            check(!quickAccess.isShown && !mainWindow.isVisible, "Escape closes quick access")
            // A search with a text takes the first Escape for itself.
            quickAccess.show()
            await settle()
            quickAccess.state.search = "a"
            await settle()
            quickAccess.window.press(.escape)
            await wait { quickAccess.state.search.isEmpty }
            check(quickAccess.state.search.isEmpty && quickAccess.isShown,
                  "Escape in a search with a text empties the search and closes nothing")
            quickAccess.window.press(.escape)
            await wait { !quickAccess.isShown }
            check(!quickAccess.isShown, "a second Escape closes quick access")
            quickAccess.show()
            await settle()
            quickAccess.window.press(.down)
            quickAccess.window.press(.return)
            await wait { mainWindow.isVisible }
            await settle()
            check(quickRows.count > 1 && navigation.openItemID == quickRows[1].id && !quickAccess.isShown && mainWindow.isVisible,
                  "arrow down and Return in quick access show the second item in the main window")
            check(NSApp.activationPolicy() == .regular, "opening an item from Quick Access restores the Dock entry")
            if let last = quickRows.last {
                quickAccess.show()
                await settle()
                quickAccess.state.search = last.name
                await settle()
                quickAccess.window.press(.return)
                await wait { navigation.openItemID == last.id }
                check(navigation.openItemID == last.id && !quickAccess.isShown && quickAccess.state.search.isEmpty,
                      "a search and Return in quick access show the item that was found, and the search is forgotten")
            }
            await fakeActiveField?.setField(FillTarget(appName: "Fake Editor"))
            // Copying and the menu of a row. Only on the fake backend, whose clipboard is not the
            // one of the Mac and whose items may change.
            if model.prefill != nil,
               let login = quickRows.first(where: { $0.type == .login && $0.fields.contains(.username) && $0.fields.contains(.password) }) {
                let row = login.id
                let said = { @MainActor (key: String) in
                    let message = BWText["valueCopied", BWText[key]]
                    return quickAccess.navigation.toasts.toasts.contains { $0.message == message }
                }
                quickAccess.show()
                await settle()
                quickAccess.state.search = login.name
                await settle()
                quickAccess.window.press(.command("u"))
                await wait { said("username") }
                check(said("username") && quickAccess.isShown, "Command-U in quick access copies the user name of the row the keyboard is on")
                quickAccess.navigation.openCopyMenuItemID = row
                await settle()
                quickAccess.window.press(.down)
                quickAccess.window.press(.return)
                await wait { said("password") }
                check(said("password") && quickAccess.isShown && quickAccess.navigation.openCopyMenuItemID == nil,
                      "the copy menu of a row copies the password, and the panel stays open")
                let listed = { @MainActor in model.state.vault.items.first { $0.id == login.id } }
                for _ in 0..<2 {
                    // The first item of the menu sets the favourite mark, and takes it away again.
                    let wasFavorite = listed()?.isFavorite == true
                    quickAccess.navigation.openMenuItemID = row
                    await settle()
                    quickAccess.window.press(.return)
                    await wait { listed()?.isFavorite == !wasFavorite }
                    check(listed()?.isFavorite == !wasFavorite && quickAccess.isShown, "the menu of a row changes the favourite mark from the panel")
                }
                // Fill: the fake backend has a field of its own in place of one of another app.
                if let fakeActiveField {
                    let password = await (try? model.item(id: login.id))?.value(of: .password)
                    check(quickAccess.state.target?.appName == "Fake Editor",
                          "quick access knows the field that had the cursor when it opened")
                    quickAccess.window.press(.return)
                    await settle()
                    check(quickAccess.state.fillMenuRowID == row, "with a field to fill, Return offers the fields of the row")
                    quickAccess.window.press(.down)
                    quickAccess.window.press(.return)
                    await settle()
                    check(quickAccess.state.pendingFill?.field == .password && quickAccess.isShown,
                          "a chosen field waits for the answer to \"confirm autofill\"")
                    quickAccess.window.press(.return)
                    var written: [String] = []
                    for _ in 0..<60 where written.isEmpty {
                        written = await fakeActiveField.written.map(\.text)
                        if written.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
                    }
                    check(password != nil && written == [password ?? ""] && !quickAccess.isShown,
                          "the password goes into the field of the app in front, and the panel closes")

                    // A login form on a page of the login: Return fills the user name and the
                    // password into its two fields, without a menu and without a question.
                    let page = model.state.vault.items.first { $0.id == login.id }?.websites.first?.address
                    await fakeActiveField.setField(FillTarget(appName: "Fake Browser", bundleID: "test.fake.browser", website: page,
                                                              takesLogin: true))
                    quickAccess.show()
                    await settle()
                    quickAccess.state.search = login.name
                    await settle()
                    quickAccess.window.press(.return)
                    var filled: (username: String, password: String)?
                    for _ in 0..<60 where filled == nil {
                        filled = await fakeActiveField.writtenLogins.first.map { ($0.username, $0.password) }
                        if filled == nil { try? await Task.sleep(for: .milliseconds(50)) }
                    }
                    let writtenAfter = await fakeActiveField.written.count
                    check(page != nil && filled?.username == login.subtitle && filled?.password == password && writtenAfter == 1
                          && !quickAccess.isShown,
                          "into a login form of the login's page, Return fills the user name and the password at once")

                    // The shortcut that fills without the panel: the one login of the page in
                    // front goes into its form at once; a page without a login opens the panel.
                    await fakeActiveField.setField(FillTarget(appName: "Fake Browser", bundleID: "test.fake.browser", website: page,
                                                              takesLogin: true))
                    check(statusItem.perform(.autofill), "the menu bar AutoFill action uses the existing fill command")
                    var byShortcut = 0
                    for _ in 0..<60 where byShortcut < 2 {
                        byShortcut = await fakeActiveField.writtenLogins.count
                        if byShortcut < 2 { try? await Task.sleep(for: .milliseconds(50)) }
                    }
                    let last = await fakeActiveField.writtenLogins.last
                    check(byShortcut == 2 && last?.username == login.subtitle && last?.password == password && !quickAccess.isShown,
                          "the shortcut fills the one login of the page in front, and no panel opens")
                    let writtenBeforeCode = await fakeActiveField.written.count
                    await fakeActiveField.setField(FillTarget(appName: "Fake Browser", bundleID: "test.fake.browser",
                                                              website: page, isUnclassifiedCode: true))
                    quickAccess.fillFromShortcut()
                    await wait { quickAccess.isShown }
                    let writtenAfterCode = await fakeActiveField.written.count
                    let loginsAfterCode = await fakeActiveField.writtenLogins.count
                    check(quickAccess.isShown && writtenAfterCode == writtenBeforeCode && loginsAfterCode == byShortcut,
                          "the shortcut opens a field choice for an ambiguous code instead of filling the email")
                    quickAccess.close()
                    await settle()
                    await fakeActiveField.setField(FillTarget(appName: "Fake Browser", bundleID: "test.fake.browser",
                                                              website: "https://no-login.example/", takesLogin: true))
                    quickAccess.fillFromShortcut()
                    await wait { quickAccess.isShown }
                    let afterNone = await fakeActiveField.writtenLogins.count
                    check(quickAccess.isShown && afterNone == 2, "on a page without a login the shortcut opens quick access and fills nothing")
                    quickAccess.close()
                    await settle()

                    // A page that is not one of the login: the question comes, the arrow up
                    // marks "autofill and save this site", and Return fills and adds the page.
                    let newPage = "https://smoke-new-site.example/login"
                    await fakeActiveField.setField(FillTarget(appName: "Fake Browser", bundleID: "test.fake.browser", website: newPage,
                                                              takesLogin: true))
                    quickAccess.show()
                    await settle()
                    quickAccess.state.search = login.name
                    await settle()
                    quickAccess.window.press(.return)
                    await settle()
                    check(quickAccess.state.pendingFill?.item.id == login.id && quickAccess.state.fillAnswers == [.saveAndFill, .fill, .cancel]
                          && quickAccess.state.markedFillAnswer == .fill,
                          "on another page the fill of a login asks first, and Return would fill only")
                    quickAccess.window.press(.up)
                    quickAccess.window.press(.return)
                    await wait { model.state.vault.items.first { $0.id == login.id }?.websites.contains { $0.address == newPage } == true }
                    let afterSaving = await fakeActiveField.writtenLogins.count
                    check(afterSaving == 3 && model.state.vault.items.first { $0.id == login.id }?.websites.contains { $0.address == newPage } == true,
                          "\"autofill and save this site\" fills the login and adds the page to its websites")
                    await fakeActiveField.setField(FillTarget(appName: "Fake Editor", bundleID: "test.fake.editor"))

                    // The cursor leaves the field after the panel opened: nothing is written, and the panel says so.
                    quickAccess.show()
                    await settle()
                    quickAccess.state.search = login.name
                    await settle()
                    await fakeActiveField.setField(nil)
                    quickAccess.window.press(.return)
                    await settle()
                    quickAccess.window.press(.return)
                    await settle()
                    quickAccess.window.press(.return)
                    let failed = BWText["autofillError"]
                    await wait { quickAccess.navigation.toasts.toasts.contains { $0.message == failed } }
                    let afterFailure = await fakeActiveField.written.count
                    check(quickAccess.isShown && quickAccess.navigation.toasts.toasts.contains { $0.message == failed } && afterFailure == 1,
                          "a field that is gone is not filled: the panel comes back and says so")
                    await settle()
                    check(quickAccess.state.search.isEmpty && quickAccess.window.frame.height == Metric.quickAccessHeight,
                          "a failed fill restores the full result list at its expanded height")

                    // Without the permission of the system there is no field, and "fill" asks the system for it.
                    await fakeActiveField.setField(FillTarget(appName: "Fake Editor"))
                    await fakeActiveField.setPermitted(false)
                    quickAccess.close()
                    quickAccess.show()
                    await settle()
                    quickAccess.state.search = login.name
                    await settle()
                    let hadTarget = quickAccess.state.target != nil
                    quickAccess.state.fillMenuRowID = row
                    await settle()
                    quickAccess.window.press(.return)
                    var asked = 0
                    for _ in 0..<60 where asked == 0 {
                        asked = await fakeActiveField.askedForPermission
                        if asked == 0 { try? await Task.sleep(for: .milliseconds(50)) }
                    }
                    let afterRefusal = await fakeActiveField.written.count
                    check(!hadTarget && asked == 1 && afterRefusal == 1 && !quickAccess.isShown,
                          "without the permission nothing is filled, and \"fill\" has the system ask for it")
                    await fakeActiveField.setPermitted(true)

                    // A field on a page of the login: the login is in the first list, and it is
                    // filled without the question.
                    if let address = listed()?.websites.first?.address {
                        let username = await (try? model.item(id: login.id))?.value(of: .username)
                        await fakeActiveField.setField(FillTarget(appName: "Fake Browser", website: address + "/login"))
                        quickAccess.show()
                        await settle()
                        let first = model.state.vault.quickAccessSections(search: "", page: quickAccess.state.target?.website).first
                        check(first?.kind == .suggestions && first?.items.map(\.id) == [login.id],
                              "the login of the page in front is the first list of quick access")
                        quickAccess.window.press(.return)
                        await settle()
                        quickAccess.window.press(.return)
                        var texts: [String] = []
                        for _ in 0..<60 where texts.count < 2 {
                            texts = await fakeActiveField.written.map(\.text)
                            if texts.count < 2 { try? await Task.sleep(for: .milliseconds(50)) }
                        }
                        check(username != nil && texts.last == username && texts.count == 2 && !quickAccess.isShown,
                              "a login of the page in front is filled without the question")
                        await fakeActiveField.setField(FillTarget(appName: "Fake Editor"))
                    }

                    // The apps of a login. The form adds an app of the disk by its signature; the
                    // login then belongs to that app, as it belongs to the pages of its websites.
                    quickAccess.close()
                    await settle()
                    if let editor = FakeAppSignatures.editorAddress, let draft = try? await model.draft(of: login.id) {
                        let before = listed()?.websites ?? []
                        let form = ItemForm(mode: .edit, draft: draft)
                        navigation.itemForm = form
                        let actions = ItemActions(model: model, navigation: navigation)
                        let websiteRows = form.websiteRows.count
                        actions.addApp(at: FakeAppSignatures.editor, to: form)
                        await wait { form.appRows.count == 1 && !form.isReadingApp }
                        check(form.appRows.count == 1 && form.websiteRows.count == websiteRows && form.isDirty,
                              "\"app\" of \"add website or app\" adds an app of the disk to the form of a login, apart from its websites")
                        for refused in [FakeAppSignatures.unsigned, FakeAppSignatures.browser, FakeAppSignatures.editor] {
                            actions.addApp(at: refused, to: form)
                            await wait { !form.isReadingApp }
                        }
                        check(form.appRows.count == 1 && form.websiteRows.count == websiteRows,
                              "an app that nobody signed, a browser and an app the login has already are not added")
                        if case .login(var content) = form.draft.content {
                            content.websites.removeAll { $0.app != nil }
                            form.draft.content = .login(content)
                        }
                        form.isAppPickerOpen = true
                        await settle()
                        let running = (try? await model.runningApps()) ?? []
                        if let selected = running.first {
                            actions.addApp(runningID: selected.id, to: form)
                            await wait { !form.isReadingApp }
                        }
                        check(running.map(\.id) == [FakeAppSignatures.editorID] && form.appRows.count == 1 && !form.isAppPickerOpen,
                              "the running-app picker verifies the selected application and adds it to the draft")
                        _ = try? await model.save(form.draft)
                        await wait { listed()?.websites.contains { $0.app == editor } == true }
                        check(listed()?.websites.contains { $0.app == editor && $0.match == .never } == true,
                              "the login keeps the address of the app among its websites, matched \"never\"")
                        navigation.itemForm = nil

                        // The app in front is the app of the login: the shortcut fills at once.
                        let filledBefore = await fakeActiveField.writtenLogins.count
                        await fakeActiveField.setField(FillTarget(appName: "Fake Editor", bundleID: "test.fake.editor", app: editor,
                                                                  takesLogin: true))
                        quickAccess.fillFromShortcut()
                        var filled = filledBefore
                        for _ in 0..<60 where filled == filledBefore {
                            filled = await fakeActiveField.writtenLogins.count
                            if filled == filledBefore { try? await Task.sleep(for: .milliseconds(50)) }
                        }
                        let byShortcut = await fakeActiveField.writtenLogins.last
                        check(filled == filledBefore + 1 && byShortcut?.username == login.subtitle && !quickAccess.isShown,
                              "the shortcut fills the one login of the app in front, and no panel opens")
                        quickAccess.show()
                        await settle()
                        let suggested = model.state.vault.quickAccessSections(search: "", page: quickAccess.state.target?.website,
                                                                              app: quickAccess.state.target?.app).first
                        check(quickAccess.state.target?.app == editor && suggested?.kind == .suggestions
                              && suggested?.items.map(\.id) == [login.id],
                              "the login of the app in front is the first list of quick access")
                        quickAccess.window.press(.return)
                        for _ in 0..<60 where filled == filledBefore + 1 {
                            filled = await fakeActiveField.writtenLogins.count
                            if filled == filledBefore + 1 { try? await Task.sleep(for: .milliseconds(50)) }
                        }
                        await settle()
                        check(filled == filledBefore + 2 && !quickAccess.isShown, "a login of the app in front is filled without the question")

                        // The same name under another developer is another app: the fill asks first.
                        await fakeActiveField.setField(FillTarget(appName: "Fake Editor", bundleID: "test.fake.editor",
                                                                  app: AppAddress(bundleID: "test.fake.editor", developer: "OTHERTEAM9"),
                                                                  takesLogin: true))
                        quickAccess.show()
                        await settle()
                        quickAccess.state.search = login.name
                        await settle()
                        quickAccess.window.press(.return)
                        await settle()
                        let afterImpostor = await fakeActiveField.writtenLogins.count
                        check(quickAccess.state.pendingFill?.item.id == login.id && quickAccess.state.fillAnswers == [.saveAppAndFill, .fill, .cancel]
                              && afterImpostor == filledBefore + 2,
                              "in an app that another developer signed under the same identifier the fill asks first")
                        quickAccess.answerFill(.cancel)
                        quickAccess.close()
                        await settle()

                        // The app is taken out again: the login is as it was.
                        if var restored = try? await model.draft(of: login.id), case .login(var content) = restored.content {
                            content.websites.removeAll { $0.app != nil }
                            restored.content = .login(content)
                            _ = try? await model.save(restored)
                            await wait { listed()?.websites == before }
                        }
                        check(listed()?.websites == before && model.state.vault.logins(ofApp: editor).isEmpty,
                              "a login without the address of the app is no login of the app")
                        let target = FillTarget(appName: "Fake Editor", bundleID: editor.bundleID, app: editor)
                        await fakeActiveField.setField(target)
                        let writtenBefore = await fakeActiveField.written.count
                        quickAccess.show()
                        await settle()
                        quickAccess.requestFill(.username, of: listed() ?? login)
                        check(quickAccess.state.fillAnswers == [.saveAppAndFill, .fill, .cancel]
                              && quickAccess.state.markedFillAnswer == .fill,
                              "native fill confirmation offers explicit app saving and defaults to fill only")
                        quickAccess.answerFill(.fill)
                        await wait { !quickAccess.isShown }
                        for _ in 0..<60 where await fakeActiveField.written.count == writtenBefore {
                            try? await Task.sleep(for: .milliseconds(50))
                        }
                        check(model.state.vault.logins(ofApp: editor).isEmpty,
                              "fill only never adds an application association")
                        quickAccess.show()
                        await settle()
                        quickAccess.requestFill(.username, of: listed() ?? login)
                        quickAccess.answerFill(.saveAppAndFill)
                        await wait { model.state.vault.logins(ofApp: editor).contains { $0.id == login.id } }
                        check(await fakeActiveField.written.count == writtenBefore + 2
                              && listed()?.websites.contains { $0.app == editor && $0.match == .never } == true,
                              "explicit fill and save writes once and stores the captured app with match never")
                        if var restored = try? await model.draft(of: login.id), case .login(var content) = restored.content {
                            content.websites.removeAll { $0.app != nil }
                            restored.content = .login(content)
                            _ = try? await model.save(restored)
                            await wait { listed()?.websites == before }
                        }
                        await fakeActiveField.setField(FillTarget(appName: "Fake Editor"))
                    }
                    quickAccess.show()
                    await settle()
                    quickAccess.state.search = login.name
                    await settle()
                }
                quickAccess.navigation.openMenuItemID = row
                await settle()
                quickAccess.window.press(.down)
                quickAccess.window.press(.return)
                await wait { navigation.itemForm?.mode == .edit }
                check(navigation.itemForm?.mode == .edit && navigation.itemForm?.draft.id == login.id && mainWindow.isVisible
                    && !quickAccess.isShown, "\"edit\" in the menu of a row opens the form in the main window")
                navigation.itemForm = nil
            }
            // The shortcut that works in every app is not taken in a test run. That the system
            // gives one is tried with a key combination nobody uses, which is given back at once.
            let hotKey = GlobalHotKey(BWKeyShortcut(keyCode: 80, modifiers: [.control, .option, .shift, .command], keyName: "")) {}
            check(hotKey != nil, "the system gives PassVault a shortcut that works in every app")
            hotKey?.release()
            // Quick access closed the form to show an item; a form is open again when the vault locks.
            if let item { ItemActions(model: model, navigation: navigation, isPanel: true).edit(item) }
            await wait { navigation.itemForm != nil }
            mainWindow.close()
            await settle()

            check(performMenuItem(#selector(AppDelegate.lockVault(_:))), "the application menu has an enabled item that locks")
            await wait { !model.state.session.isUnlocked }
            check(model.state.session.account != nil && !model.state.session.isUnlocked, "the application menu locks the engine without a window")
            check(model.state.vault == .empty, "no vault data is left after the lock")
            check(navigation.openItemID == nil, "the lock closes the open item")
            check(navigation.itemForm == nil, "the lock throws the open form away")
            check(navigation.generator == nil, "the lock closes the generator")
            check(navigation.settingsTab == nil, "the lock closes the settings dialog")
            check(model.state.settings.clipboardClearing == .after(seconds: 10), "the settings stay with the locked account")
            check(!performMenuItem(#selector(AppDelegate.lockVault(_:))), "the lock item is disabled while the vault is locked")
            check(!performMenuItem(#selector(AppDelegate.openSettings(_:))), "the settings item is disabled while the vault is locked")
            check(!statusItem.perform(.settings) && !statusItem.perform(.lock),
                  "the menu bar disables Settings and Lock for a locked vault")

            // Locked, quick access shows no item and offers the main window.
            quickAccess.show()
            await settle()
            check(quickAccess.isShown && !mainWindow.isVisible && model.state.vault.quickAccessSections(search: "").isEmpty,
                  "quick access opens over a locked vault and has no item to show")
            quickAccess.window.press(.return)
            await wait { mainWindow.isVisible }
            check(mainWindow.isVisible && !quickAccess.isShown, "Return in locked quick access shows the main window")
            mainWindow.close()
            await settle()

            check(statusItem.perform(.show), "the menu of the menu bar item has \"show\"")
            await settle()
            check(mainWindow.isVisible, "\"show\" in the menu bar opens the main window again")
            check(NSApp.activationPolicy() == .regular, "reopening from the menu bar restores the Dock entry")
            check(showsPasswordField && !showsItemList, "the window shows the unlock screen, not the items")

            try? await model.unlock(masterPassword: account.masterPassword)
            await wait { model.state.session.isUnlocked }
            await settle()
            check(showsItemList, "unlock in the window shows the item list again")

            mainWindow.close()
            await settle()
            check(statusItem.perform(.settings), "Settings opens from the menu bar while the main window is closed")
            await settle()
            check(mainWindow.isVisible && navigation.settingsTab != nil && NSApp.activationPolicy() == .regular,
                  "opening Settings restores the main window and its Dock entry")
            navigation.settingsTab = nil
            mainWindow.close()
            await settle()
            _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
            await settle()
            check(mainWindow.isVisible && NSApp.activationPolicy() == .regular,
                  "a Finder reopen request restores the main window and its Dock entry")

            // A PIN, through the real SDK when the app runs on it.
            try? await model.setPin("4812", asksForMasterPasswordAfterRestart: false)
            await wait { model.state.pin.canUnlock }
            check(model.state.pin == PinState(isSet: true, asksForMasterPasswordAfterRestart: false, canUnlock: true),
                  "a PIN is set for the unlocked account")
            await model.lock()
            await wait { !model.state.session.isUnlocked }
            await settle()
            check(showsPasswordField && !showsItemList, "the locked window asks for the PIN")
            try? await model.unlock(pin: "0000")
            check(!model.state.session.isUnlocked, "a wrong PIN does not unlock")
            try? await model.unlock(pin: "4812")
            await wait { model.state.session.isUnlocked }
            await settle()
            check(model.state.session.isUnlocked && showsItemList, "the PIN unlocks the vault and the window shows the items")
            try? await model.removePin()
            await wait { !model.state.pin.isSet }
            check(model.state.pin == .none, "the PIN is removed")

            // Touch ID, with a sensor and a Keychain that are none: the test says what the user
            // answers, and no finger is asked for.
            if let fakeBiometrics {
                let reason = BWText["touchIdConsentMessage"]
                check(!model.state.biometrics.isAvailable, "a Mac without a sensor in reach offers no Touch ID")
                await fakeBiometrics.setSensorAvailable(true)
                await model.refreshBiometrics()
                try? await model.setBiometricUnlock(true)
                // The window model follows the engine a moment later.
                await wait { model.state.biometrics.canUnlock }
                var kept = await fakeBiometrics.kept.count
                check(model.state.biometrics.canUnlock && kept == 1,
                      "with a sensor in reach the unlock with Touch ID is turned on, and its key is kept")
                await model.lock()
                await wait { !model.state.session.isUnlocked }
                await settle()
                check(!showsPasswordField && !showsItemList, "the locked window starts with the button of Touch ID, with no field for a secret")
                await fakeBiometrics.setAnswer(.cancel)
                try? await model.unlockWithBiometrics(reason: reason)
                check(!model.state.session.isUnlocked, "a question for Touch ID that the user closes leaves the vault locked")
                await fakeBiometrics.setAnswer(.accept)
                try? await model.unlockWithBiometrics(reason: reason)
                await wait { model.state.session.isUnlocked }
                await settle()
                let asked = await fakeBiometrics.reasons
                check(model.state.session.isUnlocked && showsItemList && asked.count == 2 && asked.last == reason,
                      "Touch ID unlocks the vault and the window shows the items")

                // Quick access on the locked vault: Return is "unlock with Touch ID", and the
                // panel stays open for the question of the system.
                await model.lock()
                await wait { !model.state.session.isUnlocked }
                quickAccess.show()
                await wait { quickAccess.isShown }
                await settle()
                await fakeBiometrics.setAnswer(.cancel)
                quickAccess.window.press(.return)
                for _ in 0..<100 where await fakeBiometrics.reasons.count < 3 {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                await settle()
                var askedInPanel = await fakeBiometrics.reasons.count
                check(askedInPanel == 3 && quickAccess.isShown && !model.state.session.isUnlocked,
                      "in quick access a question for Touch ID that the user closes leaves the panel open and the vault locked")
                await fakeBiometrics.setAnswer(.accept)
                quickAccess.window.press(.return)
                await wait { model.state.session.isUnlocked }
                await settle()
                askedInPanel = await fakeBiometrics.reasons.count
                check(askedInPanel == 4 && quickAccess.isShown && model.state.session.isUnlocked,
                      "Touch ID opens the vault from quick access, which stays open")
                quickAccess.close()
                await settle()

                // The keyboard with the sensor is taken away: the key stays, the button goes.
                await model.lock()
                await wait { !model.state.session.isUnlocked }
                await fakeBiometrics.setSensorAvailable(false)
                await model.refreshBiometrics()
                await wait { !model.state.biometrics.canUnlock }
                await settle()
                check(model.state.biometrics.isEnabled && !model.state.biometrics.canUnlock && showsPasswordField,
                      "without the sensor the locked window asks for the master password")
                try? await model.unlock(masterPassword: account.masterPassword)
                await wait { model.state.session.isUnlocked }
                await fakeBiometrics.setSensorAvailable(true)
                await model.refreshBiometrics()
                try? await model.setBiometricUnlock(false)
                await wait { !model.state.biometrics.isEnabled }
                kept = await fakeBiometrics.kept.count
                check(!model.state.biometrics.isEnabled && kept == 0, "turned off, the unlock with Touch ID keeps no key")
                await fakeBiometrics.setSensorAvailable(false)
                await model.refreshBiometrics()
                await settle()
            }

            // "Keep running in the background": without it the menu bar item is gone. The window
            // stays open here: closing it would then quit the app.
            preferences.runsInBackground = false
            await settle()
            check(!statusItem.isShown, "without \"keep running in the background\" the menu bar item is gone")
            check(NSApp.activationPolicy() == .regular, "disabling background mode retains the open window's Dock entry")
            preferences.runsInBackground = true
            await settle()
            check(statusItem.isShown && statusItem.isInstalled, "with it the menu bar item is back")

            // "Add account" puts the account aside and shows the log-in; the menu of accounts
            // leads back to it, locked.
            let accountID = model.state.session.account?.id
            try? await model.addAccount()
            await wait { model.state.session == .loggedOut }
            await settle()
            check(model.state.session == .loggedOut && model.state.otherAccounts.map(\.id) == [accountID].compactMap { $0 },
                  "\"add account\" shows the log-in and keeps the account waiting")
            check(!showsItemList, "the window shows no item of the account that waits")
            if let accountID { try? await model.switchAccount(to: accountID) }
            await wait { model.state.session.account?.id == accountID }
            await settle()
            check(model.state.session.account?.id == accountID && !model.state.session.isUnlocked && model.state.otherAccounts.isEmpty,
                  "the menu of accounts switches back to the account, which is locked")
            try? await model.unlock(masterPassword: account.masterPassword)
            await wait { model.state.session.isUnlocked }
            await settle()
            check(showsItemList, "the account opens again with its master password")

            if model.prefill == nil {
                // Only the signed app can use the Keychain, so the store on disk is checked here,
                // with a synthetic record, its own Keychain item and a temporary folder.
                let (survives, isRemoved, remembers) = await checkAccountStore()
                check(survives, "an account saved to disk and Keychain is loaded by a new store")
                check(isRemoved, "clearing the store removes the account and its Keychain item")
                check(remembers, "a remembered device and a PIN are kept in the Keychain and can be removed")
            }

            print(failures == 0 ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED (\(failures))")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
    }

    private func checkAccountStore() async -> (survives: Bool, isRemoved: Bool, remembers: Bool) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "passvault-smoke-\(UUID().uuidString)")
        let secrets = KeychainSecretStore(service: "PassVault.smoke-test")
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = StoredAccount(
            account: Account(id: "00000000-0000-4000-8000-000000000002", email: "smoke@passvault.test",
                             serverURL: URL(string: "http://localhost:8642")!),
            crypto: AccountCryptoMaterial(kdf: .pbkdf2(iterations: 600_000), salt: "smoke@passvault.test",
                                          masterKeyWrappedUserKey: "2.synthetic", keys: .v1(privateKey: "2.synthetic")),
            accessToken: "synthetic-access-token", refreshToken: "synthetic-refresh-token",
            accessTokenExpiry: Date(timeIntervalSince1970: 1_800_003_600), vaultPayload: Data("{}".utf8),
            lastSync: Date(timeIntervalSince1970: 1_800_000_000))
        do {
            let server = record.account.serverURL, email = record.account.email
            try await FileAccountStore(directory: directory, secrets: secrets).save(record)
            try await FileAccountStore(directory: directory, secrets: secrets)
                .saveTwoStepRememberToken("synthetic-remember-token", server: server, email: email)
            let loaded = try await FileAccountStore(directory: directory, secrets: secrets).load()
            try await FileAccountStore(directory: directory, secrets: secrets).clear()
            let afterClear = try await FileAccountStore(directory: directory, secrets: secrets).load()
            let item = try secrets.read("session-tokens")
            let remembered = try await FileAccountStore(directory: directory, secrets: secrets)
                .twoStepRememberToken(server: server, email: email)
            try await FileAccountStore(directory: directory, secrets: secrets)
                .saveTwoStepRememberToken(nil, server: server, email: email)
            let forgotten = try secrets.read("two-step-remember") == nil
            // The PIN lies in the Keychain as well.
            let pin = StoredPin(envelope: "synthetic-envelope", encryptedPin: "2.synthetic", failedAttempts: 2)
            try await FileAccountStore(directory: directory, secrets: secrets).savePin(pin, accountID: record.account.id)
            let loadedPin = try await FileAccountStore(directory: directory, secrets: secrets).loadPin(accountID: record.account.id)
            try await FileAccountStore(directory: directory, secrets: secrets).savePin(nil, accountID: record.account.id)
            let pinIsGone = try secrets.read("pin") == nil
            return (loaded == record, afterClear == nil && item == nil,
                    remembered == "synthetic-remember-token" && forgotten && loadedPin == pin && pinIsGone)
        } catch {
            print("      store error: \(error)")
            return (false, false, false)
        }
    }

    /// Chooses the first item of the application menu with this action, as a click or its
    /// shortcut does. Returns false when there is none or the item is disabled.
    /// The launch agent in the app is the one the app names: its property list lies where the
    /// system looks for it, with the label and the services the app uses, and its program has
    /// the signature the app asks of the agent. Nothing is registered and nothing is started.
    private static var holdsItsLaunchAgent: Bool {
        guard let peers = try? AutoFillPeers.current(as: .app) else { return false }
        let app = Bundle.main.bundleURL
        let list = app.appending(path: "Contents/Library/LaunchAgents").appending(path: peers.agentPropertyList)
        guard let data = try? Data(contentsOf: list),
              let facts = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              facts["Label"] as? String == peers.agentLabel,
              let services = facts["MachServices"] as? [String: Any],
              Set(services.keys) == [peers.service(.publish), peers.service(.lookup)],
              let program = facts["BundleProgram"] as? String else { return false }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app.appending(path: program) as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(peers.requirement(for: .agent) as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
    }

    private func performMenuItem(_ action: Selector) -> Bool {
        func find(_ menu: NSMenu) -> (menu: NSMenu, index: Int)? {
            menu.update()
            for (index, item) in menu.items.enumerated() {
                if item.action == action, item.submenu == nil { return (menu, index) }
                if let submenu = item.submenu, let found = find(submenu) { return found }
            }
            return nil
        }
        guard let main = NSApp.mainMenu, let found = find(main), found.menu.items[found.index].isEnabled else { return false }
        found.menu.performActionForItem(at: found.index)
        return true
    }

    private var credentials: (server: URL, email: String, masterPassword: String)? {
        if let fake = model.prefill { return (fake.server, fake.email, fake.masterPassword) }
        return LaunchOptions.testCredentials
    }

    /// Waits up to five seconds for the condition.
    private func wait(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Gives SwiftUI time to draw the state it was given.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(400))
    }

    /// The vault screen has two scroll areas at least, its navigation and its list. The
    /// screens before the vault have one: their page, which scrolls in a low window.
    private var showsItemList: Bool { count(NSScrollView.self) > 1 }
    private var navigationScrollFrames: [CGRect] {
        guard let root = mainWindow.window.contentView else { return [] }
        func frames(_ view: NSView) -> [CGRect] {
            let own = view is NSScrollView && !view.isHidden ? [view.convert(view.bounds, to: root)] : []
            return own + view.subviews.flatMap(frames)
        }
        return frames(root).filter { $0.width > 1 && $0.height > 20 }.sorted { $0.minX < $1.minX }
    }
    private var showsPasswordField: Bool { contains(NSSecureTextField.self) }
    private var showsTextField: Bool { contains(NSTextField.self) }

    private func contains<View: NSView>(_ type: View.Type) -> Bool {
        count(type) > 0
    }

    private func count<View: NSView>(_ type: View.Type) -> Int {
        func search(_ view: NSView) -> Int {
            (view is View ? 1 : 0) + view.subviews.reduce(0) { $0 + search($1) }
        }
        return mainWindow.window.contentView.map(search) ?? 0
    }

    private var quickAccessScrollAreas: Int {
        func count(_ view: NSView) -> Int {
            (view is NSScrollView ? 1 : 0) + view.subviews.reduce(0) { $0 + count($1) }
        }
        return quickAccess.window.contentView.map(count) ?? 0
    }
}
#endif
