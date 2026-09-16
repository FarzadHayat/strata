import XCTest
@testable import StrataCore

final class SmokeTests: XCTestCase {
    func testVersion() { XCTAssertFalse(StrataCore.version.isEmpty) }
}
