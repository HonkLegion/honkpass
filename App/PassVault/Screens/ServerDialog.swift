import DesignKit
import EngineLive
import SwiftUI

/// The dialog "Self-hosted environment". Reference: docs/reference/log-in-server-*.png.
/// Source: libs/angular/src/auth/self-hosted-env-config-dialog.
///
/// PassVault takes one server URL. The separate URLs of "custom environment" are a feature it
/// does not have, so that link is disabled (PLAN.md, allowed deviations).
struct ServerDialog: View {
    @Bindable var flow: LogInFlow
    @State private var baseURL = ""
    @State private var fieldProblem: String?
    @State private var showsSummary = false
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        // The title is English in every language of the reference: it has no text key.
        BWDialog(title: "Self-hosted environment", onClose: close) {
            VStack(alignment: .leading, spacing: 0) {
                BWFormField(BWText["baseUrl"], isFocused: isFieldFocused, error: fieldProblem,
                            hint: BWText["selfHostedBaseUrlHint"]) {
                    BWTextInput(text: $baseURL)
                        .focused($isFieldFocused)
                        .onSubmit(save)
                }
                // The link is an inline button on the 20 pixel line of its block
                // (measured in docs/reference/log-in-server-*.png).
                BWLink(BWText["customEnvironment"], leadingIcon: .angleRight) {}
                    .disabled(true)
                    .frame(height: 20)
                if showsSummary {
                    // span "tw-block tw-text-danger tw-mt-2" with bwi-error
                    HStack(alignment: .firstTextBaseline, spacing: Metric.space(1)) {
                        IconView(.error, size: TextStyle.body.size)
                        Text(BWText["selfHostedEnvFormInvalid"]).textStyle(.body)
                    }
                    .foregroundStyle(.theme(.fgDanger))
                    .padding(.top, Metric.space(2))
                }
            }
        } footer: {
            BWButton(BWText["save"], kind: .primary, isBlock: false, action: save)
            BWButton(BWText["cancel"], isBlock: false, action: close)
        }
        .onAppear {
            baseURL = flow.serverURL?.absoluteString ?? ""
            isFieldFocused = true
        }
        .onExitCommand(perform: close)
    }

    private func save() {
        let text = baseURL.trimmingCharacters(in: .whitespaces)
        fieldProblem = nil
        showsSummary = false
        guard !text.isEmpty else {
            showsSummary = true
            return
        }
        guard let url = URL(string: text), VaultwardenServer.accepts(url) else {
            fieldProblem = BWText["selfHostedEnvMustUseHttps"]
            return
        }
        flow.serverURL = url
        flow.isServerDialogOpen = false
    }

    private func close() {
        flow.isServerDialogOpen = false
    }
}
