import AppKit
import DesignKit
import Engine
import SwiftUI
import UniformTypeIdentifiers

/// One choice changes the draft only. Saving the item remains a separate action.
struct RunningAppsPicker: View {
    let model: AppModel
    let navigation: VaultNavigation
    @Bindable var form: ItemForm
    @State private var apps: [RunningApp] = []
    @State private var search = ""
    @State private var selectedID: UUID?
    @State private var isLoading = true
    @State private var failed = false
    @State private var reload = 0

    private var filtered: [RunningApp] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return apps.filter { query.isEmpty || $0.name.localizedStandardContains(query) || $0.address.bundleID.localizedStandardContains(query) }
    }

    private func assigned(_ app: RunningApp) -> Bool {
        guard case .login(let login) = form.draft.content else { return false }
        return login.websites.contains { $0.app == app.address }
    }

    private var selection: RunningApp? { filtered.first { $0.id == selectedID } }

    var body: some View {
        BWDialog(title: BWText["honkpassChooseApp"], onClose: close) {
            VStack(alignment: .leading, spacing: Metric.space(3)) {
                BWSearchField(text: $search, placeholder: BWText["honkpassSearchApps"], takesFocus: true)
                    .disabled(form.isReadingApp)
                if isLoading {
                    ProgressView(BWText["honkpassLoadingApps"])
                        .frame(maxWidth: .infinity, minHeight: Metric.space(16))
                } else if failed {
                    Text(BWText["honkpassAppListError"]).textStyle(.body)
                } else if filtered.isEmpty {
                    Text(BWText[search.isEmpty ? "honkpassNoRunningApps" : "honkpassNoMatchingApps"])
                        .textStyle(.body)
                        .foregroundStyle(.theme(.textMuted))
                        .frame(maxWidth: .infinity, minHeight: Metric.space(16))
                } else {
                    List(selection: $selectedID) {
                        ForEach(filtered) { app in
                            HStack(spacing: Metric.space(3)) {
                                RunningAppIcon(location: app.location)
                                VStack(alignment: .leading, spacing: Metric.space(1)) {
                                    Text(app.name).textStyle(.body).lineLimit(1)
                                    Text(app.address.bundleID).textStyle(.xs).foregroundStyle(.theme(.textMuted)).lineLimit(1)
                                }
                                Spacer(minLength: Metric.space(2))
                                if assigned(app) { Text(BWText["honkpassAppAlreadyAssigned"]).textStyle(.xs) }
                            }
                            .padding(.vertical, Metric.space(1))
                            .tag(app.id)
                            .help(app.address.address + "\n" + app.location.path)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .frame(height: Metric.space(8) + CGFloat(min(filtered.count, 5)) * Metric.space(16))
                    .disabled(form.isReadingApp)
                }
                Text(BWText["honkpassRunningAppsHint"])
                    .textStyle(.sm)
                    .foregroundStyle(.theme(.textMuted))
                HStack {
                    BWLink(BWText["honkpassChooseAppFromDisk"], action: browse)
                    Spacer()
                    BWLink(BWText["honkpassRefreshApps"]) { reload += 1 }
                        .disabled(form.isReadingApp)
                }
                if form.isReadingApp { ProgressView().controlSize(.small) }
            }
        } footer: {
            BWButton(BWText["honkpassAssignApp"], kind: .primary, isBlock: false, action: assign)
                .disabled(selection == nil || selection.map(assigned) == true || form.isReadingApp)
                .keyboardShortcut(.defaultAction)
            BWButton(BWText["cancel"], isBlock: false, action: close)
        }
        .task(id: reload) {
            isLoading = true
            failed = false
            do {
                let loaded = try await model.runningApps()
                guard !Task.isCancelled, navigation.itemForm === form, form.isAppPickerOpen else { return }
                apps = loaded
                selectedID = filtered.first(where: { !assigned($0) })?.id
            } catch {
                guard !Task.isCancelled, navigation.itemForm === form, form.isAppPickerOpen else { return }
                failed = true
            }
            isLoading = false
        }
        .onChange(of: search) { selectedID = filtered.first(where: { !assigned($0) })?.id }
        .onSubmit(assign)
        .onExitCommand(perform: close)
    }

    private func assign() {
        guard let selection, !assigned(selection), !form.isReadingApp else { return }
        ItemActions(model: model, navigation: navigation).addApp(runningID: selection.id, to: form)
    }

    private func close() { form.isAppPickerOpen = false }

    private func browse() {
        guard !form.isReadingApp else { return }
        close()
        Task { @MainActor in
            await Task.yield()
            guard navigation.itemForm === form else { return }
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.applicationBundle]
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
            if panel.runModal() == .OK, let chosen = panel.url {
                ItemActions(model: model, navigation: navigation).addApp(at: chosen, to: form)
            }
        }
    }
}

private struct RunningAppIcon: View {
    let location: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().interpolation(.high) }
            else { IconView(.desktop, size: TextStyle.body.size) }
        }
        .frame(width: Metric.space(7), height: Metric.space(7))
        .accessibilityHidden(true)
        .task(id: location) {
            let loaded = await RunningAppIcons.load(location)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

private enum RunningAppIcons {
    @concurrent static func load(_ location: URL) async -> NSImage? {
        guard FileManager.default.fileExists(atPath: location.path) else { return nil }
        return NSWorkspace.shared.icon(forFile: location.path)
    }
}
