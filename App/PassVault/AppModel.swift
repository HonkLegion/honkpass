import Engine
import EngineFakes
import Foundation
import Observation
import VaultModel

/// What the in-process clients share: the latest engine state and the engine's commands.
/// It adds no logic and keeps nothing that the engine does not publish.
@MainActor @Observable
final class AppModel {
    private(set) var state = EngineState.initial
    /// Fills the log-in form when the app runs on the fake backend.
    let prefill: FakeAccount?
    /// Called when the vault stops being unlocked, with or without a window.
    @ObservationIgnored var onVaultClosed: (@MainActor () -> Void)?
    @ObservationIgnored var onVaultOpened: (@MainActor () -> Void)?
    /// The independent SSH window follows the engine, including cancellation and lock.
    @ObservationIgnored var onSSHStateChanged: (@MainActor () -> Void)?

    @ObservationIgnored private let engine: Engine
    @ObservationIgnored private var observation: Task<Void, Never>?

    init(engine: Engine, prefill: FakeAccount?) {
        self.engine = engine
        self.prefill = prefill
    }

    func start() {
        guard observation == nil else { return }
        observation = Task { [weak self, engine] in
            await engine.start()
            for await state in await engine.states() {
                guard let self else { return }
                let wasUnlocked = self.state.session.isUnlocked
                self.state = state
                if !wasUnlocked, state.session.isUnlocked { self.onVaultOpened?() }
                if wasUnlocked, !state.session.isUnlocked { self.onVaultClosed?() }
                self.onSSHStateChanged?()
            }
        }
    }

    func logIn(server: URL, email: String, masterPassword: String) async throws {
        try await engine.logIn(server: server, email: email, masterPassword: masterPassword)
    }

    func accountAvatar() async -> Data? {
        await engine.accountAvatar()
    }

    func submitTwoStepCode(_ code: String, method: TwoStepMethod, rememberDevice: Bool) async throws {
        try await engine.submitTwoStepCode(code, method: method, rememberDevice: rememberDevice)
    }

    func sendTwoStepEmail() async throws {
        try await engine.sendTwoStepEmail()
    }

    func cancelTwoStepLogin() async {
        await engine.cancelTwoStepLogin()
    }

    func addAccount() async throws {
        try await engine.addAccount()
    }

    func switchAccount(to id: String) async throws {
        try await engine.switchAccount(to: id)
    }

    func unlock(masterPassword: String) async throws {
        try await engine.unlock(masterPassword: masterPassword)
    }

    func unlock(pin: String) async throws {
        try await engine.unlock(pin: pin)
    }

    func cancelSSHRequest(id: UUID) async {
        await engine.cancelSSHRequest(id: id)
    }

    /// The lock screen has asked for Touch ID by itself since the app started: "ask for Touch
    /// ID on app start" asks once.
    var hasAskedForTouchIDAtStart = false

    /// Looks again whether the Mac can ask for Touch ID now: a sensor comes and goes.
    func refreshBiometrics() async {
        await engine.refreshBiometrics()
    }

    func setBiometricUnlock(_ isOn: Bool) async throws {
        try await engine.setBiometricUnlock(isOn)
    }

    /// The system asks for Touch ID. Its question says "PassVault is trying to" and the reason.
    func unlockWithBiometrics(reason: String) async throws {
        try await engine.unlockWithBiometrics(reason: reason)
    }

    func setPin(_ pin: String, asksForMasterPasswordAfterRestart: Bool) async throws {
        try await engine.setPin(pin, asksForMasterPasswordAfterRestart: asksForMasterPasswordAfterRestart)
    }

    func removePin() async throws {
        try await engine.removePin()
    }

    func sync() async throws {
        try await engine.sync()
    }

    func lock() async {
        await engine.lock()
    }

    func item(id: String) async throws -> VaultItem {
        try await engine.item(id: id)
    }

    func verificationCode(for id: String) async throws -> VerificationCode {
        try await engine.verificationCode(for: id)
    }

    func copy(_ field: ItemField, of id: String) async throws {
        try await engine.copy(field, of: id)
    }

    func isFillAllowed() async -> Bool {
        await engine.isFillAllowed()
    }

    func askForFillPermission() async {
        await engine.askForFillPermission()
    }

    func fillTarget() async -> FillTarget? {
        await engine.fillTarget()
    }

    func fill(_ field: ItemField, of id: String, into target: FillTarget) async throws {
        try await engine.fill(field, of: id, into: target)
    }

    func fillLogin(of id: String, into target: FillTarget) async throws {
        try await engine.fillLogin(of: id, into: target)
    }

    func addWebsite(_ address: String, toLogin id: String, session: VaultSessionToken? = nil) async throws {
        try await engine.addWebsite(address, toLogin: id, session: session)
    }

    func appAddress(ofAppAt location: URL) async throws -> AppAddress {
        try await engine.appAddress(ofAppAt: location)
    }

    func runningApps() async throws -> [RunningApp] { try await engine.runningApps() }

    func appAddress(ofRunningApp id: UUID) async throws -> AppAddress { try await engine.appAddress(ofRunningApp: id) }

    func fillAndSaveApp(_ field: ItemField?, of id: String, into target: FillTarget) async throws -> Bool {
        try await engine.fillAndSaveApp(field, of: id, into: target)
    }

    func answerSSHApproval(id: UUID, isAllowed: Bool) async {
        await engine.answerSSHApproval(id: id, isAllowed: isAllowed)
    }

    func send(id: String) async throws -> VaultSend {
        try await engine.send(id: id)
    }

    func copySendLink(of id: String) async throws {
        try await engine.copySendLink(of: id)
    }

    @discardableResult
    func saveSend(_ draft: SendDraft, session: VaultSessionToken? = nil) async throws -> String {
        try await engine.saveSend(draft, session: session)
    }

    func deleteSend(id: String) async throws {
        try await engine.deleteSend(id: id)
    }

    func removeSendPassword(of id: String) async throws {
        try await engine.removeSendPassword(of: id)
    }

    func vaultSession() async throws -> VaultSessionToken { try await engine.vaultSession() }

    func checkVaultSession(_ session: VaultSessionToken) async throws { try await engine.checkVaultSession(session) }

    func exportVault(format: VaultExportFormat, masterPassword: String, session: VaultSessionToken? = nil) async throws -> Data {
        try await engine.exportVault(format: format, masterPassword: masterPassword, session: session)
    }

    func importVault(_ file: VaultImport, session: VaultSessionToken? = nil) async throws {
        try await engine.importVault(file, session: session)
    }

    func fingerprintPhrase() async throws -> [String] {
        try await engine.fingerprintPhrase()
    }

    func requestPasswordHint(server: URL, email: String) async throws {
        try await engine.requestPasswordHint(server: server, email: email)
    }

    func isKnownDevice(server: URL, email: String) async -> Bool {
        await engine.isKnownDevice(server: server, email: email)
    }

    func change(_ change: ItemChange, of id: String) async throws {
        try await engine.change(change, of: id)
    }

    func change(_ change: ItemChange, ofItems ids: [String]) async throws {
        try await engine.change(change, ofItems: ids)
    }

    func draft(of id: String) async throws -> ItemDraft {
        try await engine.draft(of: id)
    }

    @discardableResult
    func save(_ draft: ItemDraft) async throws -> String {
        try await engine.save(draft)
    }

    @discardableResult
    func assign(itemID: String, toOrganization organizationID: String, collectionIDs: [String]) async throws {
        try await engine.assign(itemID: itemID, toOrganization: organizationID, collectionIDs: collectionIDs)
    }

    func saveFolder(id: String?, name: String) async throws -> String {
        try await engine.saveFolder(id: id, name: name)
    }

    func deleteFolder(id: String) async throws {
        try await engine.deleteFolder(id: id)
    }

    func generate(_ request: GeneratorRequest) async throws -> String {
        try await engine.generate(request)
    }

    func generatorHistory() async throws -> [GeneratedValue] {
        try await engine.generatorHistory()
    }

    func clearGeneratorHistory() async throws {
        try await engine.clearGeneratorHistory()
    }

    func newSSHKey() async throws -> SSHKeyContent {
        try await engine.newSSHKey()
    }

    func importSSHKeyFromClipboard(password: String?) async throws -> SSHKeyContent {
        try await engine.importSSHKeyFromClipboard(password: password)
    }

    func passwordHistory(of id: String) async throws -> [PasswordHistoryEntry] {
        try await engine.passwordHistory(of: id)
    }

    func attachment(_ attachmentID: String, of itemID: String) async throws -> AttachmentFile {
        try await engine.attachment(attachmentID, of: itemID)
    }

    func addAttachment(to itemID: String, fileName: String, data: Data, session: VaultSessionToken? = nil) async throws {
        try await engine.addAttachment(to: itemID, fileName: fileName, data: data, session: session)
    }

    func repairAttachment(_ attachmentID: String, of itemID: String) async throws {
        try await engine.repairAttachment(attachmentID, of: itemID)
    }

    func deleteAttachment(_ attachmentID: String, of itemID: String) async throws {
        try await engine.deleteAttachment(attachmentID, of: itemID)
    }

    func timesLeaked(password: String) async throws -> Int {
        try await engine.timesLeaked(password: password)
    }

    func copy(text: String, isSensitive: Bool) async throws {
        try await engine.copy(text: text, isSensitive: isSensitive)
    }

    func setSettings(_ settings: EngineSettings) async throws {
        try await engine.setSettings(settings)
    }

    func websiteIcon(host: String) async -> Data? {
        await engine.websiteIcon(host: host)
    }

    func isMasterPassword(_ password: String) async -> Bool {
        await engine.isMasterPassword(password)
    }

    func logOut() async {
        try? await engine.logOut()
    }

    func dismiss(_ notice: EngineNotice) async {
        await engine.dismiss(notice)
    }

    func noteUserActivity() async {
        await engine.noteUserActivity()
    }
}
