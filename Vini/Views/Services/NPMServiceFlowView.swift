import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// NPM helper flow: pick a package.json, parse its scripts, multi-select which to
/// turn into services, and create them all at once.
struct NPMServiceFlowView: View {
    @EnvironmentObject private var store: ServicesStore
    @Environment(\.dismiss) private var dismiss

    let onBack: () -> Void

    @State private var parsed: ParsedPackageJSON?
    @State private var selected: Set<String> = []
    @State private var keepAliveOnQuit = false
    @State private var errorMessage: String?
    @State private var isChoosingPackage = false
    @State private var hostingWindow: NSWindow?
    @State private var packageOpenPanel: NSOpenPanel?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .background(WindowAccessor { hostingWindow = $0 })
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            Text("NPM Scripts")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            if parsed != nil {
                Text("\(selected.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Add \(selected.count) Service\(selected.count == 1 ? "" : "s")") {
                createServices()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selected.isEmpty)
        }
        .padding(16)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let parsed {
            scriptList(parsed)
        } else {
            picker
        }
    }

    private var picker: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Choose a package.json")
                .font(.headline)
            Text("Vini will read its scripts and let you pick which ones to run as services.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button(isChoosingPackage ? "Choosing..." : "Choose package.json…") { choosePackageJSON() }
                .controlSize(.large)
                .disabled(isChoosingPackage)
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func scriptList(_ parsed: ParsedPackageJSON) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(parsed.packageName)
                        .font(.subheadline.weight(.semibold))
                    Text("\(parsed.packageManager.displayName) · \(parsed.directory)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Change") { self.parsed = nil; selected = [] }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(parsed.scripts) { script in
                        scriptRow(script, manager: parsed.packageManager)
                        Divider().padding(.leading, 44)
                    }
                }
            }
            .frame(maxHeight: 300)

            Divider()
            Toggle("Keep running when Vini quits", isOn: $keepAliveOnQuit)
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }

    private func scriptRow(_ script: NodeScript, manager: NodePackageManager) -> some View {
        Button {
            toggle(script.name)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected.contains(script.name) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected.contains(script.name) ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(script.name)
                        .font(.system(size: 13, weight: .medium))
                    Text(script.command)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func toggle(_ name: String) {
        if selected.contains(name) { selected.remove(name) } else { selected.insert(name) }
    }

    private func choosePackageJSON() {
        guard !isChoosingPackage else { return }
        isChoosingPackage = true
        errorMessage = nil

        let panel = NSOpenPanel()
        panel.title = "Choose package.json"
        panel.prompt = "Choose"
        panel.message = "Select the package.json whose scripts you want to import."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "package.json"
        packageOpenPanel = panel

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            let selectedURL = response == .OK ? panel.url : nil
            packageOpenPanel = nil
            guard let selectedURL else {
                isChoosingPackage = false
                return
            }
            parsePackageJSON(selectedURL)
        }

        NSApp.activate(ignoringOtherApps: true)
        if let hostingWindow {
            panel.beginSheetModal(for: hostingWindow, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func parsePackageJSON(_ url: URL) {
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { () throws -> ParsedPackageJSON in
                    let didAccess = url.startAccessingSecurityScopedResource()
                    defer {
                        if didAccess { url.stopAccessingSecurityScopedResource() }
                    }
                    return try PackageJSONParser.parse(fileURL: url)
                }.value
                parsed = result
                // Preselect common dev scripts if present.
                selected = Set(result.scripts.map(\.name).filter { ["dev", "start", "serve"].contains($0) })
            } catch {
                errorMessage = error.localizedDescription
            }
            isChoosingPackage = false
        }
    }

    private func createServices() {
        guard let parsed else { return }
        let definitions = parsed.scripts
            .filter { selected.contains($0.name) }
            .map { script in
                UserServiceDefinition(
                    name: "\(parsed.packageName): \(script.name)",
                    startCommand: parsed.packageManager.runCommand(forScript: script.name),
                    stopCommand: nil,
                    workingDirectory: parsed.directory,
                    probePort: nil,
                    keepAliveOnQuit: keepAliveOnQuit,
                    iconSystemName: "shippingbox"
                )
            }
        store.addUserDefinitions(definitions, groupedUnder: parsed.packageName)
        dismiss()
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}

#if DEBUG
#Preview {
    NPMServiceFlowView(onBack: {})
        .frame(width: 460, height: 560)
        .environmentObject(ServicesStore())
}
#endif
