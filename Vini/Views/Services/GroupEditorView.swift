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
    @State private var iconSystemName: String = "rectangle.3.group"
    @State private var isPinnedToMenuBar: Bool = false
    @State private var isShowingIconPicker = false

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

            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.accentColor.opacity(0.14))
                        .frame(width: 34, height: 34)
                    Image(systemName: iconSystemName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Icon")
                        .font(.caption.weight(.medium))
                    Text(iconSystemName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Choose…") { isShowingIconPicker.toggle() }
                    .popover(isPresented: $isShowingIconPicker, arrowEdge: .trailing) {
                        SFSymbolPickerView(selection: $iconSystemName)
                    }
            }

            Toggle("Pin to Menu Bar", isOn: $isPinnedToMenuBar)
                .font(.callout)

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
            Text("Members")
                .font(.subheadline.weight(.semibold))

            if memberIDs.isEmpty {
                Text("No members added yet. Pick services or groups below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(memberIDs.enumerated()), id: \.element) { index, id in
                        memberRow(id: id, index: index)
                    }
                }
            }

            Divider().padding(.vertical, 4)

            if !availableServices.isEmpty {
                Text("Available services")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(availableServices, id: \.id) { service in
                    availableRow(
                        icon: service.iconSystemName,
                        name: service.name,
                        detail: service.kind.sourceLabel
                    ) { memberIDs.append(service.id) }
                }
            }

            if !availableGroups.isEmpty {
                Text("Available groups")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(availableGroups, id: \.id) { group in
                    availableRow(
                        icon: group.iconSystemName,
                        name: group.name,
                        detail: group.mode.displayLabel
                    ) { memberIDs.append(group.memberReferenceID) }
                }
            }
        }
    }

    private func availableRow(icon: String, name: String, detail: String, add: @escaping () -> Void) -> some View {
        Button(action: add) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                Image(systemName: icon).frame(width: 18)
                Text(name).font(.system(size: 12))
                Spacer()
                Text(detail)
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }

    private func memberRow(id: String, index: Int) -> some View {
        let isGroup = ServiceGroup.groupID(fromMemberID: id) != nil
        let memberName = displayName(forMemberID: id)
        let memberIcon = displayIcon(forMemberID: id)
        return HStack(spacing: 8) {
            if mode == .sequenced {
                Text("\(index + 1).")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .trailing)
            }
            Image(systemName: memberIcon)
                .frame(width: 18)
                .foregroundStyle(isGroup ? Color.accentColor : .primary)
            Text(memberName)
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
    private var availableServices: [ViniService] {
        store.allDiscovered.filter { service in
            !memberIDs.contains(service.id) && service.isControllable
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Other groups eligible to be nested here: not this group, not already a
    /// member, and not creating a cycle.
    private var availableGroups: [ServiceGroup] {
        store.groups.filter { candidate in
            guard candidate.id != editing?.id else { return false }
            guard !memberIDs.contains(candidate.memberReferenceID) else { return false }
            if let targetID = editing?.id,
               store.wouldCreateCycle(addingGroup: candidate.id, to: targetID) {
                return false
            }
            return true
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func displayName(forMemberID id: String) -> String {
        if let gid = ServiceGroup.groupID(fromMemberID: id) {
            return store.group(withID: gid)?.name ?? "Unknown group"
        }
        return store.service(withID: id)?.name ?? id
    }

    private func displayIcon(forMemberID id: String) -> String {
        if let gid = ServiceGroup.groupID(fromMemberID: id) {
            return store.group(withID: gid)?.mode.iconSystemName ?? "rectangle.3.group"
        }
        return store.service(withID: id)?.iconSystemName ?? "questionmark.circle"
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
        iconSystemName = editing.iconSystemName
        isPinnedToMenuBar = editing.isPinnedToMenuBar
    }

    private func save() {
        let group = ServiceGroup(
            id: editing?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            mode: mode,
            memberServiceIDs: memberIDs,
            stopOnFailure: stopOnFailure,
            iconSystemName: iconSystemName,
            isPinnedToMenuBar: isPinnedToMenuBar
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
