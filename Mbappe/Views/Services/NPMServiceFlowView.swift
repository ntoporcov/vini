import SwiftUI
import AppKit

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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
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
            Text("Mbappe will read its scripts and let you pick which ones to run as services.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Choose package.json…") { choosePackageJSON() }
                .controlSize(.large)
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
            Toggle("Keep running when Mbappe quits", isOn: $keepAliveOnQuit)
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
        errorMessage = nil
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = "Select a package.json file"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let result = try PackageJSONParser.parse(fileURL: url)
            parsed = result
            // Preselect common dev scripts if present.
            selected = Set(result.scripts.map(\.name).filter { ["dev", "start", "serve"].contains($0) })
        } catch {
            errorMessage = error.localizedDescription
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
        store.addUserDefinitions(definitions)
        dismiss()
    }
}

#if DEBUG
#Preview {
    NPMServiceFlowView(onBack: {})
        .frame(width: 460, height: 560)
        .environmentObject(ServicesStore())
}
#endif
