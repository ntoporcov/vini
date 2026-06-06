import SwiftUI
import UniformTypeIdentifiers

enum ServiceRowSelectionKey {
    static func service(_ serviceID: String, parentGroupID: UUID?) -> String {
        "\(parentGroupID?.uuidString ?? "root")|\(serviceID)"
    }
}

/// Scrollable tree of folders (simultaneous groups), services, and sequenced
/// groups (as leaves), plus an Ungrouped bucket.
struct ServiceListView: View {
    @EnvironmentObject private var store: ServicesStore

    var onEditGroup: (ServiceGroup) -> Void = { _ in }
    var onViewLogs: (ViniService) -> Void = { _ in }
    var selectedServiceID: String? = nil
    var selectedServiceIDs: Set<String> = []
    var selectedServiceRowKeys: Set<String> = []
    var selectedServicesForActions: [ViniService] = []
    var onSelectService: (ViniService) -> Void = { _ in }
    var onSelectServiceRow: (ViniService, String, UUID?) -> Void = { _, _, _ in }
    var onCreateGroupFromServices: ([ViniService]) -> Void = { _ in }
    var maxHeight: CGFloat? = 380

    var body: some View {
        let nodes = store.tree
        if nodes.isEmpty {
            emptyStateView
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(nodes) { node in
                        ServiceTreeNodeView(
                            node: node,
                            depth: 0,
                            onEditGroup: onEditGroup,
                            onViewLogs: onViewLogs,
                            selectedServiceID: selectedServiceID,
                            selectedServiceIDs: selectedServiceIDs,
                            selectedServiceRowKeys: selectedServiceRowKeys,
                            selectedServicesForActions: selectedServicesForActions,
                            onSelectService: onSelectService,
                            onSelectServiceRow: onSelectServiceRow,
                            onCreateGroupFromServices: onCreateGroupFromServices
                        )
                    }
                }
            }
            .frame(maxHeight: maxHeight)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "server.rack")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No services found")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Use + to add a service or group.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Recursive node

/// Renders one tree node and (for folders) its children recursively.
struct ServiceTreeNodeView: View {
    let node: ServiceTreeNode
    let depth: Int
    /// The group this node is a direct member of (nil at root / Ungrouped).
    var parentGroupID: UUID?
    var onEditGroup: (ServiceGroup) -> Void
    var onViewLogs: (ViniService) -> Void
    var selectedServiceID: String? = nil
    var selectedServiceIDs: Set<String> = []
    var selectedServiceRowKeys: Set<String> = []
    var selectedServicesForActions: [ViniService] = []
    var onSelectService: (ViniService) -> Void = { _ in }
    var onSelectServiceRow: (ViniService, String, UUID?) -> Void = { _, _, _ in }
    var onCreateGroupFromServices: ([ViniService]) -> Void = { _ in }

    @EnvironmentObject private var store: ServicesStore
    @State private var showsInsertionGap = false
    @State private var folderDropIntent: FolderDropIntent = .none

    private var indent: CGFloat { CGFloat(depth) * 16 }

    var body: some View {
        switch node.kind {
        case .service(let service):
            let rowKey = ServiceRowSelectionKey.service(service.id, parentGroupID: parentGroupID)
            VStack(spacing: 0) {
                insertionGap(isVisible: showsInsertionGap, indent: indent)
                ServiceRowView(
                    service: service,
                    onViewLogs: { onViewLogs(service) },
                    leadingInset: indent,
                    isSelected: isSelected(service: service, rowKey: rowKey),
                    onSelect: {
                        onSelectService(service)
                        onSelectServiceRow(service, rowKey, parentGroupID)
                    },
                    selectedServicesForActions: selectedServicesForActions,
                    onCreateGroupFromServices: onCreateGroupFromServices,
                    removeFromGroup: removeAction(memberID: service.id, rowKey: rowKey)
                )
                .onDrag { NSItemProvider(object: service.id as NSString) }
                .onDrop(
                    of: [.plainText],
                    delegate: MemberDropDelegate(
                        targetGroupID: parentGroupID,
                        beforeMemberID: service.id,
                        isTargeted: $showsInsertionGap,
                        store: store
                    )
                )
            }
            divider

        case .sequencedGroup(let group):
            VStack(spacing: 0) {
                insertionGap(isVisible: showsInsertionGap, indent: indent)
                SequencedGroupRowView(
                    group: group,
                    leadingInset: indent,
                    onEdit: { onEditGroup(group) },
                    removeFromGroup: removeAction(memberID: group.memberReferenceID)
                )
                .onDrag { NSItemProvider(object: group.memberReferenceID as NSString) }
                .onDrop(
                    of: [.plainText],
                    delegate: MemberDropDelegate(
                        targetGroupID: parentGroupID,
                        beforeMemberID: group.memberReferenceID,
                        isTargeted: $showsInsertionGap,
                        store: store
                    )
                )
            }
            divider

        case .folder(let groupID):
            VStack(spacing: 0) {
                insertionGap(isVisible: folderDropIntent == .reorder, indent: indent)
                FolderRowView(
                    node: node,
                    groupID: groupID,
                    parentGroupID: parentGroupID,
                    depth: depth,
                    isDropDestination: folderDropIntent == .into,
                    folderDropIntent: $folderDropIntent,
                    onEditGroup: onEditGroup,
                    removeFromGroup: groupID.flatMap { removeAction(memberID: "group:\($0.uuidString)") }
                )
                .onDrag {
                    guard let groupID else { return NSItemProvider() }
                    return NSItemProvider(object: "group:\(groupID.uuidString)" as NSString)
                }
            }
            divider
            if store.isExpanded(node.id) {
                ForEach(node.children) { child in
                    ServiceTreeNodeView(
                        node: child,
                        depth: depth + 1,
                        parentGroupID: groupID,
                        onEditGroup: onEditGroup,
                        onViewLogs: onViewLogs,
                        selectedServiceID: selectedServiceID,
                        selectedServiceIDs: selectedServiceIDs,
                        selectedServiceRowKeys: selectedServiceRowKeys,
                        selectedServicesForActions: selectedServicesForActions,
                        onSelectService: onSelectService,
                        onSelectServiceRow: onSelectServiceRow,
                        onCreateGroupFromServices: onCreateGroupFromServices
                    )
                }
            }
        }
    }

    /// Returns a closure that removes `memberID` from the parent group, or nil
    /// when this node isn't inside a real group (root / Ungrouped bucket).
    private func removeAction(memberID: String, rowKey: String? = nil) -> (() -> Void)? {
        guard let parentGroupID else { return nil }
        return {
            let memberIDs = rowKey.map { selectedServiceRowKeys.contains($0) } == true
                ? selectedServicesForActions.map(\.id)
                : [memberID]
            for memberID in memberIDs {
                store.removeMember(memberID, fromGroup: parentGroupID)
            }
        }
    }

    private func isSelected(service: ViniService, rowKey: String) -> Bool {
        if !selectedServiceRowKeys.isEmpty { return selectedServiceRowKeys.contains(rowKey) }
        if !selectedServiceIDs.isEmpty { return selectedServiceIDs.contains(service.id) }
        return selectedServiceID == service.id
    }

    private var divider: some View {
        Divider().padding(.leading, 48 + indent)
    }

    private func insertionGap(isVisible: Bool, indent: CGFloat) -> some View {
        HStack(spacing: 8) {
            Spacer().frame(width: 40 + indent)
            Capsule()
                .fill(Color.accentColor.opacity(isVisible ? 0.9 : 0))
                .frame(height: 3)
            Spacer().frame(width: 12)
        }
        .frame(height: isVisible ? 14 : 0)
        .opacity(isVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: isVisible)
    }
}

private enum FolderDropIntent: Equatable {
    case none
    case reorder
    case into
}

private struct MemberDropDelegate: DropDelegate {
    let targetGroupID: UUID?
    var beforeMemberID: String? = nil
    @Binding var isTargeted: Bool
    @ObservedObject var store: ServicesStore

    func dropEntered(info: DropInfo) {
        withAnimation(.easeOut(duration: 0.12)) { isTargeted = true }
    }

    func dropExited(info: DropInfo) {
        withAnimation(.easeOut(duration: 0.12)) { isTargeted = false }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if !isTargeted { isTargeted = true }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        withAnimation(.easeOut(duration: 0.12)) { isTargeted = false }
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
            let memberID: String?
            if let data = item as? Data {
                memberID = String(data: data, encoding: .utf8)
            } else {
                memberID = item as? String
            }
            guard let memberID, !memberID.isEmpty else { return }
            Task { @MainActor in
                if targetGroupID == nil,
                   let draggedGroupID = ServiceGroup.groupID(fromMemberID: memberID),
                   let beforeMemberID,
                   let targetGroupID = ServiceGroup.groupID(fromMemberID: beforeMemberID) {
                    store.moveGroup(draggedGroupID, before: targetGroupID)
                } else {
                    store.moveMember(memberID, toGroup: targetGroupID, beforeMemberID: beforeMemberID)
                }
            }
        }
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText])
    }
}

private struct FolderDropDelegate: DropDelegate {
    let folderGroupID: UUID?
    let parentGroupID: UUID?
    let beforeMemberID: String?
    let reorderZoneWidth: CGFloat
    @Binding var intent: FolderDropIntent
    @ObservedObject var store: ServicesStore

    private func intent(for info: DropInfo) -> FolderDropIntent {
        info.location.x <= reorderZoneWidth && beforeMemberID != nil ? .reorder : .into
    }

    func dropEntered(info: DropInfo) {
        withAnimation(.easeOut(duration: 0.12)) { intent = self.intent(for: info) }
    }

    func dropExited(info: DropInfo) {
        withAnimation(.easeOut(duration: 0.12)) { intent = .none }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let nextIntent = intent(for: info)
        if intent != nextIntent {
            withAnimation(.easeOut(duration: 0.12)) { intent = nextIntent }
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        let reorder = info.location.x <= reorderZoneWidth && beforeMemberID != nil
        withAnimation(.easeOut(duration: 0.12)) { intent = .none }
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
            let memberID: String?
            if let data = item as? Data {
                memberID = String(data: data, encoding: .utf8)
            } else {
                memberID = item as? String
            }
            guard let memberID, !memberID.isEmpty else { return }
            Task { @MainActor in
                if reorder {
                    if parentGroupID == nil,
                       let draggedGroupID = ServiceGroup.groupID(fromMemberID: memberID),
                       let beforeMemberID,
                       let targetGroupID = ServiceGroup.groupID(fromMemberID: beforeMemberID) {
                        store.moveGroup(draggedGroupID, before: targetGroupID)
                    } else {
                        store.moveMember(memberID, toGroup: parentGroupID, beforeMemberID: beforeMemberID)
                    }
                } else {
                    store.moveMember(memberID, toGroup: folderGroupID)
                }
            }
        }
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText])
    }
}

// MARK: - Folder row

private struct FolderRowView: View {
    let node: ServiceTreeNode
    let groupID: UUID?
    let parentGroupID: UUID?
    let depth: Int
    var isDropDestination = false
    @Binding var folderDropIntent: FolderDropIntent
    var onEditGroup: (ServiceGroup) -> Void
    var removeFromGroup: (() -> Void)? = nil

    @EnvironmentObject private var store: ServicesStore
    @State private var isWorking = false

    private var indent: CGFloat { CGFloat(depth) * 16 }

    private var group: ServiceGroup? {
        groupID.flatMap { store.group(withID: $0) }
    }

    private var reachable: [ViniService] {
        guard let group else {
            // Ungrouped bucket: aggregate over its direct child services.
            return node.children.compactMap {
                if case .service(let svc) = $0.kind { return svc } else { return nil }
            }
        }
        return store.reachableServices(of: group)
    }

    private var runningCount: Int { reachable.filter { $0.status.isActive }.count }
    private var allRunning: Bool { !reachable.isEmpty && runningCount == reachable.count }

    var body: some View {
        HStack(spacing: 8) {
            if indent > 0 { Spacer().frame(width: indent) }

            Button {
                store.toggleExpanded(node.id)
            } label: {
                Image(systemName: store.isExpanded(node.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            .buttonStyle(.borderless)

            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill((node.isRunnableFolder ? Color.accentColor : Color.secondary).opacity(0.15))
                    .frame(width: 28, height: 28)
                Image(systemName: node.iconSystemName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(node.isRunnableFolder ? Color.accentColor : .secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !reachable.isEmpty {
                    Text("\(runningCount)/\(reachable.count) running")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            // Only real groups are run-all-able; the Ungrouped bucket is not.
            if node.isRunnableFolder, let group {
                if isWorking {
                    ProgressView().controlSize(.mini).frame(width: 20, height: 20)
                } else if allRunning {
                    Button {
                        Task { isWorking = true; await store.stopGroup(group); isWorking = false }
                    } label: { Image(systemName: "stop.fill").foregroundStyle(.red) }
                    .buttonStyle(.borderless)
                    .help("Stop all")
                } else {
                    Button {
                        Task { isWorking = true; await store.runGroup(group); isWorking = false }
                    } label: { Image(systemName: "play.fill").foregroundStyle(.green) }
                    .buttonStyle(.borderless)
                    .help("Run all")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(isDropDestination ? 0.12 : 0))
                .padding(.horizontal, 8)
        }
        .contentShape(Rectangle())
        .onTapGesture { store.toggleExpanded(node.id) }
        .contextMenu {
            if let group {
                Button { onEditGroup(group) } label: { Label("Edit Group", systemImage: "pencil") }
                Button {
                    store.setGroupPinned(group.id, isPinned: !group.isPinnedToMenuBar)
                } label: {
                    Label(group.isPinnedToMenuBar ? "Unpin from Menu Bar" : "Pin to Menu Bar", systemImage: group.isPinnedToMenuBar ? "pin.slash" : "pin")
                }
                if let removeFromGroup {
                    Button {
                        removeFromGroup()
                    } label: { Label("Remove from Group", systemImage: "minus.circle") }
                }
                Button(role: .destructive) {
                    store.removeGroup(id: group.id)
                } label: { Label("Delete Group", systemImage: "trash") }
            }
        }
        .onDrop(
            of: [.plainText],
            delegate: FolderDropDelegate(
                folderGroupID: groupID,
                parentGroupID: parentGroupID,
                beforeMemberID: groupID.map { "group:\($0.uuidString)" },
                reorderZoneWidth: 44 + indent,
                intent: $folderDropIntent,
                store: store
            )
        )
    }
}

// MARK: - Sequenced group leaf row

private struct SequencedGroupRowView: View {
    let group: ServiceGroup
    var leadingInset: CGFloat = 0
    var onEdit: () -> Void = {}
    var removeFromGroup: (() -> Void)? = nil

    @EnvironmentObject private var store: ServicesStore
    @State private var isWorking = false

    private var reachable: [ViniService] { store.reachableServices(of: group) }
    private var runningCount: Int { reachable.filter { $0.status.isActive }.count }
    private var allRunning: Bool { !reachable.isEmpty && runningCount == reachable.count }

    var body: some View {
        HStack(spacing: 12) {
            if leadingInset > 0 { Spacer().frame(width: leadingInset) }

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: group.iconSystemName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    Text("Sequence")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if !reachable.isEmpty {
                        Text("· \(runningCount)/\(reachable.count) running")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            if isWorking {
                ProgressView().controlSize(.mini).frame(width: 20, height: 20)
            } else if allRunning {
                Button {
                    Task { isWorking = true; await store.stopGroup(group); isWorking = false }
                } label: { Image(systemName: "stop.fill").foregroundStyle(.red) }
                .buttonStyle(.borderless)
                .help("Stop")
            } else {
                Button {
                    Task { isWorking = true; await store.runGroup(group); isWorking = false }
                } label: { Image(systemName: "play.fill").foregroundStyle(.green) }
                .buttonStyle(.borderless)
                .help("Run in sequence")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu {
            Button { onEdit() } label: { Label("Edit Group", systemImage: "pencil") }
            Button {
                store.setGroupPinned(group.id, isPinned: !group.isPinnedToMenuBar)
            } label: {
                Label(group.isPinnedToMenuBar ? "Unpin from Menu Bar" : "Pin to Menu Bar", systemImage: group.isPinnedToMenuBar ? "pin.slash" : "pin")
            }
            if let removeFromGroup {
                Button {
                    removeFromGroup()
                } label: { Label("Remove from Group", systemImage: "minus.circle") }
            }
            Button(role: .destructive) {
                store.removeGroup(id: group.id)
            } label: { Label("Delete Group", systemImage: "trash") }
        }
    }
}

#if DEBUG
#Preview {
    ServiceListView()
        .environmentObject(ServicesStore())
        .frame(width: 320)
}
#endif
