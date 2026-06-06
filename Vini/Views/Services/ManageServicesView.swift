import SwiftUI

/// Lists services kept out of the main list so the user can bring them back:
/// - hidden catalog services (unhide)
/// - unlisted / non-catalog services (surface into the main list)
struct ManageServicesView: View {
    @EnvironmentObject private var store: ServicesStore
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 320)
        .background(.ultraThinMaterial)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            Text("Hidden & Unlisted")
                .font(.headline)
            Spacer()
            if !store.hiddenCatalogServices.isEmpty {
                Button("Unhide All") {
                    store.unhideAll()
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !store.hasManageableServices {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !store.hiddenCatalogServices.isEmpty {
                        SectionHeader(title: "Hidden")
                        ForEach(store.hiddenCatalogServices) { service in
                            ManageRow(service: service, action: .unhide)
                            rowDivider(after: service, in: store.hiddenCatalogServices)
                        }
                    }
                    if !store.unlistedServices.isEmpty {
                        SectionHeader(title: "Not in Vini's known list")
                        ForEach(store.unlistedServices) { service in
                            ManageRow(service: service, action: .surface)
                            rowDivider(after: service, in: store.unlistedServices)
                        }
                    }
                }
            }
            .frame(maxHeight: 380)
        }
    }

    private func rowDivider(after service: ViniService, in list: [ViniService]) -> some View {
        Group {
            if service.id != list.last?.id {
                Divider().padding(.leading, 48)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "eye")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Nothing hidden or unlisted")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Services you hide, and tools not in Vini's known list, show up here.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

// MARK: - Section header

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }
}

// MARK: - Row

private struct ManageRow: View {
    enum Action { case unhide, surface }

    let service: ViniService
    let action: Action
    @EnvironmentObject private var store: ServicesStore

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: service.iconSystemName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(service.name)
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 4) {
                    Text(service.kind.sourceLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(service.status.displayLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            switch action {
            case .unhide:
                Button {
                    store.unhide(id: service.id)
                } label: {
                    Label("Unhide", systemImage: "eye")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Unhide")
            case .surface:
                Button {
                    store.surface(id: service.id)
                } label: {
                    Label("Add to list", systemImage: "plus.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Add to list")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

#if DEBUG
#Preview {
    ManageServicesView(onBack: {})
        .environmentObject(ServicesStore())
}
#endif
