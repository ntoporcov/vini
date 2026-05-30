import XCTest
@testable import Mbappe

final class ServiceTreeTests: XCTestCase {

    private func svc(_ id: String, _ name: String) -> MbappeService {
        MbappeService(id: id, name: name, kind: .homebrew(formula: name),
                      pid: nil, port: nil, status: .stopped, iconSystemName: "x")
    }

    // MARK: - Tree building

    func testLooseServicesGoIntoUngroupedBucket() {
        let services = [svc("brew:redis", "Redis"), svc("brew:pg", "PostgreSQL")]
        let tree = ServiceTree.build(groups: [], services: services)
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree.first?.id, ServiceTree.ungroupedNodeID)
        XCTAssertEqual(tree.first?.children.count, 2)
        XCTAssertFalse(tree.first?.isRunnableFolder ?? true) // Ungrouped is not runnable
    }

    func testSimultaneousGroupIsAFolderWithChildren() {
        let redis = svc("brew:redis", "Redis")
        let group = ServiceGroup(name: "Stack", mode: .simultaneous, memberServiceIDs: ["brew:redis"])
        let tree = ServiceTree.build(groups: [group], services: [redis])
        let folder = tree.first { $0.name == "Stack" }
        XCTAssertNotNil(folder)
        XCTAssertTrue(folder!.isFolder)
        XCTAssertTrue(folder!.isRunnableFolder)
        XCTAssertEqual(folder!.children.count, 1)
        // Grouped service should NOT also appear in Ungrouped.
        XCTAssertNil(tree.first { $0.id == ServiceTree.ungroupedNodeID })
    }

    func testSequencedGroupIsALeaf() {
        let redis = svc("brew:redis", "Redis")
        let group = ServiceGroup(name: "Seq", mode: .sequenced, memberServiceIDs: ["brew:redis"])
        let tree = ServiceTree.build(groups: [group], services: [redis])
        let node = tree.first { $0.name == "Seq" }
        XCTAssertNotNil(node)
        XCTAssertFalse(node!.isFolder)
        if case .sequencedGroup = node!.kind {} else { XCTFail("expected sequencedGroup leaf") }
    }

    func testNestedGroupNotShownAtRoot() {
        let redis = svc("brew:redis", "Redis")
        let inner = ServiceGroup(name: "Inner", mode: .simultaneous, memberServiceIDs: ["brew:redis"])
        let outer = ServiceGroup(name: "Outer", mode: .simultaneous, memberServiceIDs: [inner.memberReferenceID])
        let tree = ServiceTree.build(groups: [inner, outer], services: [redis])
        // Only Outer at root; Inner appears as a child of Outer.
        XCTAssertEqual(tree.map(\.name), ["Outer"])
        XCTAssertEqual(tree.first?.children.map(\.name), ["Inner"])
    }

    func testCycleDoesNotInfiniteLoopInTree() {
        // A contains B, B contains A (manually corrupted state).
        let a = ServiceGroup(id: UUID(), name: "A", mode: .simultaneous, memberServiceIDs: [])
        let b = ServiceGroup(id: UUID(), name: "B", mode: .simultaneous, memberServiceIDs: [a.memberReferenceID])
        var aWithB = a
        aWithB.memberServiceIDs = [b.memberReferenceID]
        // The key assertion is that build terminates (no crash/hang) on a cycle.
        // A mutual cycle has no top-level entry, so the tree is legitimately empty.
        let tree = ServiceTree.build(groups: [aWithB, b], services: [])
        XCTAssertTrue(tree.isEmpty)
    }
}

// MARK: - Store recursion + cycle prevention

final class ServiceTreeStoreTests: XCTestCase {

    @MainActor
    private func freshStore() -> ServicesStore {
        UserDefaults.standard.removeObject(forKey: "mbappe.groups")
        UserDefaults.standard.removeObject(forKey: "mbappe.expandedNodeIDs")
        return ServicesStore()
    }

    private func svc(_ id: String, _ name: String) -> MbappeService {
        MbappeService(id: id, name: name, kind: .homebrew(formula: name),
                      pid: nil, port: nil, status: .stopped, iconSystemName: "x")
    }

    @MainActor
    func testReachableServicesFollowsNesting() {
        let store = freshStore()
        store._setDiscoveredForTesting([svc("brew:redis", "Redis"), svc("brew:pg", "PostgreSQL")])
        let inner = ServiceGroup(name: "Inner", mode: .simultaneous, memberServiceIDs: ["brew:pg"])
        store.addGroup(inner)
        let outer = ServiceGroup(name: "Outer", mode: .simultaneous,
                                 memberServiceIDs: ["brew:redis", inner.memberReferenceID])
        store.addGroup(outer)

        let reachable = Set(store.reachableServices(of: outer).map(\.id))
        XCTAssertEqual(reachable, ["brew:redis", "brew:pg"])
    }

    @MainActor
    func testWouldCreateCycleDetectsDirectAndIndirect() {
        let store = freshStore()
        let a = ServiceGroup(id: UUID(), name: "A", mode: .simultaneous, memberServiceIDs: [])
        store.addGroup(a)
        let b = ServiceGroup(id: UUID(), name: "B", mode: .simultaneous, memberServiceIDs: [a.memberReferenceID])
        store.addGroup(b)

        // Adding a group into itself is a cycle.
        XCTAssertTrue(store.wouldCreateCycle(addingGroup: a.id, to: a.id))
        // Adding B into A would create A->B->A.
        XCTAssertTrue(store.wouldCreateCycle(addingGroup: b.id, to: a.id))
        // Adding A into B is fine (B already contains A; this is the existing edge, not a new cycle).
        // But adding B's parent chain back is the concern; A into B specifically:
        // B contains A, so adding A into B again is just a duplicate edge, not a NEW cycle through B.
        // The dangerous direction is verified above.
    }

    @MainActor
    func testRemoveGroupStripsReferencesFromOthers() {        let store = freshStore()
        let inner = ServiceGroup(id: UUID(), name: "Inner", mode: .simultaneous, memberServiceIDs: [])
        store.addGroup(inner)
        let outer = ServiceGroup(name: "Outer", mode: .simultaneous, memberServiceIDs: [inner.memberReferenceID])
        store.addGroup(outer)

        store.removeGroup(id: inner.id)
        let updatedOuter = store.group(withID: outer.id)
        XCTAssertEqual(updatedOuter?.memberServiceIDs, [])
    }

    @MainActor
    func testExpansionStatePersists() {
        let storeA = freshStore()
        storeA.toggleExpanded("folder:test")
        XCTAssertTrue(storeA.isExpanded("folder:test"))

        let storeB = ServicesStore()
        XCTAssertTrue(storeB.isExpanded("folder:test"))
    }

    @MainActor
    func testRemoveMemberRemovesOnlyFromThatGroup() {
        let store = freshStore()
        store._setDiscoveredForTesting([svc("brew:redis", "Redis")])
        let a = ServiceGroup(id: UUID(), name: "A", mode: .simultaneous, memberServiceIDs: ["brew:redis"])
        let b = ServiceGroup(id: UUID(), name: "B", mode: .simultaneous, memberServiceIDs: ["brew:redis"])
        store.addGroup(a)
        store.addGroup(b)

        store.removeMember("brew:redis", fromGroup: a.id)

        XCTAssertEqual(store.group(withID: a.id)?.memberServiceIDs, [])
        // Still present in B.
        XCTAssertEqual(store.group(withID: b.id)?.memberServiceIDs, ["brew:redis"])
    }
}
