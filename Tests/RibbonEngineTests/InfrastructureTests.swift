import XCTest
import RibbonCore
@testable import RibbonEngine

final class InfrastructureTests: XCTestCase {
    func testFileSessionStoreRoundTripsAndToleratesGarbage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ribbon-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nested/session.json")
        let store = FileSessionStore(url: url)
        XCTAssertNil(store.load(), "missing file")
        let snapshot = SessionSnapshot(world: World(strips: [StripKey(displayUUID: "A", spaceID: 1): makeStrip([1, 2])]),
                                       signatures: [1: WindowSignature(bundleID: "x", title: "t")])
        store.save(snapshot)
        XCTAssertEqual(store.load(), snapshot)
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(store.load(), "corrupt file is ignored, not fatal")
        XCTAssertTrue(FileSessionStore.defaultURL().path.hasSuffix("Ribbon/session.json"))
    }

    func testMainQueueSchedulerRunsAndCancels() {
        let scheduler = MainQueueScheduler()
        let ran = expectation(description: "runs")
        var cancelledRan = false
        let start = scheduler.now()
        let token = scheduler.schedule(after: 0.01) { cancelledRan = true }
        token.cancel()
        scheduler.schedule(after: 0.02) { ran.fulfill() }
        wait(for: [ran], timeout: 2)
        XCTAssertFalse(cancelledRan)
        XCTAssertGreaterThanOrEqual(scheduler.now() - start, 0.02)
    }
}
