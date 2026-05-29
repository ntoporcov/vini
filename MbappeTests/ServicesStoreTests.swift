import XCTest
@testable import Mbappe

final class ServicesStoreTests: XCTestCase {
    @MainActor
    func testInitialState() {
        let store = ServicesStore()
        XCTAssertTrue(store.services.isEmpty)
        XCTAssertFalse(store.isRefreshing)
        XCTAssertNil(store.lastError)
    }

    func testHomebrewServiceIsControllable() {
        let service = MbappeService(
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
        let service = MbappeService(
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
}

// MARK: - Hide / surface / delete filtering

final class ServicesStoreFilterTests: XCTestCase {

    private func makeService(
        id: String,
        kind: ServiceKind,
        isCatalogKnown: Bool
    ) -> MbappeService {
        MbappeService(
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
        // Clear persisted state so tests are deterministic.
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "mbappe.hiddenServiceIDs")
        defaults.removeObject(forKey: "mbappe.surfacedServiceIDs")
        defaults.removeObject(forKey: "mbappe.userDefinitions")
        return ServicesStore()
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
}


