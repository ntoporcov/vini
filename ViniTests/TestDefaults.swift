import Foundation

enum TestDefaults {
    static func make(file: StaticString = #filePath, line: UInt = #line) -> UserDefaults {
        let suiteName = "com.ntoporcov.vini.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Unable to create test defaults suite", file: file, line: line)
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
