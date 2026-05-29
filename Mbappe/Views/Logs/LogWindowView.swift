import SwiftUI

/// Identifies a logs window by service. Used as the `WindowGroup` value.
struct LogWindowTarget: Identifiable, Hashable, Codable {
    let serviceID: String
    let serviceName: String
    var id: String { serviceID }
}

/// Standalone resizable logs window content.
struct LogWindowView: View {
    let target: LogWindowTarget
    @EnvironmentObject private var store: ServicesStore
    @StateObject private var session: LogSession

    init(target: LogWindowTarget) {
        self.target = target
        // Default to no live capture; refreshed on appear from ProcessManager.
        _session = StateObject(wrappedValue: LogSession(
            serviceID: target.serviceID,
            serviceName: target.serviceName,
            isLiveCaptureAvailable: false
        ))
    }

    var body: some View {
        LogContentView(session: session, compact: false)
            .frame(minWidth: 480, minHeight: 320)
            .navigationTitle("\(target.serviceName) — Logs")
            .task {
                // Reflect whether this instance owns the process for live capture.
                if let service = store.service(withID: target.serviceID) {
                    session.isLiveCaptureAvailable = await store
                        .makeLogSession(for: service).isLiveCaptureAvailable
                }
            }
    }
}
