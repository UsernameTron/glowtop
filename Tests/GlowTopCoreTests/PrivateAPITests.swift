import XCTest
@testable import GlowTopCore

/// SPEC.md §13.7.3's flag and §5.0.5's vocabulary. Run twice by 1.1's own `Expected` list --
/// once plain, once as `GLOWTOP_DISABLE_PRIVATE=1 swift test --filter PrivateAPITests` -- so
/// both the open path and the flag path are exercised in the same suite.
final class PrivateAPITests: XCTestCase {
    /// `PrivateAPI.disabled` is a `static let`: mutating the environment after the first
    /// read must never change the second. A computed property would pass this test only by
    /// accident of timing; a `static let` passes it structurally.
    func testDisabledFlagIsReadOncePerProcess() {
        let first = PrivateAPI.disabled
        if first {
            unsetenv("GLOWTOP_DISABLE_PRIVATE")
        } else {
            setenv("GLOWTOP_DISABLE_PRIVATE", "1", 1)
        }
        defer {
            if first { setenv("GLOWTOP_DISABLE_PRIVATE", "1", 1) } else { unsetenv("GLOWTOP_DISABLE_PRIVATE") }
        }
        let second = PrivateAPI.disabled
        XCTAssertEqual(first, second)
    }

    /// Only meaningful under the `GLOWTOP_DISABLE_PRIVATE=1` run named above; the plain run
    /// skips it rather than asserting the opposite, since `handle` is not guaranteed non-nil
    /// on every machine even with the flag off.
    func testHandleReturnsNilWhenDisabled() throws {
        guard PrivateAPI.disabled else {
            throw XCTSkip("run with GLOWTOP_DISABLE_PRIVATE=1 to exercise the short-circuit")
        }
        XCTAssertNil(PrivateLib.handle(.ioReport))
        XCTAssertNil(PrivateLib.handle(.ioKit))
    }

    func testSymbolReturnsNilOnNilHandle() {
        let missing = PrivateLib.symbol(
            "glowtop_symbol_that_does_not_exist", in: .ioReport, as: (@convention(c) () -> Void).self
        )
        XCTAssertNil(missing)
    }

    func testDisabledReasonIsInTheClosedVocabulary() {
        XCTAssertEqual(PrivateAPI.disabledReason, "private APIs disabled")
    }
}
