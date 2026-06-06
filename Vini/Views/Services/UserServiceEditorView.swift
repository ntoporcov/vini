import SwiftUI
import AppKit

/// Sheet for creating or editing a user-defined service.
///
/// Creating starts on a helper grid (NPM, Custom). Editing goes straight to the
/// custom form.
struct UserServiceEditorView: View {
    @EnvironmentObject private var store: ServicesStore
    @Environment(\.dismiss) private var dismiss

    /// Existing definition when editing; nil when creating.
    let editing: UserServiceDefinition?

    @State private var step: Step

    private enum Step {
        case picker
        case custom
        case npm
    }

    init(editing: UserServiceDefinition? = nil) {
        self.editing = editing
        // Editing always uses the free-form custom step.
        _step = State(initialValue: editing == nil ? .picker : .custom)
    }

    var body: some View {
        switch step {
        case .picker:
            HelperPickerView(
                onSelectCustom: { step = .custom },
                onSelectNPM: { step = .npm },
                onCancel: { dismiss() }
            )
            .frame(width: 460, height: 360)
        case .custom:
            CustomServiceFormView(
                editing: editing,
                showBack: editing == nil,
                onBack: { step = .picker }
            )
            .frame(width: 460, height: 560)
        case .npm:
            NPMServiceFlowView(onBack: { step = .picker })
                .frame(width: 460, height: 560)
        }
    }
}

// MARK: - Helper picker grid

private struct HelperPickerView: View {
    let onSelectCustom: () -> Void
    let onSelectNPM: () -> Void
    let onCancel: () -> Void

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add a Service")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()

            Text("Choose how you'd like to set up your service.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            LazyVGrid(columns: columns, spacing: 12) {
                HelperCard(
                    title: "NPM",
                    subtitle: "Pick a package.json and turn its scripts into services.",
                    systemImage: "shippingbox",
                    action: onSelectNPM
                )
                HelperCard(
                    title: "Custom",
                    subtitle: "Define your own start and stop commands.",
                    systemImage: "terminal",
                    action: onSelectCustom
                )
            }
            .padding(16)

            Spacer()
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
    }
}

private struct HelperCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 24))
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.4)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Custom service form

/// The free-form service editor (also used when editing any service).
private struct CustomServiceFormView: View {
    @EnvironmentObject private var store: ServicesStore
    @Environment(\.dismiss) private var dismiss

    let editing: UserServiceDefinition?
    let showBack: Bool
    let onBack: () -> Void

    @State private var name: String = ""
    @State private var startCommand: String = ""
    @State private var stopCommand: String = ""
    @State private var workingDirectory: String = ""
    @State private var probePortText: String = ""
    @State private var keepAliveOnQuit: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    formSection
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .onAppear(perform: load)
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack(spacing: 8) {
            if showBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
            }
            Text(editing == nil ? "Custom Service" : "Edit Service")
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
                    Text("Keep running when Vini quits")
                    Text("Vini re-adopts the process on next launch if it's still alive.")
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
        guard let editing else { return }
        name = editing.name
        startCommand = editing.startCommand
        stopCommand = editing.stopCommand ?? ""
        workingDirectory = editing.workingDirectory ?? ""
        probePortText = editing.probePort.map(String.init) ?? ""
        keepAliveOnQuit = editing.keepAliveOnQuit
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            workingDirectory = url.path
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
