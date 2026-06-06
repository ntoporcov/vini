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
    @State private var session: LogSession?

    init(target: LogWindowTarget) {
        self.target = target
    }

    var body: some View {
        Group {
            if let session {
                LogContentView(session: session, compact: false)
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .navigationTitle("\(target.serviceName) — Logs")
        .task(id: target.serviceID) {
            if let service = store.service(withID: target.serviceID) {
                session = await store.makeLogSession(for: service)
            } else {
                session = LogSession(
                    serviceID: target.serviceID,
                    serviceName: target.serviceName,
                    isLiveCaptureAvailable: false,
                    seedText: store.isScreenshotMode ? "" : nil
                )
            }
        }
    }
}
