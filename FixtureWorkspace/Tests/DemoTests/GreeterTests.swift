import XCTest
@testable import Demo

final class GreeterTests: XCTestCase {
    func testGreeting() {
        XCTAssertEqual(
            Greeter.message,
            "Hello from Local AI"
        )
    }
}
