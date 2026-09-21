import XCTest
@testable import GlowTopCore

/// 4.2's timeboxed investigation took outcome B (see `LoginItemsReader.swift`'s own record):
/// `.unavailable` on every call, never a partial list.
final class LoginItemsReaderTests: XCTestCase {
    func testReadIsAlwaysUnavailable() {
        guard case .unavailable(let reason) = LoginItemsReader.read() else {
            return XCTFail("expected .unavailable")
        }
        XCTAssertEqual(reason, "unsupported on this Mac")
    }
}
