import XCTest
@testable import Vini

final class ServicesStoreTests: XCTestCase {
    @MainActor
    func testInitialState() {
        let store = ServicesStore(defaults: TestDefaults.make())
        XCTAssertTrue(store.services.isEmpty)
        XCTAssertFalse(store.isRefreshing)
        XCTAssertNil(store.lastError)
    }

    func testHomebrewServiceIsControllable() {
        let service = ViniService(
            id: "brew:redis",
            name: "redis",
            kind: .homebrew(formula: "redis"),
            pid: nil,
            port: nil,
            status: .stopped,
            iconSystemName: "memorychip"
        )
        XCTAssertTrue(service.isControllable)
    }

    func testPortProbedServiceIsNotControllable() {
        let service = ViniService(
            id: "port:5432",
            name: "PostgreSQL",
            kind: .portProbe(port: 5432),
            pid: 99,
            port: 5432,
            status: .running,
            iconSystemName: "cylinder.fill"
        )
        XCTAssertFalse(service.isControllable)
    }

    // MARK: - KnownServices catalog

    func testKnownServiceMatchesVersionedFormula() {
        let entry = KnownServices.entry(forIdentifier: "postgresql@17")
        XCTAssertEqual(entry?.displayName, "PostgreSQL")
        XCTAssertEqual(entry?.port, 5432)
    }

    func testKnownServiceMatchesLaunchdLabel() {
        let entry = KnownServices.entry(forIdentifier: "homebrew.mxcl.postgresql@17")
        XCTAssertEqual(entry?.displayName, "PostgreSQL")
    }

    func testPodmanIsInCatalog() {
        XCTAssertEqual(KnownServices.entry(forIdentifier: "podman")?.displayName, "Podman")
    }

    func testUnknownFormulaIsFilteredOut() {
        XCTAssertNil(KnownServices.entry(forIdentifier: "some-obscure-tool"))
    }

    func testPortLookup() {
        XCTAssertEqual(KnownServices.entry(forPort: 6379)?.displayName, "Redis")
        XCTAssertNil(KnownServices.entry(forPort: 9999))
    }

    @MainActor
    func testScreenshotModeSeedsDemoStateAndDoesNotPersist() async throws {
        let defaults = TestDefaults.make()
        let store = ServicesStore(defaults: defaults, mode: .screenshot)

        XCTAssertTrue(store.isScreenshotMode)
        XCTAssertFalse(store.services.isEmpty)
        XCTAssertTrue(store.groups.contains { $0.isPinnedToMenuBar })
        XCTAssertTrue(store.groups.contains { $0.name == "Freight Ops" })

        let stopped = try XCTUnwrap(store.services.first { $0.name == "Route Worker" })
        XCTAssertEqual(stopped.status, .stopped)

        await store.start(stopped)

        XCTAssertEqual(store.service(withID: stopped.id)?.status, .running)
        XCTAssertNil(defaults.object(forKey: "vini.groups"))
        XCTAssertNil(defaults.object(forKey: "vini.userDefinitions"))
    }

    @MainActor
    func testScreenshotModeUsesInMemoryLogs() async throws {
        let store = ServicesStore(defaults: TestDefaults.make(), mode: .screenshot)
        let service = try XCTUnwrap(store.services.first { $0.name == "API Gateway" })

        let session = await store.makeLogSession(for: service)
        session.start()

        XCTAssertFalse(session.isFileBacked)
        XCTAssertTrue(session.text.contains("API listening"))
        XCTAssertTrue(store.hasLogs(for: service))
    }
}

// MARK: - Hide / surface / delete filtering

final class ServicesStoreFilterTests: XCTestCase {

    private func makeService(
        id: String,
        kind: ServiceKind,
        isCatalogKnown: Bool
    ) -> ViniService {
        ViniService(
            id: id,
            name: id,
            kind: kind,
            pid: nil,
            port: nil,
            status: .stopped,
            iconSystemName: "gearshape.2",
            isCatalogKnown: isCatalogKnown
        )
    }

    @MainActor
    private func freshStore() -> ServicesStore {
        ServicesStore(defaults: TestDefaults.make())
    }

    @MainActor
    func testCatalogServiceShownByDefaultUnlistedHidden() {
        let store = freshStore()
        let known = makeService(id: "brew:redis", kind: .homebrew(formula: "redis"), isCatalogKnown: true)
        let unlisted = makeService(id: "brew:obscure", kind: .homebrew(formula: "obscure"), isCatalogKnown: false)
        store._setDiscoveredForTesting([known, unlisted])

        XCTAssertEqual(store.services.map(\.id), ["brew:redis"])
        XCTAssertEqual(store.unlistedServices.map(\.id), ["brew:obscure"])
        XCTAssertTrue(store.hiddenCatalogServices.isEmpty)
    }

    @MainActor
    func testHideRemovesFromMainListAndAppearsInManage() {
        let store = freshStore()
        let known = makeService(id: "brew:redis", kind: .homebrew(formula: "redis"), isCatalogKnown: true)
        store._setDiscoveredForTesting([known])

        store.hide(known)
        XCTAssertTrue(store.services.isEmpty)
        XCTAssertEqual(store.hiddenCatalogServices.map(\.id), ["brew:redis"])

        store.unhide(id: "brew:redis")
        XCTAssertEqual(store.services.map(\.id), ["brew:redis"])
    }

    @MainActor
    func testSurfaceMovesUnlistedIntoMainList() {
        let store = freshStore()
        let unlisted = makeService(id: "brew:obscure", kind: .homebrew(formula: "obscure"), isCatalogKnown: false)
        store._setDiscoveredForTesting([unlisted])

        XCTAssertTrue(store.services.isEmpty)
        store.surface(id: "brew:obscure")
        XCTAssertEqual(store.services.map(\.id), ["brew:obscure"])
        XCTAssertTrue(store.unlistedServices.isEmpty)

        store.unsurface(unlisted)
        XCTAssertTrue(store.services.isEmpty)
        XCTAssertEqual(store.unlistedServices.map(\.id), ["brew:obscure"])
    }

    @MainActor
    func testDeleteUserDefinedRemovesDefinition() {
        let store = freshStore()
        let def = UserServiceDefinition(name: "My API", startCommand: "echo start")
        store.addUserDefinition(def)
        XCTAssertEqual(store.userDefinitions.count, 1)

        let service = makeService(
            id: "user:\(def.id.uuidString)",
            kind: .userDefined(definition: def),
            isCatalogKnown: true
        )
        store.delete(service)
        XCTAssertTrue(store.userDefinitions.isEmpty)
    }

    @MainActor
    func testUserDefinitionsPersistAcrossStoreInstances() {
        let defaults = TestDefaults.make()
        let storeA = ServicesStore(defaults: defaults)
        let def = UserServiceDefinition(name: "Persisted API", startCommand: "npm run dev")
        storeA.addUserDefinition(def)

        // A brand new store instance must load the saved definition.
        let storeB = ServicesStore(defaults: defaults)
        XCTAssertEqual(storeB.userDefinitions.map(\.name), ["Persisted API"])
    }

    @MainActor
    func testHiddenIDsPersistAcrossStoreInstances() {
        let defaults = TestDefaults.make()
        let storeA = ServicesStore(defaults: defaults)
        let svc = makeService(id: "brew:redis", kind: .homebrew(formula: "redis"), isCatalogKnown: true)
        storeA._setDiscoveredForTesting([svc])
        storeA.hide(svc)

        let storeB = ServicesStore(defaults: defaults)
        XCTAssertTrue(storeB.hiddenServiceIDs.contains("brew:redis"))
    }
}

// MARK: - Groups

final class ServiceGroupTests: XCTestCase {

    @MainActor
    private func freshStore() -> ServicesStore {
        ServicesStore(defaults: TestDefaults.make())
    }

    @MainActor
    func testGroupCRUD() {
        let store = freshStore()
        var group = ServiceGroup(name: "Backend", mode: .simultaneous, memberServiceIDs: ["brew:redis"])
        store.addGroup(group)
        XCTAssertEqual(store.groups.count, 1)

        group.name = "Backend stack"
        store.updateGroup(group)
        XCTAssertEqual(store.groups.first?.name, "Backend stack")

        store.removeGroup(id: group.id)
        XCTAssertTrue(store.groups.isEmpty)
    }

    @MainActor
    func testMembersResolveInOrder() {
        let store = freshStore()
        let redis = ViniService(id: "brew:redis", name: "Redis", kind: .homebrew(formula: "redis"), pid: nil, port: nil, status: .stopped, iconSystemName: "memorychip")
        let pg = ViniService(id: "brew:postgresql@17", name: "PostgreSQL", kind: .homebrew(formula: "postgresql@17"), pid: nil, port: nil, status: .stopped, iconSystemName: "cylinder.fill")
        store._setDiscoveredForTesting([pg, redis])

        let group = ServiceGroup(name: "Stack", mode: .sequenced, memberServiceIDs: ["brew:redis", "brew:postgresql@17"])
        let members = store.members(of: group)
        XCTAssertEqual(members.map(\.id), ["brew:redis", "brew:postgresql@17"])
    }

    @MainActor
    func testBulkUserDefinitionsCanCreateGroup() {
        let store = freshStore()
        let dev = UserServiceDefinition(name: "dev", startCommand: "npm run dev")
        let start = UserServiceDefinition(name: "start", startCommand: "npm run start")

        store.addUserDefinitions([dev, start], groupedUnder: "app")

        XCTAssertEqual(store.userDefinitions.map(\.name), ["dev", "start"])
        XCTAssertEqual(store.groups.map(\.name), ["app"])
        XCTAssertEqual(store.groups.first?.memberServiceIDs, ["user:\(dev.id.uuidString)", "user:\(start.id.uuidString)"])
    }

    @MainActor
    func testMoveMemberRemovesPreviousMemberships() {
        let store = freshStore()
        let a = ServiceGroup(name: "A", memberServiceIDs: ["brew:redis"])
        let b = ServiceGroup(name: "B")
        store.addGroup(a)
        store.addGroup(b)

        store.moveMember("brew:redis", toGroup: b.id)

        XCTAssertEqual(store.group(withID: a.id)?.memberServiceIDs, [])
        XCTAssertEqual(store.group(withID: b.id)?.memberServiceIDs, ["brew:redis"])
    }

    @MainActor
    func testMoveMemberCanInsertBeforeTarget() {
        let store = freshStore()
        let group = ServiceGroup(name: "A", memberServiceIDs: ["brew:redis", "brew:pg"])
        store.addGroup(group)

        store.moveMember("brew:api", toGroup: group.id, beforeMemberID: "brew:pg")

        XCTAssertEqual(store.group(withID: group.id)?.memberServiceIDs, ["brew:redis", "brew:api", "brew:pg"])
    }

    @MainActor
    func testMoveServiceToUngroupedUpdatesServiceOrder() {
        let store = freshStore()
        let group = ServiceGroup(name: "A", memberServiceIDs: ["brew:redis"])
        store.addGroup(group)

        store.moveMember("brew:redis", toGroup: nil, beforeMemberID: "brew:pg")

        XCTAssertEqual(store.group(withID: group.id)?.memberServiceIDs, [])
        XCTAssertEqual(store.serviceOrderIDs, ["brew:redis"])
    }

    @MainActor
    func testMoveTopLevelGroupReordersGroups() {
        let store = freshStore()
        let a = ServiceGroup(name: "A")
        let b = ServiceGroup(name: "B")
        store.addGroup(a)
        store.addGroup(b)

        store.moveGroup(b.id, before: a.id)

        XCTAssertEqual(store.groups.map(\.name), ["B", "A"])
    }

    @MainActor
    func testDuplicateMemberPreservesPreviousMemberships() {
        let store = freshStore()
        let a = ServiceGroup(name: "A", memberServiceIDs: ["brew:redis"])
        let b = ServiceGroup(name: "B")
        store.addGroup(a)
        store.addGroup(b)

        store.addMember("brew:redis", toGroup: b.id)

        XCTAssertEqual(store.group(withID: a.id)?.memberServiceIDs, ["brew:redis"])
        XCTAssertEqual(store.group(withID: b.id)?.memberServiceIDs, ["brew:redis"])
    }

    func testGroupDecodesDefaultsForOlderSavedPayloads() throws {
        let id = UUID()
        let json = """
        [{
          "id": "\(id.uuidString)",
          "name": "Stack",
          "mode": "simultaneous",
          "memberServiceIDs": ["brew:redis"],
          "stopOnFailure": true,
          "iconSystemName": "server.rack"
        }]
        """.data(using: .utf8)!

        let groups = try JSONDecoder().decode([ServiceGroup].self, from: json)

        XCTAssertEqual(groups.first?.iconSystemName, "server.rack")
        XCTAssertEqual(groups.first?.isPinnedToMenuBar, false)
    }

    func testSimultaneousAndSequencedModeMetadata() {
        XCTAssertEqual(ServiceGroupMode.simultaneous.displayLabel, "Simultaneous")
        XCTAssertEqual(ServiceGroupMode.sequenced.displayLabel, "Sequenced")
    }
}
