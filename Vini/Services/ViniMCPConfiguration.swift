import Foundation

enum ViniMCPConfiguration {
    static let socketFileName = "mcp.sock"

    static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Vini", isDirectory: true)
    }

    static var socketURL: URL {
        applicationSupportDirectory.appendingPathComponent(socketFileName, isDirectory: false)
    }

    static var socketPath: String {
        socketURL.path
    }

    static var relayExecutablePath: String {
        if let path = Bundle.main.path(forAuxiliaryExecutable: "ViniMCP") {
            return path
        }
        return Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("ViniMCP", isDirectory: false)
            .path
    }

    static var clientConfigurationJSON: String {
        let escapedPath = relayExecutablePath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {
          "mcpServers": {
            "vini": {
              "command": "\(escapedPath)"
            }
          }
        }
        """
    }
}
