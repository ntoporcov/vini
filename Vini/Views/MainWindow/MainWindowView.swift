import SwiftUI
import AppKit

// MARK: - Selection types

/// Unified selection for the content panel — either a service or a group.
private enum ContentSelection: Hashable {
    case service(String)
    case group(UUID)
}

// MARK: - Main Window View

/// Primary app window: three-column NavigationSplitView.
/// Sidebar = group tree (collapsible), Content = tree of selected group's children,
/// Detail = logs for the selected service.
struct MainWindowView: View {
    @EnvironmentObject private var store: ServicesStore
    @Environment(\.openWindow) private var openWindow

    @State private var selectedSidebarNode: String?
    @State private var selectedContentItem: ContentSelection?
    @State private var logContext: LogContext?
    @State private var selectionTask: Task<Void, Never>?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private struct LogContext: Identifiable {
        let service: ViniService
        let session: LogSession
        var id: String { service.id }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarColumn
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            contentColumn
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 480)
        } detail: {
            detailColumn
        }
        .frame(minWidth: 900, minHeight: 520)
        .onAppear { showInDock() }
        .task { showInDock() }
        .onDisappear { hideFromDock() }
        .onChange(of: selectedContentItem) { _, newValue in
            handleContentSelection(newValue)
        }
        .onChange(of: selectedSidebarNode) { _, _ in
            selectedContentItem = nil
            logContext = nil
        }
    }

    // MARK: - Sidebar Column (tree of groups)

    private var sidebarColumn: some View {
        List(selection: $selectedSidebarNode) {
            // "All Services" at top
            Label("All Services", systemImage: "square.grid.2x2")
                .tag("all")

            // Groups as a recursive tree
            ForEach(sidebarTree) { node in
                SidebarTreeRow(node: node, store: store, openEditor: openEditor)
            }

            // Ungrouped bucket
            if hasUngroupedServices {
                Label("Ungrouped", systemImage: "tray")
                    .tag("ungrouped")
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button { openEditor(.newService) } label: {
                        Label("New Service...", systemImage: "terminal")
                    }
                    Button { openEditor(.newGroup) } label: {
                        Label("New Group...", systemImage: "rectangle.3.group")
                    }
                } label: {
                    Image(systemName: "plus")
                }

                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh")
                }
            }
        }
    }

    // MARK: - Content Column (tree of children)

    private var contentColumn: some View {
        VStack(spacing: 0) {
            if let nodes = contentTree, !nodes.isEmpty {
                List(selection: $selectedContentItem) {
                    OutlineGroup(nodes, children: \.childrenOrNil) { node in
                        ContentTreeRow(node: node)
                            .tag(node.selectionTag)
                    }
                }
                .listStyle(.inset)
            } else {
                ContentUnavailableView(
                    "No Services",
                    systemImage: "server.rack",
                    description: Text("Select a group in the sidebar to see its services.")
                )
            }
        }
        .navigationTitle(contentTitle)
    }

    // MARK: - Detail Column (logs)

    private var detailColumn: some View {
        VStack(spacing: 0) {
            detailHeader
            Divider()
            if let logContext {
                LogContentView(session: logContext.session, compact: false)
                    .id(logContext.id)
            } else {
                ContentUnavailableView(
                    "Select a Service",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Choose a service from the list to view its logs.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
    }

    private var detailHeader: some View {
        HStack(spacing: 10) {
            if let service = logContext?.service {
                Image(systemName: service.iconSystemName)
                    .foregroundStyle(statusColor(for: service))
                VStack(alignment: .leading, spacing: 1) {
                    Text(service.name)
                        .font(.headline)
                    Text(service.kind.sourceLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Logs")
                    .font(.headline)
            }

            Spacer()

            if let service = logContext?.service, service.isControllable {
                DetailToolbarActions(service: service)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Sidebar tree data

    private var sidebarTree: [SidebarNode] {
        let nestedIDs = nestedGroupIDSet
        let topLevel = store.groups.filter { !nestedIDs.contains($0.id) }
        return topLevel.map { buildSidebarNode(for: $0, visited: []) }
    }

    private func buildSidebarNode(for group: ServiceGroup, visited: Set<UUID>) -> SidebarNode {
        var newVisited = visited
        newVisited.insert(group.id)

        let children: [SidebarNode] = group.memberServiceIDs.compactMap { memberID in
            guard let gid = ServiceGroup.groupID(fromMemberID: memberID),
                  !newVisited.contains(gid),
                  let child = store.group(withID: gid) else { return nil }
            return buildSidebarNode(for: child, visited: newVisited)
        }

        return SidebarNode(
            id: "group:\(group.id.uuidString)",
            group: group,
            children: children.isEmpty ? nil : children
        )
    }

    // MARK: - Content tree data

    private var contentTitle: String {
        switch selectedSidebarNode {
        case "all": return "All Services"
        case "ungrouped": return "Ungrouped"
        case let tag? where tag.hasPrefix("group:"):
            let uuidStr = String(tag.dropFirst("group:".count))
            if let uuid = UUID(uuidString: uuidStr), let group = store.group(withID: uuid) {
                return group.name
            }
            return "Group"
        default: return "Services"
        }
    }

    private var contentTree: [ContentNode]? {
        switch selectedSidebarNode {
        case "all":
            // Flat list of all services
            return store.services.map { service in
                ContentNode(id: "svc:\(service.id)", service: service, group: nil, children: nil)
            }

        case "ungrouped":
            let groupedIDs = allGroupedServiceIDs
            let ungrouped = store.services.filter { !groupedIDs.contains($0.id) }
            return ungrouped.map { service in
                ContentNode(id: "svc:\(service.id)", service: service, group: nil, children: nil)
            }

        case let tag? where tag.hasPrefix("group:"):
            let uuidStr = String(tag.dropFirst("group:".count))
            guard let uuid = UUID(uuidString: uuidStr),
                  let group = store.group(withID: uuid) else { return nil }
            return buildContentNodes(for: group, visited: [])

        default:
            return nil
        }
    }

    private func buildContentNodes(for group: ServiceGroup, visited: Set<UUID>) -> [ContentNode] {
        var newVisited = visited
        newVisited.insert(group.id)

        return group.memberServiceIDs.compactMap { memberID in
            if let gid = ServiceGroup.groupID(fromMemberID: memberID) {
                guard !newVisited.contains(gid),
                      let childGroup = store.group(withID: gid) else { return nil }
                let children = buildContentNodes(for: childGroup, visited: newVisited)
                return ContentNode(
                    id: "grp:\(gid.uuidString)",
                    service: nil,
                    group: childGroup,
                    children: children.isEmpty ? nil : children
                )
            } else if let service = store.service(withID: memberID) {
                return ContentNode(id: "svc:\(service.id)", service: service, group: nil, children: nil)
            }
            return nil
        }
    }

    // MARK: - Helpers

    private var nestedGroupIDSet: Set<UUID> {
        var nested = Set<UUID>()
        for group in store.groups {
            for member in group.memberServiceIDs {
                if let gid = ServiceGroup.groupID(fromMemberID: member) {
                    nested.insert(gid)
                }
            }
        }
        return nested
    }

    private var hasUngroupedServices: Bool {
        let groupedIDs = allGroupedServiceIDs
        return store.services.contains { !groupedIDs.contains($0.id) }
    }

    private var allGroupedServiceIDs: Set<String> {
        var ids = Set<String>()
        for group in store.groups {
            for member in group.memberServiceIDs where ServiceGroup.groupID(fromMemberID: member) == nil {
                ids.insert(member)
            }
        }
        return ids
    }

    // MARK: - Selection handling

    private func handleContentSelection(_ item: ContentSelection?) {
        guard let item else {
            logContext = nil
            return
        }
        switch item {
        case .service(let serviceID):
            guard let service = store.service(withID: serviceID) else { return }
            loadLogs(for: service)
        case .group:
            logContext = nil
        }
    }

    private func loadLogs(for service: ViniService) {
        selectionTask?.cancel()
        selectionTask = Task {
            let session = await store.makeLogSession(for: service)
            guard !Task.isCancelled else { return }
            logContext = LogContext(service: service, session: session)
        }
    }

    // MARK: - Utilities

    private func showInDock() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func hideFromDock() {
        selectionTask?.cancel()
        selectionTask = nil
        if !store.isScreenshotMode {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func openEditor(_ target: EditorWindowTarget) {
        openWindow(value: target)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func statusColor(for service: ViniService) -> Color {
        switch service.status {
        case .running: .green
        case .stopped: .secondary
        case .starting, .stopping: .orange
        case .unknown: .secondary
        }
    }
}

// MARK: - Sidebar Node Model

private struct SidebarNode: Identifiable {
    let id: String
    let group: ServiceGroup
    let children: [SidebarNode]?
}

// MARK: - Sidebar Tree Row

private struct SidebarTreeRow: View {
    let node: SidebarNode
    @ObservedObject var store: ServicesStore
    var openEditor: (EditorWindowTarget) -> Void

    private var reachable: [ViniService] { store.reachableServices(of: node.group) }
    private var runningCount: Int { reachable.filter { $0.status.isActive }.count }

    var body: some View {
        if let children = node.children, !children.isEmpty {
            DisclosureGroup {
                ForEach(children) { child in
                    SidebarTreeRow(node: child, store: store, openEditor: openEditor)
                }
            } label: {
                groupLabel
                    .tag(node.id)
            }
        } else {
            groupLabel
                .tag(node.id)
        }
    }

    private var groupLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: node.group.iconSystemName)
                .foregroundStyle(Color.accentColor)
            Text(node.group.name)
                .lineLimit(1)
            Spacer()
            if !reachable.isEmpty {
                Text("\(runningCount)/\(reachable.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .contextMenu {
            Button { openEditor(.editGroup(node.group)) } label: {
                Label("Edit Group", systemImage: "pencil")
            }
            Button {
                store.setGroupPinned(node.group.id, isPinned: !node.group.isPinnedToMenuBar)
            } label: {
                Label(
                    node.group.isPinnedToMenuBar ? "Unpin from Menu Bar" : "Pin to Menu Bar",
                    systemImage: node.group.isPinnedToMenuBar ? "pin.slash" : "pin"
                )
            }
            Divider()
            Button(role: .destructive) {
                store.removeGroup(id: node.group.id)
            } label: {
                Label("Delete Group", systemImage: "trash")
            }
        }
    }
}

// MARK: - Content Node Model

private struct ContentNode: Identifiable {
    let id: String
    let service: ViniService?
    let group: ServiceGroup?
    let children: [ContentNode]?

    /// For OutlineGroup: return children only if non-empty.
    var childrenOrNil: [ContentNode]? { children }

    var selectionTag: ContentSelection {
        if let service {
            return .service(service.id)
        } else if let group {
            return .group(group.id)
        }
        return .service(id) // fallback
    }
}

// MARK: - Content Tree Row

private struct ContentTreeRow: View {
    let node: ContentNode
    @EnvironmentObject private var store: ServicesStore

    var body: some View {
        if let service = node.service {
            serviceRow(service)
        } else if let group = node.group {
            groupRow(group)
        }
    }

    private func serviceRow(_ service: ViniService) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(statusColor(for: service).opacity(0.15))
                    .frame(width: 26, height: 26)
                Image(systemName: service.iconSystemName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(statusColor(for: service))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(service.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    StatusBadge(status: service.status)
                    if let port = service.port {
                        Text(":\(port)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            if service.isControllable {
                ServiceActionButtons(service: service)
            }
        }
        .padding(.vertical, 2)
    }

    private func groupRow(_ group: ServiceGroup) -> some View {
        let reachable = store.reachableServices(of: group)
        let runningCount = reachable.filter { $0.status.isActive }.count

        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 26, height: 26)
                Image(systemName: group.iconSystemName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(group.mode.displayLabel)
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

            ContentGroupActions(group: group)
        }
        .padding(.vertical, 2)
    }

    private func statusColor(for service: ViniService) -> Color {
        switch service.status {
        case .running: .green
        case .stopped: .secondary
        case .starting, .stopping: .orange
        case .unknown: .secondary
        }
    }
}

// MARK: - Content Group Actions

private struct ContentGroupActions: View {
    let group: ServiceGroup
    @EnvironmentObject private var store: ServicesStore
    @State private var isWorking = false

    private var reachable: [ViniService] { store.reachableServices(of: group) }
    private var allRunning: Bool {
        let r = reachable
        return !r.isEmpty && r.allSatisfy { $0.status.isActive }
    }

    var body: some View {
        if isWorking {
            ProgressView().controlSize(.mini)
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

// MARK: - Detail Toolbar Actions

private struct DetailToolbarActions: View {
    let service: ViniService
    @EnvironmentObject private var store: ServicesStore

    var body: some View {
        HStack(spacing: 6) {
            if service.status == .running {
                Button {
                    Task { await store.restart(service) }
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                Button(role: .destructive) {
                    Task { await store.stop(service) }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            } else if service.status == .stopped {
                Button {
                    Task { await store.start(service) }
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .labelStyle(.iconOnly)
    }
}

#if DEBUG
#Preview {
    MainWindowView()
        .environmentObject(ServicesStore())
}
#endif
