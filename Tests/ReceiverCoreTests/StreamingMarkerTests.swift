import XCTest
@testable import ReceiverCore

final class StreamingMarkerTests: XCTestCase {
    func testTouchRemoveAndStaleness() {
        let path = NSTemporaryDirectory() + "synccast-marker-\(UUID().uuidString)"
        defer { StreamingMarker.remove(at: path) }
        XCTAssertFalse(StreamingMarker.isFresh(at: path))
        StreamingMarker.touch(at: path)
        XCTAssertTrue(StreamingMarker.isFresh(at: path))
        XCTAssertFalse(StreamingMarker.isFresh(at: path, now: Date().addingTimeInterval(StreamingMarker.staleSeconds + 1)),
                       "a marker the daemon stopped refreshing must go stale")
        StreamingMarker.touch(at: path)
        XCTAssertTrue(StreamingMarker.isFresh(at: path))
        StreamingMarker.remove(at: path)
        XCTAssertFalse(StreamingMarker.isFresh(at: path))
    }
}
