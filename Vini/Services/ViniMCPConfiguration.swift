import Foundation

enum ViniMCPConfiguration {
    static let defaultPort = 45678

    static func serverURL(port: Int) -> String {
        "http://127.0.0.1:\(port)/mcp"
    }

    static func clientConfigurationJSON(port: Int) -> String {
        let url = serverURL(port: port)
        return """
        {
          "type": "remote",
          "url": "\(url)"
        }
        """
    }
}
