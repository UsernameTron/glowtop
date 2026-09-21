import XCTest
@testable import GlowTopCore

/// SPEC.md §14.5's stable sort, D-13's search and CONN-04's coverage footer -- all pure, so
/// every test here runs against a fixture `ConnectionsSample`, never a live socket table.
final class ConnectionsModelTests: XCTestCase {
    private func row(
        pid: Int32, fd: Int32 = 0, name: String = "proc", transport: SocketRow.Transport = .tcp,
        isIPv6: Bool = false, localAddress: String = "127.0.0.1", localPort: Int = 80,
        remoteAddress: String = "127.0.0.1", remotePort: Int = 1234, tcpState: Int? = 4,
        scopeInterface: String = ""
    ) -> SocketRow {
        SocketRow(
            pid: pid, fd: fd, processName: name, transport: transport, isIPv6: isIPv6,
            localAddress: localAddress, localPort: localPort, remoteAddress: remoteAddress,
            remotePort: remotePort, tcpState: transport == .udp ? nil : tcpState, scopeInterface: scopeInterface
        )
    }

    // MARK: - Stability

    /// 100 rows, all the same `state`, must come back in original order across two sorts.
    func testSortIsStableAcrossEqualValues() {
        let rows = (0..<100).map { row(pid: Int32($0), fd: 0, tcpState: 4) }

        let first = ConnectionsModel.stableSort(rows, key: .state, ascending: false)
        XCTAssertEqual(first.map(\.pid), rows.map(\.pid))

        let second = ConnectionsModel.stableSort(first, key: .state, ascending: false)
        XCTAssertEqual(second.map(\.pid), first.map(\.pid))
    }

    // MARK: - Search (D-13's four fields)

    func testSearchMatchesProcessPidLocalAndRemote() {
        let rows = [
            row(pid: 1138, name: "helper", localAddress: "10.0.0.1", remoteAddress: "93.184.216.34"),
            row(pid: 42, name: "chrome", localAddress: "10.0.0.2", remoteAddress: "1.1.1.1"),
            row(pid: 7, name: "unrelated", localAddress: "10.0.0.3", remoteAddress: "8.8.8.8"),
        ]
        let sample = ConnectionsSample(rows: rows, pidCount: 3, inspectedPIDCount: 3, enumerationMilliseconds: 1)

        let byPid = ConnectionsModel.project(sample, sort: .pid, ascending: true, search: "1138")
        XCTAssertEqual(byPid.rows.map(\.pid), [1138])

        let byProcess = ConnectionsModel.project(sample, sort: .pid, ascending: true, search: "chrome")
        XCTAssertEqual(byProcess.rows.map(\.pid), [42])

        let byLocal = ConnectionsModel.project(sample, sort: .pid, ascending: true, search: "10.0.0.3")
        XCTAssertEqual(byLocal.rows.map(\.pid), [7])

        let byRemote = ConnectionsModel.project(sample, sort: .pid, ascending: true, search: "1.1.1.1")
        XCTAssertEqual(byRemote.rows.map(\.pid), [42])
    }

    // MARK: - The five locked address forms

    func testAddressFormsMatchTheLockedFiveCases() {
        // Wildcard local -- a listener bound to all interfaces -- never `—`.
        let wildcardLocal = row(pid: 1, localAddress: "0.0.0.0", localPort: 8080, remoteAddress: "5.6.7.8", remotePort: 1)
        let wildcardDetail = ConnectionsModel.project(
            ConnectionsSample(rows: [wildcardLocal], pidCount: 1, inspectedPIDCount: 1, enumerationMilliseconds: 1),
            sort: .pid, ascending: true, search: ""
        ).rows[0]
        XCTAssertEqual(wildcardDetail.localText, "*:8080")

        // Unconnected remote -- all-zero address and port 0 -- is `—`.
        let unconnectedRemote = row(pid: 2, localAddress: "10.0.0.1", localPort: 443, remoteAddress: "0.0.0.0", remotePort: 0)
        let unconnectedDetail = ConnectionsModel.project(
            ConnectionsSample(rows: [unconnectedRemote], pidCount: 1, inspectedPIDCount: 1, enumerationMilliseconds: 1),
            sort: .pid, ascending: true, search: ""
        ).rows[0]
        XCTAssertEqual(unconnectedDetail.remoteText, Format.unknown)

        // Plain v4.
        let plainV4 = row(pid: 3, localAddress: "192.168.1.5", localPort: 443, remoteAddress: "1.2.3.4", remotePort: 55)
        let plainV4Detail = ConnectionsModel.project(
            ConnectionsSample(rows: [plainV4], pidCount: 1, inspectedPIDCount: 1, enumerationMilliseconds: 1),
            sort: .pid, ascending: true, search: ""
        ).rows[0]
        XCTAssertEqual(plainV4Detail.localText, "192.168.1.5:443")

        // Bracketed v6, no scope.
        let bracketedV6 = row(
            pid: 4, isIPv6: true, localAddress: "2001:db8::1", localPort: 443,
            remoteAddress: "2001:db8::2", remotePort: 8080
        )
        let bracketedDetail = ConnectionsModel.project(
            ConnectionsSample(rows: [bracketedV6], pidCount: 1, inspectedPIDCount: 1, enumerationMilliseconds: 1),
            sort: .pid, ascending: true, search: ""
        ).rows[0]
        XCTAssertEqual(bracketedDetail.localText, "[2001:db8::1]:443")

        // Link-local v6 with scope -- byte-exact.
        let linkLocal = row(
            pid: 5, isIPv6: true, localAddress: "fe80::1", localPort: 546,
            remoteAddress: "1.2.3.4", remotePort: 1, scopeInterface: "en0"
        )
        let linkLocalDetail = ConnectionsModel.project(
            ConnectionsSample(rows: [linkLocal], pidCount: 1, inspectedPIDCount: 1, enumerationMilliseconds: 1),
            sort: .pid, ascending: true, search: ""
        ).rows[0]
        XCTAssertEqual(linkLocalDetail.localText, "[fe80::1%en0]:546")
    }

    /// The unconnected-remote and wildcard-local forms must never collapse into the same
    /// string even though both start from an all-zero address -- the exact distinction §14.5's
    /// numeric-only rule exists to preserve.
    func testUnconnectedRemoteAndWildcardLocalAreDifferentStrings() {
        let bothZero = row(pid: 1, localAddress: "0.0.0.0", localPort: 8080, remoteAddress: "0.0.0.0", remotePort: 0)
        let detail = ConnectionsModel.project(
            ConnectionsSample(rows: [bothZero], pidCount: 1, inspectedPIDCount: 1, enumerationMilliseconds: 1),
            sort: .pid, ascending: true, search: ""
        ).rows[0]
        XCTAssertEqual(detail.localText, "*:8080")
        XCTAssertEqual(detail.remoteText, Format.unknown)
        XCTAssertNotEqual(detail.localText, detail.remoteText)
    }

    // MARK: - CONN-04's coverage footer

    func testFooterCountsRefusedPIDsWithoutDroppingThem() {
        let rows = [row(pid: 1)]
        let sample = ConnectionsSample(rows: rows, pidCount: 937, inspectedPIDCount: 608, enumerationMilliseconds: 1)
        let model = ConnectionsModel.project(sample, sort: .pid, ascending: true, search: "")
        XCTAssertEqual(model.footerText, "608 of 937 processes inspected · sockets of the other 329 are not listed")
    }

    // MARK: - CONN-04's empty-vs-search distinction

    func testEmptyBodyOnlyAppearsWhenRowsAreGenuinelyEmpty() {
        let emptySample = ConnectionsSample(rows: [], pidCount: 608, inspectedPIDCount: 608, enumerationMilliseconds: 1)
        let emptyModel = ConnectionsModel.project(emptySample, sort: .pid, ascending: true, search: "")
        XCTAssertEqual(emptyModel.emptyBodyText, "No open TCP or UDP sockets among the 608 processes this user can inspect")

        let nonEmptySample = ConnectionsSample(rows: [row(pid: 1)], pidCount: 608, inspectedPIDCount: 608, enumerationMilliseconds: 1)
        let nonEmptyModel = ConnectionsModel.project(nonEmptySample, sort: .pid, ascending: true, search: "")
        XCTAssertEqual(nonEmptyModel.emptyBodyText, "")

        // A search that narrows a non-empty sample to zero rows is not the same as CONN-04's
        // genuine empty state -- the sample itself still had sockets.
        let searchedAway = ConnectionsModel.project(nonEmptySample, sort: .pid, ascending: true, search: "nomatch")
        XCTAssertEqual(searchedAway.rows.count, 0)
        XCTAssertEqual(searchedAway.emptyBodyText, "")
    }

    // MARK: - Format discipline

    func testProjectionUsesFormatAndNotAdHocStringFormatting() throws {
        let path = #filePath.replacingOccurrences(
            of: "Tests/GlowTopCoreTests/ConnectionsModelTests.swift",
            with: "Sources/GlowTopCore/ConnectionsModel.swift"
        )
        XCTAssertTrue(path.hasSuffix("Sources/GlowTopCore/ConnectionsModel.swift"), "re-pointed, not copy-pasted")
        let source = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(source.contains("String(format:"))
        XCTAssertFalse(source.contains("NumberFormatter"))
    }
}
