import XCTest
@testable import GlowTopCore

/// §11.1's UID filter, the `nobody` trap, `pw_gecos` first-field extraction, `ut_type`
/// filtering -- all pure, run from fixture rows with no real `getpwent`/`getutxent` call.
final class UsersReaderTests: XCTestCase {
    // MARK: - Accounts

    func testNobodyIsExcludedDespitePassingTheUidFloor() {
        // `nobody`'s `pw_uid` is -2, which read through the unsigned `uid_t` is 4294967294 --
        // passes a bare `>= 500` and must still be excluded.
        XCTAssertFalse(UsersReader.isRealAccount(uid: uid_t(bitPattern: -2)))
        XCTAssertTrue(UsersReader.isRealAccount(uid: 501))
        XCTAssertTrue(UsersReader.isRealAccount(uid: 0))
        XCTAssertFalse(UsersReader.isRealAccount(uid: 499))
    }

    func testDuplicatePasswdEntriesAreDeduped() {
        let raw = [
            UsersReader.RawAccount(name: "nobody", uid: uid_t(bitPattern: -2), gid: 0, gecos: "", homeDirectory: "/var/empty", shell: "/usr/bin/false"),
            UsersReader.RawAccount(name: "nobody", uid: uid_t(bitPattern: -2), gid: 0, gecos: "", homeDirectory: "/var/empty", shell: "/usr/bin/false"),
            UsersReader.RawAccount(name: "jappleseed", uid: 501, gid: 20, gecos: "J Appleseed,,,", homeDirectory: "/Users/jappleseed", shell: "/bin/zsh"),
        ]
        let accounts = UsersReader.project(raw, admins: ["jappleseed"], groupName: { _ in "staff" })
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts[0].name, "jappleseed")
    }

    func testGecosTakesOnlyTheFirstField() {
        XCTAssertEqual(UsersReader.firstGecosField("J Appleseed,,,"), "J Appleseed")
        XCTAssertEqual(UsersReader.firstGecosField("Solo Name"), "Solo Name")
        XCTAssertEqual(UsersReader.firstGecosField(""), "")
    }

    func testAdminMembershipComesFromTheGroupList() {
        let raw = [
            UsersReader.RawAccount(name: "jappleseed", uid: 501, gid: 20, gecos: "J Appleseed", homeDirectory: "/Users/jappleseed", shell: "/bin/zsh"),
            UsersReader.RawAccount(name: "test", uid: 502, gid: 20, gecos: "Test User", homeDirectory: "/Users/test", shell: "/bin/zsh"),
        ]
        let accounts = UsersReader.project(raw, admins: ["root", "jappleseed"], groupName: { _ in "staff" })
        XCTAssertEqual(accounts.first(where: { $0.name == "jappleseed" })?.admin, true)
        XCTAssertEqual(accounts.first(where: { $0.name == "test" })?.admin, false)
    }

    // MARK: - Sessions

    func testOnlyUserProcessRecordsAreSessions() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let raw = [
            UsersReader.RawSession(user: "", line: "", host: "", type: Int16(BOOT_TIME), epochSeconds: 900_000),
            UsersReader.RawSession(user: "", line: "", host: "", type: Int16(DEAD_PROCESS), epochSeconds: 900_000),
            UsersReader.RawSession(user: "jappleseed", line: "console", host: "", type: Int16(USER_PROCESS), epochSeconds: 999_000),
        ]
        let sessions = UsersReader.project(raw, now: now)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].user, "jappleseed")
    }

    func testRemoteSessionDetectedFromNonEmptyHost() {
        XCTAssertEqual(UsersReader.sessionKind(line: "console", host: ""), .console)
        XCTAssertEqual(UsersReader.sessionKind(line: "ttys000", host: ""), .terminal)
        XCTAssertEqual(UsersReader.sessionKind(line: "ttys001", host: "10.0.0.5"), .remote)
    }
}
