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

    func testIconHeuristics() {
        XCTAssertEqual(ServiceDiscovery.icon(forName: "postgresql"), "cylinder.fill")
        XCTAssertEqual(ServiceDiscovery.icon(forName: "redis"), "memorychip")
        XCTAssertEqual(ServiceDiscovery.icon(forName: "nginx"), "network")
    }
}

