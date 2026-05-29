import SwiftUI

/// Sheet for creating or editing a service group.
struct GroupEditorView: View {
    @EnvironmentObject private var store: ServicesStore
    @Environment(\.dismiss) private var dismiss

    let editing: ServiceGroup?

    @State private var name: String = ""
    @State private var mode: ServiceGroupMode = .simultaneous
    @State private var stopOnFailure: Bool = true
    @State private var memberIDs: [String] = []

    init(editing: ServiceGroup? = nil) {
        self.editing = editing
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    settingsSection
                    Divider()
                    membersSection
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 460, height: 560)
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack {
            Text(editing == nil ? "New Group" : "Edit Group")
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

    // MARK: - Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.caption.weight(.medium))
                TextField("Backend stack", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            Picker("Mode", selection: $mode) {
                ForEach([ServiceGroupMode.simultaneous, .sequenced], id: \.self) { m in
                    Label(m.displayLabel, systemImage: m.iconSystemName).tag(m)
                }
            }
            .pickerStyle(.segmented)

            Text(mode == .simultaneous
                 ? "All services start at the same time."
                 : "Services start one after another, in the order below.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if mode == .sequenced {
                Toggle("Stop the sequence if a service fails to start", isOn: $stopOnFailure)
                    .font(.callout)
            }
        }
    }

    // MARK: - Members

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Services")
                .font(.subheadline.weight(.semibold))

            if memberIDs.isEmpty {
                Text("No services added yet. Pick from the list below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Ordered members (reorderable for sequenced groups).
                VStack(spacing: 4) {
                    ForEach(Array(memberIDs.enumerated()), id: \.element) { index, id in
                        memberRow(id: id, index: index)
                    }
                }
            }

            Divider().padding(.vertical, 4)

            Text("Available")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(availableServices, id: \.id) { service in
                Button {
                    memberIDs.append(service.id)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle")
                        Image(systemName: service.iconSystemName).frame(width: 18)
                        Text(service.name).font(.system(size: 12))
                        Spacer()
                        Text(service.kind.sourceLabel)
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
            }
        }
    }

    private func memberRow(id: String, index: Int) -> some View {
        let service = store.service(withID: id)
        return HStack(spacing: 8) {
            if mode == .sequenced {
                Text("\(index + 1).")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .trailing)
            }
            Image(systemName: service?.iconSystemName ?? "questionmark.circle")
                .frame(width: 18)
            Text(service?.name ?? id)
                .font(.system(size: 12, weight: .medium))
            Spacer()
            if mode == .sequenced {
                Button {
                    move(from: index, by: -1)
                } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(index == 0)
                Button {
                    move(from: index, by: 1)
                } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(index == memberIDs.count - 1)
            }
            Button(role: .destructive) {
                memberIDs.removeAll { $0 == id }
            } label: { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
    }

    private func move(from index: Int, by offset: Int) {
        let target = index + offset
        guard target >= 0, target < memberIDs.count else { return }
        memberIDs.swapAt(index, target)
    }

    /// Services not already in the group, eligible to be members.
    private var availableServices: [MbappeService] {
        store.allDiscovered.filter { service in
            !memberIDs.contains(service.id) && service.isControllable
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Actions

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !memberIDs.isEmpty
    }

    private func load() {
        guard let editing else { return }
        name = editing.name
        mode = editing.mode
        stopOnFailure = editing.stopOnFailure
        memberIDs = editing.memberServiceIDs
    }

    private func save() {
        let group = ServiceGroup(
            id: editing?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            mode: mode,
            memberServiceIDs: memberIDs,
            stopOnFailure: stopOnFailure,
            iconSystemName: editing?.iconSystemName ?? "rectangle.3.group"
        )
        if editing == nil {
            store.addGroup(group)
        } else {
            store.updateGroup(group)
        }
        dismiss()
    }
}

#if DEBUG
#Preview {
    GroupEditorView()
        .environmentObject(ServicesStore())
}
#endif
