import SwiftUI

/// A single row in the service list — mirrors the JetBrains Services panel feel.
struct ServiceRowView: View {
    let service: ViniService
    var onViewLogs: () -> Void = {}
    /// Extra leading inset for tree indentation.
    var leadingInset: CGFloat = 0
    var isSelected = false
    var onSelect: () -> Void = {}
    var selectedServicesForActions: [ViniService] = []
    var onCreateGroupFromServices: ([ViniService]) -> Void = { _ in }
    /// Present when this row is inside a group; removes it from that group.
    var removeFromGroup: (() -> Void)? = nil
    @EnvironmentObject private var store: ServicesStore

    var body: some View {
        HStack(spacing: 12) {
            if leadingInset > 0 {
                Spacer().frame(width: leadingInset)
            }
            // Status indicator + icon
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: service.iconSystemName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(statusColor)
            }

            // Name + detail
            VStack(alignment: .leading, spacing: 2) {
                Text(service.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    StatusBadge(status: service.status)
                    Text(service.kind.sourceLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if let port = service.port {
                        Text(":\(port)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if isKeptAlive {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                            .help("Stays running when Vini quits")
                    }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            // Action buttons
            ServiceActionButtons(service: service)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(isSelected ? 0.18 : 0))
                .padding(.horizontal, 8)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu {
            let services = contextServices
            let isBulk = services.count > 1
            if !isBulk && isUserDefined {
                Button {
                    onViewLogs()
                } label: {
                    Label("View Logs", systemImage: "doc.text.magnifyingglass")
                }
                Divider()
            }
            if let removeFromGroup {
                Button {
                    removeFromGroup()
                } label: {
                    Label(isBulk ? "Remove Selected from Group" : "Remove from Group", systemImage: "minus.circle")
                }
                Divider()
            }
            if isBulk {
                Button {
                    onCreateGroupFromServices(services)
                } label: {
                    Label("Create New Group", systemImage: "rectangle.3.group")
                }
                Divider()
            }
            if !store.groups.isEmpty {
                Menu {
                    ForEach(store.groups) { group in
                        Button(group.name) {
                            for service in services {
                                store.addMember(service.id, toGroup: group.id)
                            }
                        }
                    }
                } label: {
                    Label(isBulk ? "Duplicate Selected to Group" : "Duplicate to Group", systemImage: "plus.square.on.square")
                }
                Divider()
            }
            Button(role: isBulk || services.contains(where: { $0.isUserDefinedForBulkAction }) ? .destructive : nil) {
                store.removeFromList(services)
            } label: {
                Label(removalLabel(for: services), systemImage: isBulk ? "trash" : removalIconName)
            }
        }
    }

    private var contextServices: [ViniService] {
        if isSelected, selectedServicesForActions.count > 1 {
            return selectedServicesForActions
        }
        return [service]
    }

    private var removalIconName: String {
        if case .userDefined = service.kind { return "trash" }
        return "eye.slash"
    }

    private func removalLabel(for services: [ViniService]) -> String {
        if services.count > 1 { return "Delete/Hide Selected" }
        if case .userDefined = service.kind { return "Delete Service" }
        return "Hide from List"
    }

    private var statusColor: Color {
        switch service.status {
        case .running:  .green
        case .stopped:  .secondary
        case .starting, .stopping: .orange
        case .unknown:  .secondary
        }
    }

    private var isKeptAlive: Bool {
        if case .userDefined(let def) = service.kind {
            return def.keepAliveOnQuit
        }
        return false
    }

    private var isUserDefined: Bool {
        if case .userDefined = service.kind { return true }
        return false
    }
}

private extension ViniService {
    var isUserDefinedForBulkAction: Bool {
        if case .userDefined = kind { return true }
        return false
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let status: ServiceStatus

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(status.displayLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var dotColor: Color {
        switch status {
        case .running:  .green
        case .stopped:  .red
        case .starting, .stopping: .orange
        case .unknown:  .gray
        }
    }
}

// MARK: - Action Buttons

struct ServiceActionButtons: View {
    let service: ViniService
    @EnvironmentObject private var store: ServicesStore

    var body: some View {
        HStack(spacing: 4) {
            if !service.isControllable {
                // Port-probed services are read-only.
                EmptyView()
            } else if service.status == .running {
                Button {
                    Task { await store.restart(service) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Restart")

                Button {
                    Task { await store.stop(service) }
                } label: {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Stop")
            } else if service.status == .stopped {
                Button {
                    Task { await store.start(service) }
                } label: {
                    Image(systemName: "play.fill")
                        .foregroundStyle(.green)
                }
                .buttonStyle(.borderless)
                .help("Start")
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 20, height: 20)
            }
        }
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 0) {
        ServiceRowView(service: ViniService(
            id: "brew:postgresql",
            name: "postgresql",
            kind: .homebrew(formula: "postgresql"),
            pid: 1234,
            port: 5432,
            status: .running,
            iconSystemName: "cylinder.fill"
        ))
        Divider()
        ServiceRowView(service: ViniService(
            id: "brew:redis",
            name: "redis",
            kind: .homebrew(formula: "redis"),
            pid: nil,
            port: 6379,
            status: .stopped,
            iconSystemName: "memorychip"
        ))
        Divider()
        ServiceRowView(service: ViniService(
            id: "port:80",
            name: "Nginx",
            kind: .portProbe(port: 80),
            pid: 5678,
            port: 80,
            status: .running,
            iconSystemName: "network"
        ))
    }
    .environmentObject(ServicesStore())
    .frame(width: 320)
}
#endif
