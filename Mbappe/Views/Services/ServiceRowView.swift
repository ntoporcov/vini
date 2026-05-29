import SwiftUI

/// A single row in the service list — mirrors the JetBrains Services panel feel.
struct ServiceRowView: View {
    let service: MbappeService
    @EnvironmentObject private var store: ServicesStore

    var body: some View {
        HStack(spacing: 12) {
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
                }
            }

            Spacer()

            // Action buttons
            ServiceActionButtons(service: service)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu {
            if case .userDefined = service.kind {
                Button(role: .destructive) {
                    store.delete(service)
                } label: {
                    Label("Delete Service", systemImage: "trash")
                }
            } else {
                Button {
                    store.hide(service)
                } label: {
                    Label("Hide from List", systemImage: "eye.slash")
                }
            }
        }
    }

    private var statusColor: Color {
        switch service.status {
        case .running:  .green
        case .stopped:  .secondary
        case .starting, .stopping: .orange
        case .unknown:  .secondary
        }
    }
}

// MARK: - Status Badge

private struct StatusBadge: View {
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

private struct ServiceActionButtons: View {
    let service: MbappeService
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
        ServiceRowView(service: MbappeService(
            id: "brew:postgresql",
            name: "postgresql",
            kind: .homebrew(formula: "postgresql"),
            pid: 1234,
            port: 5432,
            status: .running,
            iconSystemName: "cylinder.fill"
        ))
        Divider()
        ServiceRowView(service: MbappeService(
            id: "brew:redis",
            name: "redis",
            kind: .homebrew(formula: "redis"),
            pid: nil,
            port: 6379,
            status: .stopped,
            iconSystemName: "memorychip"
        ))
        Divider()
        ServiceRowView(service: MbappeService(
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
