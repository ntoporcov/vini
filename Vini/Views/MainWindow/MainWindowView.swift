import SwiftUI
import AppKit

/// Primary app window: service tree on the left, logs for the selected service on the right.
struct MainWindowView: View {
    @EnvironmentObject private var store: ServicesStore
    @Environment(\.openWindow) private var openWindow

    @State private var selectedServiceID: String?
    @State private var selectedServiceRowKeys: Set<String> = []
    @State private var selectionAnchorServiceRowKey: String?
    @State private var logContext: LogContext?
    @State private var selectionTask: Task<Void, Never>?

    private struct LogContext: Identifiable {
        let service: ViniService
        let session: LogSession
        var id: String { service.id }
    }

    private struct VisibleServiceRow {
        let key: String
        let service: ViniService
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 440)

            detail
                .frame(minWidth: 520)
        }
        .frame(minWidth: 860, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { showInDock() }
        .onDisappear { hideFromDock() }
        .task { selectInitialServiceIfNeeded() }
        .onChange(of: store.services) { selectInitialServiceIfNeeded() }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ServiceListView(
                onEditGroup: openGroupEditor,
                onViewLogs: select,
                selectedServiceID: selectedServiceID,
                selectedServiceRowKeys: selectedServiceRowKeys,
                selectedServicesForActions: selectedServices,
                onSelectServiceRow: select,
                onCreateGroupFromServices: createGroup,
                maxHeight: nil
            )
        }
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Services")
                .font(.headline)
            if !selectedServiceRowKeys.isEmpty {
                Text("\(selectedServiceRowKeys.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !selectedServiceRowKeys.isEmpty {
                Button {
                    createGroupFromSelection()
                } label: {
                    Label("Create Group", systemImage: "rectangle.3.group")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Create New Group from Selection")

                Button(role: .destructive) {
                    removeSelectedServices()
                } label: {
                    Label("Delete/Hide Selected", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Delete custom services or hide discovered services")
            }
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
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var detail: some View {
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
                    description: Text("Choose a service on the left to view its logs.")
                )
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
                ServiceToolbarActions(service: service)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func selectInitialServiceIfNeeded() {
        if let selectedServiceID, store.service(withID: selectedServiceID) != nil {
            return
        }
        if let first = firstService(in: store.tree) {
            select(first)
        } else {
            selectedServiceID = nil
            selectedServiceRowKeys = []
            selectionAnchorServiceRowKey = nil
            logContext = nil
        }
    }

    private func firstService(in nodes: [ServiceTreeNode]) -> ViniService? {
        for node in nodes {
            switch node.kind {
            case .service(let service):
                return service
            case .folder, .sequencedGroup:
                if let service = firstService(in: node.children) {
                    return service
                }
            }
        }
        return nil
    }

    private func select(_ service: ViniService) {
        let row = visibleServiceRows(in: store.tree).first { $0.service.id == service.id }
        let rowKey = row?.key ?? ServiceRowSelectionKey.service(service.id, parentGroupID: nil)
        updateSelection(for: service, rowKey: rowKey)
        loadLogs(for: service)
    }

    private func select(_ service: ViniService, rowKey: String, parentGroupID: UUID?) {
        updateSelection(for: service, rowKey: rowKey)
        loadLogs(for: service)
    }

    private func updateSelection(for service: ViniService, rowKey: String) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let anchorKey = selectionAnchorServiceRowKey ?? selectedServiceRowKeys.first {
            selectedServiceRowKeys = rangeSelection(from: anchorKey, to: rowKey)
        } else if flags.contains(.command) {
            if selectedServiceRowKeys.contains(rowKey) {
                selectedServiceRowKeys.remove(rowKey)
            } else {
                selectedServiceRowKeys.insert(rowKey)
            }
            if selectedServiceRowKeys.isEmpty {
                selectedServiceRowKeys.insert(rowKey)
            }
            selectionAnchorServiceRowKey = rowKey
        } else {
            selectedServiceRowKeys = [rowKey]
            selectionAnchorServiceRowKey = rowKey
        }
    }

    private func rangeSelection(from anchorID: String, to targetID: String) -> Set<String> {
        let visibleKeys = visibleServiceRows(in: store.tree).map(\.key)
        guard let anchorIndex = visibleKeys.firstIndex(of: anchorID),
              let targetIndex = visibleKeys.firstIndex(of: targetID) else {
            return [targetID]
        }
        let bounds = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        return Set(visibleKeys[bounds])
    }

    private func visibleServiceRows(in nodes: [ServiceTreeNode], parentGroupID: UUID? = nil) -> [VisibleServiceRow] {
        var rows: [VisibleServiceRow] = []
        for node in nodes {
            switch node.kind {
            case .service(let service):
                rows.append(VisibleServiceRow(
                    key: ServiceRowSelectionKey.service(service.id, parentGroupID: parentGroupID),
                    service: service
                ))
            case .sequencedGroup:
                continue
            case .folder(let groupID):
                if store.isExpanded(node.id) {
                    rows.append(contentsOf: visibleServiceRows(in: node.children, parentGroupID: groupID))
                }
            }
        }
        return rows
    }

    private func loadLogs(for service: ViniService) {
        selectedServiceID = service.id
        selectionTask?.cancel()
        selectionTask = Task {
            let session = await store.makeLogSession(for: service)
            guard !Task.isCancelled else { return }
            guard selectedServiceID == service.id else { return }
            logContext = LogContext(service: service, session: session)
        }
    }

    private var selectedServices: [ViniService] {
        visibleServiceRows(in: store.tree)
            .filter { selectedServiceRowKeys.contains($0.key) }
            .map(\.service)
    }

    private func createGroupFromSelection() {
        createGroup(from: selectedServices)
    }

    private func createGroup(from services: [ViniService]) {
        let ids = services.map(\.id)
        store.createSimultaneousGroup(serviceIDs: ids)
    }

    private func removeSelectedServices() {
        let removingPrimarySelection = selectedServiceID.map { selectedServices.map(\.id).contains($0) } ?? false
        store.removeFromList(selectedServices)
        selectedServiceRowKeys = []
        selectionAnchorServiceRowKey = nil
        if removingPrimarySelection {
            selectedServiceID = nil
            logContext = nil
            selectInitialServiceIfNeeded()
        }
    }

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

    private func openGroupEditor(_ group: ServiceGroup) {
        openEditor(.editGroup(group))
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

private struct ServiceToolbarActions: View {
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
