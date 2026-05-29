import SwiftUI
import AppKit

/// Sheet for creating or editing a user-defined service, with project auto-discovery.
struct UserServiceEditorView: View {
    @EnvironmentObject private var store: ServicesStore
    @Environment(\.dismiss) private var dismiss

    /// Existing definition when editing; nil when creating.
    let editing: UserServiceDefinition?

    @State private var name: String = ""
    @State private var startCommand: String = ""
    @State private var stopCommand: String = ""
    @State private var workingDirectory: String = ""
    @State private var probePortText: String = ""
    @State private var keepAliveOnQuit: Bool = false

    @State private var suggestions: [ProjectSuggestion] = []
    @State private var isScanning = false

    init(editing: UserServiceDefinition? = nil) {
        self.editing = editing
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if editing == nil {
                        discoverySection
                        Divider()
                    }
                    formSection
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 460, height: 560)
        .onAppear(perform: load)
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack {
            Text(editing == nil ? "New Service" : "Edit Service")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(editing == nil ? "Add" : "Save") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
        }
        .padding(16)
    }

    // MARK: - Discovery

    private var discoverySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Suggested projects", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if isScanning {
                    ProgressView().controlSize(.small)
                }
            }

            if suggestions.isEmpty && !isScanning {
                Text("No projects found in ~/Developer, ~/Projects, ~/Code, ~/src, or ~/repos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(suggestions) { suggestion in
                        suggestionRow(suggestion)
                    }
                }
            }
        }
    }

    private func suggestionRow(_ suggestion: ProjectSuggestion) -> some View {
        Button {
            apply(suggestion)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: suggestion.projectType.iconSystemName)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(suggestion.name)
                        .font(.system(size: 12, weight: .medium))
                    Text("\(suggestion.projectType.displayName) · \(suggestion.suggestedCommand)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "arrow.up.left.circle")
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func apply(_ suggestion: ProjectSuggestion) {
        if name.isEmpty { name = suggestion.name }
        startCommand = suggestion.suggestedCommand
        workingDirectory = suggestion.directory
    }

    // MARK: - Form

    private var formSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("Name", text: $name, placeholder: "My API")
            field("Start command", text: $startCommand, placeholder: "npm run dev", mono: true)
            field("Stop command (optional)", text: $stopCommand, placeholder: "Leave blank to terminate the process", mono: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Working directory")
                    .font(.caption.weight(.medium))
                HStack {
                    TextField("~/", text: $workingDirectory)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Button("Choose…") { chooseDirectory() }
                }
            }

            field("Probe port (optional)", text: $probePortText, placeholder: "3000")

            Toggle(isOn: $keepAliveOnQuit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep running when Mbappe quits")
                    Text("Mbappe re-adopts the process on next launch if it's still alive.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.medium))
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(mono ? .system(.body, design: .monospaced) : .body)
        }
    }

    // MARK: - Actions

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !startCommand.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func load() {
        if let editing {
            name = editing.name
            startCommand = editing.startCommand
            stopCommand = editing.stopCommand ?? ""
            workingDirectory = editing.workingDirectory ?? ""
            probePortText = editing.probePort.map(String.init) ?? ""
            keepAliveOnQuit = editing.keepAliveOnQuit
        } else {
            runScan()
        }
    }

    private func runScan() {
        isScanning = true
        Task {
            let found = await ProjectScanner.shared.scan()
            await MainActor.run {
                suggestions = found
                isScanning = false
            }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            workingDirectory = url.path
            // Offer a command suggestion if we recognize the picked folder.
            Task {
                if let detected = await ProjectScanner.shared.detect(directory: url) {
                    await MainActor.run {
                        if startCommand.isEmpty { startCommand = detected.suggestedCommand }
                        if name.isEmpty { name = detected.name }
                    }
                }
            }
        }
    }

    private func save() {
        let port = Int(probePortText.trimmingCharacters(in: .whitespaces))
        let trimmedStop = stopCommand.trimmingCharacters(in: .whitespaces)
        let trimmedDir = workingDirectory.trimmingCharacters(in: .whitespaces)

        let definition = UserServiceDefinition(
            id: editing?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            startCommand: startCommand.trimmingCharacters(in: .whitespaces),
            stopCommand: trimmedStop.isEmpty ? nil : trimmedStop,
            workingDirectory: trimmedDir.isEmpty ? nil : trimmedDir,
            probePort: port,
            keepAliveOnQuit: keepAliveOnQuit,
            iconSystemName: editing?.iconSystemName ?? "terminal"
        )

        if editing != nil {
            store.removeUserDefinition(id: definition.id)
        }
        store.addUserDefinition(definition)
        dismiss()
    }
}

#if DEBUG
#Preview {
    UserServiceEditorView()
        .environmentObject(ServicesStore())
}
#endif
