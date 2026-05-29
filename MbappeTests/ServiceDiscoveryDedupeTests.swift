import XCTest
@testable import Mbappe

final class ServiceDiscoveryDedupeTests: XCTestCase {

    private func service(
        id: String,
        name: String,
        kind: ServiceKind,
        pid: Int?,
        port: Int? = nil
    ) -> MbappeService {
        MbappeService(
            id: id,
            name: name,
            kind: kind,
            pid: pid,
            port: port,
            status: pid != nil ? .running : .stopped,
            iconSystemName: "gearshape.2"
        )
    }

    func testDropsExactIdDuplicates() {
        let a = service(id: "brew:redis", name: "Redis", kind: .homebrew(formula: "redis"), pid: 10)
        let b = service(id: "brew:redis", name: "Redis", kind: .homebrew(formula: "redis"), pid: 10)
        let result = ServiceDiscovery.dedupe([a, b])
        XCTAssertEqual(result.count, 1)
    }

    func testDropsSecondEntryWithSameLivePID() {
        // Same running process reported by two different sources.
        let brew = service(id: "brew:postgresql@17", name: "PostgreSQL", kind: .homebrew(formula: "postgresql@17"), pid: 3593)
        let agent = service(id: "launchd:homebrew.mxcl.postgresql@17", name: "PostgreSQL", kind: .launchAgent(label: "homebrew.mxcl.postgresql@17"), pid: 3593)
        let result = ServiceDiscovery.dedupe([brew, agent])
        XCTAssertEqual(result.count, 1)
    }

    func testControllableEntryWinsOverPortProbeOnSamePID() {
        let port = service(id: "port:5432", name: "PostgreSQL", kind: .portProbe(port: 5432), pid: 3593, port: 5432)
        let brew = service(id: "brew:postgresql@17", name: "PostgreSQL", kind: .homebrew(formula: "postgresql@17"), pid: 3593)
        let result = ServiceDiscovery.dedupe([port, brew])
        XCTAssertEqual(result.count, 1)
        // The controllable (homebrew) entry must be the survivor.
        XCTAssertEqual(result.first?.kind, .homebrew(formula: "postgresql@17"))
    }

    func testNilPIDsAreNotTreatedAsDuplicates() {
        // Two stopped services (both nil pid) must both survive.
        let pg15 = service(id: "brew:postgresql@15", name: "PostgreSQL", kind: .homebrew(formula: "postgresql@15"), pid: nil)
        let pg17 = service(id: "brew:postgresql@17", name: "PostgreSQL", kind: .homebrew(formula: "postgresql@17"), pid: nil)
        let result = ServiceDiscovery.dedupe([pg15, pg17])
        XCTAssertEqual(result.count, 2)
    }

    func testDistinctRunningServicesBothSurvive() {
        let redis = service(id: "brew:redis", name: "Redis", kind: .homebrew(formula: "redis"), pid: 100)
        let pg = service(id: "brew:postgresql@17", name: "PostgreSQL", kind: .homebrew(formula: "postgresql@17"), pid: 200)
        let result = ServiceDiscovery.dedupe([redis, pg])
        XCTAssertEqual(result.count, 2)
    }
}
