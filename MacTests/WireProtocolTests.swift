import XCTest

final class WireProtocolTests: XCTestCase {
    func testFrameStartPasses() {
        XCTAssertTrue(WireProtocol.startsFrame(Data([0, 0, 0, 42, 0x7B])))
        XCTAssertTrue(WireProtocol.startsFrame(Data([0, 0x40, 0, 0])))   // a 4 MB keyframe
        XCTAssertTrue(WireProtocol.startsFrame(Data([0, 0])))            // too short to judge
    }

    /// A web check sends an HTTP request; it must not take over a session.
    func testHTTPRequestIsNoFrame() {
        XCTAssertFalse(WireProtocol.startsFrame(Data("GET / HTTP/1.1\r\n".utf8)))
        XCTAssertFalse(WireProtocol.startsFrame(Data("HEAD / HTTP/1.1\r\n".utf8)))
        XCTAssertFalse(WireProtocol.startsFrame(Data([0, 0, 0, 0])))
    }
}
