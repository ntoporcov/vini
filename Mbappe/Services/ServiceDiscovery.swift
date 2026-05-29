import Foundation

/// Discovers running services on the local machine.
/// Replace the stub implementation with real process scanning, launchd querying,
/// or any other discovery mechanism appropriate for your use case.
actor ServiceDiscovery {
    static let shared = ServiceDiscovery()

    private init() {}

    func discover() throws -> [MbappeService] {
        // Stub: returns placeholder services for initial development.
        // TODO: replace with real discovery (e.g. scan launchctl list, known ports, etc.)
        [
            MbappeService(
                id: "com.example.postgres",
                name: "PostgreSQL",
                pid: nil,
                port: 5432,
                status: .unknown,
                iconSystemName: "cylinder.fill"
            ),
            MbappeService(
                id: "com.example.redis",
                name: "Redis",
                pid: nil,
                port: 6379,
                status: .unknown,
                iconSystemName: "memorychip"
            ),
            MbappeService(
                id: "com.example.nginx",
                name: "Nginx",
                pid: nil,
                port: 80,
                status: .unknown,
                iconSystemName: "network"
            ),
        ]
    }
}
