import XCTest
@testable import Vini

final class ServiceDiscoveryDedupeTests: XCTestCase {

    private func service(
        id: String,
        name: String,
        kind: ServiceKind,
        pid: Int?,
        port: Int? = nil
    ) -> ViniService {
        ViniService(
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

    // MARK: - Batched lsof parsing
    //
    // Port discovery used to spawn one `lsof` per catalog port (9+) on every
    // refresh. It now spawns one and parses `-F` machine output.

    func testParsesLsofFieldOutput() {
        let output = """
        p862
        f9
        n*:59500
        f11
        n*:59500
        p993
        f7
        n[::1]:5432
        f8
        n127.0.0.1:5432
        """
        let map = ServiceDiscovery.parseLsofFieldOutput(output)
        XCTAssertEqual(map[59500], 862)
        XCTAssertEqual(map[5432], 993)
        XCTAssertEqual(map.count, 2)
    }

    func testLsofParsingHandlesIPv6AndWildcardAddresses() {
        let map = ServiceDiscovery.parseLsofFieldOutput("p1\nn[::1]:3000\np2\nn*:4000\np3\nn127.0.0.1:5000")
        XCTAssertEqual(map[3000], 1)
        XCTAssertEqual(map[4000], 2)
        XCTAssertEqual(map[5000], 3)
    }

    func testLsofParsingFirstPIDWinsForSharedPort() {
        // Matches the previous `lsof -t | head -1` behaviour.
        let map = ServiceDiscovery.parseLsofFieldOutput("p111\nn*:8080\np222\nn*:8080")
        XCTAssertEqual(map[8080], 111)
    }

    func testLsofParsingIgnoresGarbageAndNamesWithoutPID() {
        XCTAssertTrue(ServiceDiscovery.parseLsofFieldOutput("").isEmpty)
        // `n` before any `p` has no owner, and non-numeric ports are skipped.
        XCTAssertTrue(ServiceDiscovery.parseLsofFieldOutput("n*:3000").isEmpty)
        XCTAssertTrue(ServiceDiscovery.parseLsofFieldOutput("p1\nn*:notaport").isEmpty)
        XCTAssertTrue(ServiceDiscovery.parseLsofFieldOutput("p1\nnnocolon").isEmpty)
    }
}
