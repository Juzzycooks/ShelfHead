import XCTest
@testable import ShelfHead

/// Review Medium 16/17 (30 October 2026).
final class CloudPositionAdoptionTests: XCTestCase {
    func testCloudBehindLocalIsNotAdopted() {
        let cloud = CloudPositionStore.Record(
            currentTime: 100, duration: 3600, updatedAt: Date(timeIntervalSince1970: 2000), deviceName: "d")
        XCTAssertFalse(CloudPositionStore.shouldAdoptCloudPosition(
            cloud: cloud, localCurrentTime: 500, localUpdatedAt: nil, serverReachable: false))
        XCTAssertFalse(CloudPositionStore.shouldAdoptCloudPosition(
            cloud: cloud, localCurrentTime: 500, localUpdatedAt: Date(timeIntervalSince1970: 1000), serverReachable: false))
    }

    func testCloudAheadWithoutLocalTimestampIsAdopted() {
        let cloud = CloudPositionStore.Record(currentTime: 500, duration: 3600, updatedAt: Date(), deviceName: "d")
        XCTAssertTrue(CloudPositionStore.shouldAdoptCloudPosition(
            cloud: cloud, localCurrentTime: 100, localUpdatedAt: nil, serverReachable: false))
    }

    func testCrossDeviceScopeIgnoresSchemeAndCaseButNotUser() {
        let a = CloudPositionStore.crossDeviceScope(serverURL: "https://Books.Example.com", username: "ann")
        let b = CloudPositionStore.crossDeviceScope(serverURL: "http://books.example.com", username: "ann")
        let c = CloudPositionStore.crossDeviceScope(serverURL: "https://books.example.com", username: "bob")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
