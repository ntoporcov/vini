import XCTest
@testable import Mbappe

final class ServicesStoreTests: XCTestCase {
    @MainActor
    func testInitialState() {
        let store = ServicesStore()
        XCTAssertTrue(store.services.isEmpty)
        XCTAssertFalse(store.isRefreshing)
        XCTAssertNil(store.lastRefreshError)
    }
}
