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

