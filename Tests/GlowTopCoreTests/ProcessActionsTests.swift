import XCTest
@testable import GlowTopCore

/// SPEC.md §8.5: the guardrails, the errno vocabulary, the log-line format and its escaping.
/// No process is signalled by any test here — `attempt(_:)` itself is exercised on
/// `sleep 1000` only, in phase-04's plan 2.4 and 5.3.
final class ProcessActionsTests: XCTestCase {
    func testGuardrailBlocksPidZeroAndOne() {
        XCTAssertTrue(ProcessActions.guardrail(pid: 0))
        XCTAssertTrue(ProcessActions.guardrail(pid: 1))
        XCTAssertFalse(ProcessActions.guardrail(pid: 2))
    }

    func testGuardrailBlocksNegativePid() {
        // A negative PID is a process *group* to `kill(2)` — not a thing GlowTop offers.
        XCTAssertTrue(ProcessActions.guardrail(pid: -1))
        XCTAssertTrue(ProcessActions.guardrail(pid: -100))
    }

    /// Both of §8.5's own example lines, reproduced character for character from their inputs.
    func testLogLineMatchesSpecExampleExactly() throws {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]

        let first = try XCTUnwrap(formatter.date(from: "2026-08-25T14:32:07Z"))
        XCTAssertEqual(
            ProcessActions.logLine(timestamp: first, pid: 48213, name: "Google Chrome Helper",
                                    signal: .term, uid: 501, result: .ok),
            #"2026-08-25T14:32:07Z KILL pid=48213 name="Google Chrome Helper" signal=SIGTERM uid=501 result=ok"#
        )

        let second = try XCTUnwrap(formatter.date(from: "2026-08-25T14:33:11Z"))
        XCTAssertEqual(
            ProcessActions.logLine(timestamp: second, pid: 1, name: "launchd",
                                    signal: .term, uid: 0, result: .blockedGuardrail),
            #"2026-08-25T14:33:11Z KILL pid=1 name="launchd" signal=SIGTERM uid=0 result=blocked-guardrail"#
        )
    }

    /// A `"` becomes `'`; a control character or newline is dropped — one process named
    /// `foo" result=ok` must not write a log line that lies about its own fields.
    func testLogLineEscapesQuotesInName() {
        let name = "foo\"bar\ncontrol\u{07}end"
        let line = ProcessActions.logLine(
            timestamp: Date(timeIntervalSince1970: 0), pid: 99, name: name,
            signal: .kill, uid: 501, result: .ok
        )
        XCTAssertTrue(line.contains(#"name="foo'barcontrolend""#), line)
        XCTAssertFalse(line.contains("\n"))
    }

    func testResultVocabularyIsClosed() {
        XCTAssertEqual(KillResult.ok.rawValue, "ok")
        XCTAssertEqual(KillResult.blockedGuardrail.rawValue, "blocked-guardrail")
        XCTAssertEqual(KillResult.eperm.rawValue, "eperm")
        XCTAssertEqual(KillResult.esrch.rawValue, "esrch")
        XCTAssertEqual(KillResult.failed(13).rawValue, "failed:13")
    }

    func testEsrchHasNoUserFacingMessage() {
        XCTAssertNil(ProcessActions.userMessage(for: .esrch))
        XCTAssertEqual(ProcessActions.userMessage(for: .eperm),
                        "Not permitted — this process belongs to another user or the system.")
    }

    /// Guards against `FileManager.createFile` on every call, which truncates. Two calls must
    /// produce two lines in the file, in order — not one line that always wins.
    func testAppendIsAdditive() throws {
        let marker = UUID().uuidString
        // A temp file, not `ProcessActions.logURL`: this suite used to append two lines to the
        // user's real action log on every run, and 70 lines of that debris had accumulated
        // beside the 8 genuine KILL records that are PROC-03's evidence.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("glowtop-actions-\(marker).log")
        defer { try? FileManager.default.removeItem(at: url) }

        ProcessActions.append("line-one-\(marker)", to: url)
        ProcessActions.append("line-two-\(marker)", to: url)

        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.split(separator: "\n").map(String.init)
        let firstIndex = try XCTUnwrap(lines.firstIndex(of: "line-one-\(marker)"))
        let secondIndex = try XCTUnwrap(lines.firstIndex(of: "line-two-\(marker)"))
        XCTAssertLessThan(firstIndex, secondIndex)
    }
}
