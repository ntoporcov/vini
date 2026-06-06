import Foundation

/// Curated catalog of popular developer services Vini knows about.
///
/// This is the single source of truth for what gets surfaced. Homebrew formulae,
/// launchd labels, and probed ports are all filtered against this list so the menu
/// stays focused on common tools instead of every random brew service.
enum KnownServices {
    /// One catalog entry describing a popular service and how to recognize it.
    struct Entry: Sendable {
        /// Canonical display name, e.g. "PostgreSQL".
        let displayName: String
        /// SF Symbol used in the UI.
        let icon: String
        /// Lowercased substrings that identify this service in a brew formula name
        /// or launchd label (e.g. "postgresql", "postgres").
        let matchTokens: [String]
        /// Default port to probe, if any.
        let port: Int?
    }

    /// The allowlist. Add new popular tools here.
    static let catalog: [Entry] = [
        Entry(displayName: "PostgreSQL", icon: "cylinder.fill", matchTokens: ["postgresql", "postgres"], port: 5432),
        Entry(displayName: "MySQL",      icon: "cylinder.fill", matchTokens: ["mysql"],                  port: 3306),
        Entry(displayName: "MariaDB",    icon: "cylinder.fill", matchTokens: ["mariadb"],                port: 3306),
        Entry(displayName: "Redis",      icon: "memorychip",    matchTokens: ["redis"],                  port: 6379),
        Entry(displayName: "MongoDB",    icon: "leaf.fill",     matchTokens: ["mongodb", "mongo"],       port: 27017),
        Entry(displayName: "Podman",     icon: "shippingbox.fill", matchTokens: ["podman"],              port: nil),
        Entry(displayName: "Nginx",      icon: "network",       matchTokens: ["nginx"],                  port: 80),
        Entry(displayName: "RabbitMQ",   icon: "tray.full",     matchTokens: ["rabbitmq"],               port: 5672),
        Entry(displayName: "Elasticsearch", icon: "magnifyingglass", matchTokens: ["elasticsearch"],     port: 9200),
        Entry(displayName: "Memcached",  icon: "memorychip",    matchTokens: ["memcached"],              port: 11211),
    ]

    /// Match an arbitrary identifier (brew formula or launchd label) to a catalog entry.
    /// Versioned/prefixed names like "postgresql@17" or "homebrew.mxcl.postgresql@17" match.
    static func entry(forIdentifier identifier: String) -> Entry? {
        let lower = identifier.lowercased()
        return catalog.first { entry in
            entry.matchTokens.contains { lower.contains($0) }
        }
    }

    /// Match a listening port to a catalog entry.
    static func entry(forPort port: Int) -> Entry? {
        catalog.first { $0.port == port }
    }
}
