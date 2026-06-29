import XCTest
@testable import Lemon

final class OpenCodeClientTests: XCTestCase {
    func testBaseURLUsesHostAndPort() {
        let client = OpenCodeClient(host: "127.0.0.1", port: 4096)
        XCTAssertEqual(client.baseURL.absoluteString, "http://127.0.0.1:4096")
    }

    func testBaseURLSupportsCustomHostPort() {
        let client = OpenCodeClient(host: "localhost", port: 5001)
        XCTAssertEqual(client.baseURL.absoluteString, "http://localhost:5001")
    }
}
