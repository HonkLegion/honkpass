#if DEBUG
import AppKit
import Engine

/// `--fake-backend --fill-check`: fills the second login of the fake account into the login
/// form of the fixture app (support/fill-fixture) through the real Accessibility port, and
/// exits with 0 or 1. It checks what the tests cannot: that the two fields of a form are found
/// in what another app tells the Accessibility of the system, and that both take their value.
/// It writes into the fixture only: any other app in front is left alone.
@MainActor
struct FillCheck {
    static let fixtureName = "PassVaultFillFixture"
    let model: AppModel

    func run() {
        Task {
            guard let account = model.prefill else {
                print("FILL CHECK FAILED: it needs --fake-backend")
                exit(1)
            }
            try? await model.logIn(server: account.server, email: account.email, masterPassword: account.masterPassword)
            for _ in 0..<100 where !model.state.session.isUnlocked {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard await model.isFillAllowed() else {
                print("FILL CHECK FAILED: the system does not allow PassVault to use other apps")
                exit(1)
            }
            if CommandLine.arguments.contains("--fill-check-long") {
                do {
                    var draft = try await model.draft(of: "item-2")
                    guard case .login(var login) = draft.content else { exit(1) }
                    login.password = "synthetic-" + String(repeating: "a", count: 67) + "é👨‍👩‍👧‍👦e\u{301}!"
                    draft.content = .login(login)
                    _ = try await model.save(draft)
                } catch { exit(1) }
            }
            // The fixture has to be in front, with the cursor in its form.
            NSApp.hide(nil)
            print("FILL CHECK WAITS for the fixture")
            fflush(stdout)
            var lastTarget = "none"
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(500))
                // No look at any other app: while the fixture is not in front, nothing is asked.
                guard NSWorkspace.shared.frontmostApplication?.localizedName == Self.fixtureName,
                      let target = await model.fillTarget(), target.appName == Self.fixtureName else { continue }
                lastTarget = "value=\(target.takesValue) secure=\(target.isSecure) code=\(target.isVerificationCode) form=\(target.takesLogin)"
                if CommandLine.arguments.contains("--fill-check-ambiguous-code") {
                    guard target.isUnclassifiedCode, target.suggestedLoginField == nil, !target.takesLogin else { continue }
                    print("FILL CHECK DONE: an ambiguous code requires an explicit field choice")
                    exit(0)
                }
                let codeOnly = CommandLine.arguments.contains("--fill-check-code-only")
                guard codeOnly ? target.isVerificationCode : target.takesLogin else { continue }
                if CommandLine.arguments.contains("--fill-check-password"), !target.isSecure { continue }
                if CommandLine.arguments.contains("--fill-check-nowhere"), target.takesValue { continue }
                if !codeOnly && !CommandLine.arguments.contains("--fill-check-password")
                    && !CommandLine.arguments.contains("--fill-check-nowhere")
                    && (!target.takesValue || target.isSecure) { continue }
                do {
                    if codeOnly {
                        try await model.fill(.verificationCode, of: "item-1", into: target)
                    } else {
                        let itemID = CommandLine.arguments.contains("--fill-check-code") ? "item-1" : "item-2"
                        try await model.fillLogin(of: itemID, into: target)
                    }
                    guard !CommandLine.arguments.contains("--fill-check-interrupted") else {
                        print("FILL CHECK FAILED: a focus change did not interrupt the fill")
                        exit(1)
                    }
                    print("FILL CHECK DONE: the cursor was in \(target.takesValue ? (target.isSecure ? "the password" : "the user name") : "no field")")
                    exit(0)
                } catch {
                    if CommandLine.arguments.contains("--fill-check-interrupted"),
                       error as? EngineError == .fill(.targetChanged) {
                        print("FILL CHECK DONE: a focus change interrupted the fill")
                        exit(0)
                    }
                    print("FILL CHECK FAILED: \(error)")
                    exit(1)
                }
            }
            print("FILL CHECK FAILED: the expected fixture target was unavailable (\(lastTarget))")
            exit(1)
        }
    }

}
#endif
