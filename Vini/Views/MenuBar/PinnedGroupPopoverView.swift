import SwiftUI

struct PinnedGroupPopoverView: View {
    @EnvironmentObject private var store: ServicesStore
    @Environment(\.openWindow) private var openWindow

    let groupID: UUID

    private var group: ServiceGroup? { store.group(withID: groupID) }
    private var services: [ViniService] {
        guard let group else { return [] }
        return store.reachableServices(of: group)
    }
    private var runningCount: Int { services.filter { $0.status.isActive }.count }
    private var allRunning: Bool { !services.isEmpty && runningCount == services.count }
    private var isWorking: Bool { store.isGroupWorking(groupID) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if services.isEmpty {
                ContentUnavailableView("No Services", systemImage: "tray", description: Text("This group has no available controllable services."))
                    .frame(height: 220)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(services, id: \.id) { service in
                            serviceRow(service)
                        }
                    }
                    .padding(10)
                }
                .frame(height: 360)
            }
        }
        .frame(width: 320, height: 420)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: group?.iconSystemName ?? "rectangle.3.group")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(group?.name ?? "Pinned Group")
                    .font(.headline)
                    .lineLimit(1)
                Text("\(runningCount)/\(services.count) running")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            groupAction

            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "macwindow")
            }
            .buttonStyle(.borderless)
            .help("Open Vini")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var groupAction: some View {
        Group {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
            } else if let group, allRunning {
                Button {
                    Task { await store.stopGroup(group) }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                .help("Stop all")
            } else if let group {
                Button {
                    Task { await store.runGroup(group) }
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .help("Start all")
            }
        }
        .frame(width: 24, height: 24)
    }

    private func serviceRow(_ service: ViniService) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(service.status.tint.opacity(0.16))
                    .frame(width: 32, height: 32)
                Image(systemName: service.iconSystemName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(service.status.tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(service.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(service.status.displayLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            serviceAction(service)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    @ViewBuilder
    private func serviceAction(_ service: ViniService) -> some View {
        Group {
            if service.status == .starting || service.status == .stopping {
                ProgressView()
                    .controlSize(.mini)
            } else if service.status.isActive {
                Button {
                    Task { await store.stop(service) }
                } label: {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Stop")
            } else if service.isControllable {
                Button {
                    Task { await store.start(service) }
                } label: {
                    Image(systemName: "play.fill")
                        .foregroundStyle(.green)
                }
                .buttonStyle(.borderless)
                .help("Start")
            }
        }
        .frame(width: 20, height: 20)
    }
}

private extension ServiceStatus {
    var tint: Color {
        switch self {
        case .running: Color.green
        case .starting, .stopping: Color.yellow
        case .stopped: Color.red
        case .unknown: Color.secondary
        }
    }
}

#if DEBUG
#Preview {
    PinnedGroupPopoverView(groupID: UUID())
        .environmentObject(ServicesStore())
}
#endif
