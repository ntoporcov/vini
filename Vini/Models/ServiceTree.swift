import Foundation

/// A node in the services tree shown in the popover.
///
/// - `service`: a plain discovered/user service (leaf).
/// - `sequencedGroup`: a sequenced group, rendered as a single leaf that runs
///   its members in order.
/// - `folder`: a simultaneous group, expandable, with child nodes. Can be the
///   special "Ungrouped" bucket which is not group-startable.
struct ServiceTreeNode: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case service(ViniService)
        case sequencedGroup(ServiceGroup)
        /// A simultaneous group folder. `groupID` is nil for the Ungrouped bucket.
        case folder(groupID: UUID?)
    }

    /// Stable identity for SwiftUI + expansion tracking.
    let id: String
    let kind: Kind
    let name: String
    let iconSystemName: String
    /// Child nodes (folders only).
    var children: [ServiceTreeNode]

    var isFolder: Bool {
        if case .folder = kind { return true }
        return false
    }

    /// Whether this node can be "run all" (folders that are real groups, not the
    /// Ungrouped bucket).
    var isRunnableFolder: Bool {
        if case .folder(let groupID) = kind { return groupID != nil }
        return false
    }
}

/// Special id for the Ungrouped bucket node.
enum ServiceTree {
    static let ungroupedNodeID = "folder:ungrouped"

    /// Build the tree from the user's groups and all main-list services.
    ///
    /// - Top-level groups (not referenced as a member of any other group) appear
    ///   at the root: simultaneous as folders, sequenced as leaves.
    /// - Services not contained in any group go into the "Ungrouped" bucket.
    /// - Recursion is cycle-safe via a visited set.
    static func build(groups: [ServiceGroup], services: [ViniService], serviceOrderIDs: [String] = []) -> [ServiceTreeNode] {
        let groupsByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        let servicesByID = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) })
        let serviceOrder = Dictionary(uniqueKeysWithValues: serviceOrderIDs.enumerated().map { ($0.element, $0.offset) })

        // Determine which groups are nested (referenced by another group) so we
        // don't also show them at the root.
        var nestedGroupIDs = Set<UUID>()
        for group in groups {
            for member in group.memberServiceIDs {
                if let gid = ServiceGroup.groupID(fromMemberID: member) {
                    nestedGroupIDs.insert(gid)
                }
            }
        }

        // Services that belong to at least one group are not "ungrouped".
        var groupedServiceIDs = Set<String>()
        for group in groups {
            for member in group.memberServiceIDs where ServiceGroup.groupID(fromMemberID: member) == nil {
                groupedServiceIDs.insert(member)
            }
        }

        var roots: [ServiceTreeNode] = []

        // Top-level groups preserve user order from the stored groups array.
        let topLevelGroups = groups
            .filter { !nestedGroupIDs.contains($0.id) }

        for group in topLevelGroups {
            roots.append(node(for: group, groupsByID: groupsByID, servicesByID: servicesByID, visited: []))
        }

        // Ungrouped bucket: services not in any group.
        let ungrouped = services
            .filter { !groupedServiceIDs.contains($0.id) }
            .sorted { lhs, rhs in
                switch (serviceOrder[lhs.id], serviceOrder[rhs.id]) {
                case let (l?, r?): return l < r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            }
            .map { serviceNode($0) }

        if !ungrouped.isEmpty {
            roots.append(
                ServiceTreeNode(
                    id: ungroupedNodeID,
                    kind: .folder(groupID: nil),
                    name: "Ungrouped",
                    iconSystemName: "tray",
                    children: ungrouped
                )
            )
        }

        return roots
    }

    // MARK: - Node construction

    private static func node(
        for group: ServiceGroup,
        groupsByID: [UUID: ServiceGroup],
        servicesByID: [String: ViniService],
        visited: Set<UUID>
    ) -> ServiceTreeNode {
        // Sequenced groups render as a single leaf.
        if group.mode == .sequenced {
            return ServiceTreeNode(
                id: group.memberReferenceID,
                kind: .sequencedGroup(group),
                name: group.name,
                iconSystemName: group.iconSystemName,
                children: []
            )
        }

        // Simultaneous group -> folder with children.
        var newVisited = visited
        newVisited.insert(group.id)

        var children: [ServiceTreeNode] = []
        for member in group.memberServiceIDs {
            if let gid = ServiceGroup.groupID(fromMemberID: member) {
                // Nested group — skip if it would create a cycle.
                guard !newVisited.contains(gid), let child = groupsByID[gid] else { continue }
                children.append(node(for: child, groupsByID: groupsByID, servicesByID: servicesByID, visited: newVisited))
            } else if let service = servicesByID[member] {
                children.append(serviceNode(service))
            }
            // Unknown/unavailable members are silently dropped.
        }

        return ServiceTreeNode(
            id: group.memberReferenceID,
            kind: .folder(groupID: group.id),
            name: group.name,
            iconSystemName: group.iconSystemName,
            children: children
        )
    }

    private static func serviceNode(_ service: ViniService) -> ServiceTreeNode {
        ServiceTreeNode(
            id: service.id,
            kind: .service(service),
            name: service.name,
            iconSystemName: service.iconSystemName,
            children: []
        )
    }
}
