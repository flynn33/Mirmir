import XCTest
@testable import Mirmir

final class SecurityScopedAccessTests: XCTestCase {
    func testSuccessfulStartIsStoppedExactlyOnce() {
        var stopCount = 0
        var access: SecurityScopedAccess? = SecurityScopedAccess(
            url: URL(fileURLWithPath: "/tmp/mirmir-scope-test.mov"),
            startAccessing: { _ in true },
            stopAccessing: { _ in stopCount += 1 }
        )

        XCTAssertEqual(access?.didStartAccessing, true)
        access?.stop()
        access?.stop()
        XCTAssertEqual(stopCount, 1)

        access = nil
        XCTAssertEqual(stopCount, 1)
    }

    func testFailedStartIsNeverStopped() {
        var stopCount = 0
        var access: SecurityScopedAccess? = SecurityScopedAccess(
            url: URL(fileURLWithPath: "/tmp/mirmir-scope-test.mov"),
            startAccessing: { _ in false },
            stopAccessing: { _ in stopCount += 1 }
        )

        XCTAssertEqual(access?.didStartAccessing, false)
        access?.stop()
        access = nil
        XCTAssertEqual(stopCount, 0)
    }
}
