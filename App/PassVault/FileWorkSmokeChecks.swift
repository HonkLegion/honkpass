#if DEBUG
import Foundation
import VaultModel

@MainActor enum FileWorkSmokeChecks {
    static func run(model: AppModel, check: (Bool, String) -> Void) async {
        let directory = FileManager.default.temporaryDirectory.appending(path: "honkpass-file-smoke-\(UUID())")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = directory.appending(path: "synthetic.csv")
            let csv = Data("folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n,,login,Synthetic file,,,,https://example.test,demo,synthetic,\n".utf8)
            try await VaultFileIO.write(csv, to: source)
            let expected = try VaultImportFormat.bitwardenCSV.read(csv).placed(in: VaultFolder(id: "folder", name: "Synthetic folder"))
            let prepared = try await VaultFileIO.importFile(source, pasted: "ignored", format: .bitwardenCSV,
                                                          folder: VaultFolder(id: "folder", name: "Synthetic folder"))
            check(prepared.file == expected && prepared.summary.itemCount == 1,
                  "background import preserves parsed items, destination folder and summary")
            let pasted = try await VaultFileIO.importFile(nil, pasted: String(decoding: csv, as: UTF8.self),
                                                         format: .bitwardenCSV, folder: nil)
            check(pasted.file.items.count == 1, "pasted imports use the background parser")
            do {
                _ = try await VaultFileIO.importFile(directory.appending(path: "missing.csv"), pasted: String(decoding: csv, as: UTF8.self),
                                                     format: .bitwardenCSV, folder: nil)
                check(false, "an unreadable selected file does not silently import pasted data")
            } catch {
                check(true, "an unreadable selected file does not silently import pasted data")
            }
            do {
                _ = try await VaultFileIO.read(source, maximumBytes: 2)
                check(false, "background reads reject files above the byte limit")
            } catch VaultFileIO.Failure.tooLarge {
                check(true, "background reads reject files above the byte limit")
            }
            let destination = directory.appending(path: "synthetic-export.json")
            try await VaultFileIO.write(Data("first".utf8), to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
            let payload = Data(repeating: 0x53, count: 2 * 1_024 * 1_024 + 17)
            try await VaultFileIO.write(payload, to: destination)
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            let readBack = try await VaultFileIO.read(destination)
            check(readBack == payload && (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                  "background writes replace the complete file with owner-only permissions")
            let cancelled = Task { try await VaultFileIO.write(Data([0]), to: destination) }
            cancelled.cancel()
            do { try await cancelled.value; check(false, "cancelled writes leave the destination unchanged") }
            catch is CancellationError {
                let retained = try await VaultFileIO.read(destination)
                check(retained == payload, "cancelled writes leave the destination unchanged")
            }
            let remaining = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            check(!remaining.contains { $0.lastPathComponent.hasPrefix(".honkpass-") }, "file preparation removes its staging files")

            let navigation = VaultNavigation()
            let form = SendForm(new: .file)
            form.name = "Synthetic background file Send \(UUID())"
            form.file = source
            navigation.sendForm = form
            SendActions(model: model, navigation: navigation).save(form)
            check(form.isSaving, "file Send publishes its busy state before file preparation starts")
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while form.isSaving, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            let send = model.state.vault.sends.first { $0.name == form.name }
            check(send != nil && navigation.sendForm == nil, "a file Send reads in the background and saves through the existing engine")
            if let send { try await model.deleteSend(id: send.id) }
        } catch {
            check(false, "background file round-trip completes on synthetic data")
        }

        // An intentionally non-cooperative worker models a decoder or syscall already in flight.
        let navigation = VaultNavigation()
        navigation.isImporting = true
        let context = VaultFileContext(model: model, navigation: navigation)
        let gate = FileWorkGate()
        let delayed = Task {
            do {
                let session = try await context.session()
                _ = try await context.prepare { await gate.wait(); return Data([1]) }
                try await context.check(session)
                return false
            } catch { return true }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await gate.entered), ContinuousClock.now < deadline { await Task.yield() }
        let entered = await gate.entered
        navigation.isImporting = false
        navigation.isImporting = true
        await gate.release()
        let discarded = await delayed.value
        check(entered && discarded && navigation.isImporting && navigation.importResult == nil,
              "closing and reopening a form discards a late file result without affecting the new form")
        navigation.isImporting = false

        let send = SendForm(new: .file)
        send.name = "Synthetic file Send"
        send.file = URL(filePath: "/synthetic-file-that-does-not-exist")
        let snapshot = send.draft(now: Date())
        check(snapshot != nil && snapshot?.file == nil, "a file Send snapshots fields without reading its file on the main actor")
    }
}

private actor FileWorkGate {
    private(set) var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
#endif
