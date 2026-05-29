import SwiftUI

/// A row representing a service group with run-all / stop-all controls.
struct GroupRowView: View {
    let group: ServiceGroup
    var onEdit: () -> Void = {}
    @EnvironmentObject private var store: ServicesStore

    @State private var isWorking = false

    private var members: [MbappeService] {
        store.members(of: group)
    }

    private var runningCount: Int {
        members.filter { $0.status.isActive }.count
    }

    private var allRunning: Bool {
        !members.isEmpty && runningCount == members.count
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
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
                    Text(group.mode.displayLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("\(runningCount)/\(members.count) running")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if isWorking {
                ProgressView().controlSize(.mini).frame(width: 20, height: 20)
            } else if allRunning {
                Button {
                    Task { isWorking = true; await store.stopGroup(group); isWorking = false }
                } label: {
                    Image(systemName: "stop.fill").foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Stop all")
            } else {
                Button {
                    Task { isWorking = true; await store.runGroup(group); isWorking = false }
                } label: {
                    Image(systemName: "play.fill").foregroundStyle(.green)
                }
                .buttonStyle(.borderless)
                .help(group.mode == .sequenced ? "Run in sequence" : "Run all")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu {
            Button { onEdit() } label: { Label("Edit Group", systemImage: "pencil") }
            Button(role: .destructive) {
                store.removeGroup(id: group.id)
            } label: {
                Label("Delete Group", systemImage: "trash")
            }
        }
    }
}

#if DEBUG
#Preview {
    GroupRowView(group: ServiceGroup(
        name: "Backend stack",
        mode: .sequenced,
        memberServiceIDs: ["brew:redis", "brew:postgresql@17"]
    ))
    .environmentObject(ServicesStore())
    .frame(width: 320)
}
#endif
