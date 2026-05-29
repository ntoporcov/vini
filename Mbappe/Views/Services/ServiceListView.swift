import SwiftUI

/// Scrollable tree of folders (simultaneous groups), services, and sequenced
/// groups (as leaves), plus an Ungrouped bucket.
struct ServiceListView: View {
    @EnvironmentObject private var store: ServicesStore

    var onEditGroup: (ServiceGroup) -> Void = { _ in }
    var onViewLogs: (MbappeService) -> Void = { _ in }

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
                            onViewLogs: onViewLogs
                        )
                    }
                }
            }
            .frame(maxHeight: 380)
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
    var onEditGroup: (ServiceGroup) -> Void
    var onViewLogs: (MbappeService) -> Void

    @EnvironmentObject private var store: ServicesStore

    private var indent: CGFloat { CGFloat(depth) * 16 }

    var body: some View {
        switch node.kind {
        case .service(let service):
            ServiceRowView(
                service: service,
                onViewLogs: { onViewLogs(service) },
                leadingInset: indent
            )
            divider

        case .sequencedGroup(let group):
            SequencedGroupRowView(group: group, leadingInset: indent, onEdit: { onEditGroup(group) })
            divider

        case .folder(let groupID):
            FolderRowView(node: node, groupID: groupID, depth: depth, onEditGroup: onEditGroup)
            divider
            if store.isExpanded(node.id) {
                ForEach(node.children) { child in
                    ServiceTreeNodeView(
                        node: child,
                        depth: depth + 1,
                        onEditGroup: onEditGroup,
                        onViewLogs: onViewLogs
                    )
                }
            }
        }
    }

    private var divider: some View {
        Divider().padding(.leading, 48 + indent)
    }
}

// MARK: - Folder row

private struct FolderRowView: View {
    let node: ServiceTreeNode
    let groupID: UUID?
    let depth: Int
    var onEditGroup: (ServiceGroup) -> Void

    @EnvironmentObject private var store: ServicesStore
    @State private var isWorking = false

    private var indent: CGFloat { CGFloat(depth) * 16 }

    private var group: ServiceGroup? {
        groupID.flatMap { store.group(withID: $0) }
    }

    private var reachable: [MbappeService] {
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
                if !reachable.isEmpty {
                    Text("\(runningCount)/\(reachable.count) running")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

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
        .contentShape(Rectangle())
        .onTapGesture { store.toggleExpanded(node.id) }
        .contextMenu {
            if let group {
                Button { onEditGroup(group) } label: { Label("Edit Group", systemImage: "pencil") }
                Button(role: .destructive) {
                    store.removeGroup(id: group.id)
                } label: { Label("Delete Group", systemImage: "trash") }
            }
        }
    }
}

// MARK: - Sequenced group leaf row

private struct SequencedGroupRowView: View {
    let group: ServiceGroup
    var leadingInset: CGFloat = 0
    var onEdit: () -> Void = {}

    @EnvironmentObject private var store: ServicesStore
    @State private var isWorking = false

    private var reachable: [MbappeService] { store.reachableServices(of: group) }
    private var runningCount: Int { reachable.filter { $0.status.isActive }.count }
    private var allRunning: Bool { !reachable.isEmpty && runningCount == reachable.count }

    var body: some View {
        HStack(spacing: 12) {
            if leadingInset > 0 { Spacer().frame(width: leadingInset) }

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: group.mode.iconSystemName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.system(size: 13, weight: .medium))
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

            Spacer()

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
