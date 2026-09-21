import XCTest
@testable import GlowTopCore

/// SPEC.md §14.4: the guardrail, the log line, the sheet text, and the closed `result=`
/// vocabulary -- all pure. **No test here calls `enable`/`disable`/`start`/`stop`, and none
/// spawns `launchctl`**; the four verbs' live behaviour is proved by `glowtop-probe job` against
/// the throwaway agent (4.1), never by a unit test (2026-09-07's blind-click / live-write lesson,
/// generalised).
final class JobActionsTests: XCTestCase {
    private func fixtureJob(
        label: String = "com.example.nightly-report",
        type: String = "Launch Agent",
        program: String = "/usr/bin/true",
        runAtLoad: Bool? = nil,
        keepAlive: String? = nil,
        path: String = NSHomeDirectory() + "/Library/LaunchAgents/com.example.nightly-report.plist"
    ) -> LaunchdJob {
        LaunchdJob(
            label: label, type: type, program: program, runAtLoad: runAtLoad,
            keepAlive: keepAlive, path: path, enabled: true, programArguments: [program]
        )
    }

    // MARK: - logLine, §14.4's three example lines, character for character

    func testLogLineMatchesDisableExample() throws {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        let ts = try XCTUnwrap(formatter.date(from: "2026-09-08T22:41:07Z"))
        XCTAssertEqual(
            JobActions.logLine(timestamp: ts, verb: .disable, label: "com.example.nightly-report", uid: 501, result: .disabled, pid: nil),
            #"2026-09-08T22:41:07Z DISABLE label="com.example.nightly-report" domain=gui/501 result=disabled"#
        )
    }

    func testLogLineMatchesStartExampleWithPid() throws {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        let ts = try XCTUnwrap(formatter.date(from: "2026-09-08T22:42:19Z"))
        XCTAssertEqual(
            JobActions.logLine(timestamp: ts, verb: .start, label: "homebrew.mxcl.redis", uid: 501, result: .started, pid: 2581),
            #"2026-09-08T22:42:19Z START label="homebrew.mxcl.redis" domain=gui/501 result=started pid=2581"#
        )
    }

    func testLogLineMatchesStopBlockedGuardrailExample() throws {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        let ts = try XCTUnwrap(formatter.date(from: "2026-09-08T22:43:02Z"))
        XCTAssertEqual(
            JobActions.logLine(timestamp: ts, verb: .stop, label: "com.apple.Siri.agent", uid: 501, result: .blockedGuardrail, pid: nil),
            #"2026-09-08T22:43:02Z STOP label="com.apple.Siri.agent" domain=gui/501 result=blocked-guardrail"#
        )
    }

    func testLogLinePidSuffixAppearsOnlyWhenObserved() {
        let line = JobActions.logLine(timestamp: Date(timeIntervalSince1970: 0), verb: .stop, label: "x", uid: 501, result: .stopped, pid: nil)
        XCTAssertFalse(line.contains("pid="))
    }

    func testLogLineEscapesQuoteInLabel() {
        let line = JobActions.logLine(
            timestamp: Date(timeIntervalSince1970: 0), verb: .enable, label: "com.x\"y", uid: 501, result: .enabled, pid: nil
        )
        XCTAssertTrue(line.contains(#"label="com.x'y""#), line)
    }

    // MARK: - JobResult's closed vocabulary

    func testJobResultRawValueCoversAllSevenCasesAndNothingElse() {
        XCTAssertEqual(JobResult.enabled.rawValue, "enabled")
        XCTAssertEqual(JobResult.disabled.rawValue, "disabled")
        XCTAssertEqual(JobResult.started.rawValue, "started")
        XCTAssertEqual(JobResult.stopped.rawValue, "stopped")
        XCTAssertEqual(JobResult.blockedGuardrail.rawValue, "blocked-guardrail")
        XCTAssertEqual(JobResult.failed(113).rawValue, "failed:113")
        XCTAssertEqual(JobResult.failedTimeout.rawValue, "failed:timeout")
    }

    // MARK: - The deny-list (D-12), fixture-proved

    func testGuardrailBlocksApplePrefixedLabel() {
        let job = fixtureJob(label: "com.apple.phase14-fixture", type: "Launch Agent")
        XCTAssertTrue(JobActions.guardrail(job))
    }

    func testGuardrailBlocksExactGlowTopLabel() {
        let job = fixtureJob(label: "com.glowtop.GlowTop", type: "Launch Agent")
        XCTAssertTrue(JobActions.guardrail(job))
    }

    func testGuardrailBlocksProgramResolvingToOwnExecutable() {
        let job = fixtureJob(label: "com.example.helper", program: "/Applications/GlowTop.app/Contents/MacOS/GlowTopApp")
        XCTAssertTrue(JobActions.guardrail(job, ownExecutablePath: "/Applications/GlowTop.app/Contents/MacOS/GlowTopApp"))
    }

    func testGuardrailBlocksUnparseableType() {
        let job = fixtureJob(label: "broken", type: "Unparseable", program: "")
        XCTAssertTrue(JobActions.guardrail(job))
    }

    /// The Keystone shape (Phase 0): an empty-dictionary plist decodes with no `Label` key (the
    /// reader falls back to the file stem) and no `Program`.
    func testGuardrailBlocksTheNoLabelKeystoneShape() {
        let job = fixtureJob(
            label: "com.google.keystone.agent", type: "Launch Agent", program: "",
            path: "/Users/jappleseed/Library/LaunchAgents/com.google.keystone.agent.plist"
        )
        XCTAssertTrue(JobActions.guardrail(job))
    }

    /// The one label a session ever writes must stay actionable, or 4.1's acceptance sequence
    /// blocks itself.
    func testGuardrailDoesNotBlockTheThrowawayTestLabel() {
        let job = fixtureJob(
            label: "com.glowtop.phase14-test", type: "Launch Agent", program: "/bin/sleep",
            path: "/Users/jappleseed/Library/LaunchAgents/com.glowtop.phase14-test.plist"
        )
        XCTAssertFalse(JobActions.guardrail(job))
    }

    func testGuardrailDoesNotBlockAnOrdinaryUserAgent() {
        let job = fixtureJob(label: "homebrew.mxcl.redis", type: "Launch Agent", program: "/opt/homebrew/opt/redis/bin/redis-server")
        XCTAssertFalse(JobActions.guardrail(job))
    }

    // MARK: - actionability(of:) -- the domain rule, §14.4's tooltips verbatim

    func testActionabilityReadOnlyForLaunchDaemonWithExactTooltip() {
        let job = fixtureJob(type: "Launch Daemon")
        guard case .readOnly(let tooltip) = JobActions.actionability(of: job) else {
            return XCTFail("expected .readOnly")
        }
        XCTAssertEqual(tooltip, "Read-only — this job runs as root in the system domain, and GlowTop never asks for root.")
    }

    func testActionabilityReadOnlyForLaunchAgentSystemWithExactTooltip() {
        let job = fixtureJob(type: "Launch Agent (system)")
        guard case .readOnly(let tooltip) = JobActions.actionability(of: job) else {
            return XCTFail("expected .readOnly")
        }
        XCTAssertEqual(tooltip, "Read-only — installed for every user by a package; only jobs in your own ~/Library/LaunchAgents can be changed here.")
    }

    func testActionabilityDeniedForAGuardrailMatch() {
        let job = fixtureJob(label: "com.apple.phase14-fixture", type: "Launch Agent")
        XCTAssertEqual(JobActions.actionability(of: job), .denied)
    }

    func testActionabilityActionableForAnOrdinaryUserAgent() {
        let job = fixtureJob(label: "homebrew.mxcl.redis", type: "Launch Agent")
        XCTAssertEqual(JobActions.actionability(of: job), .actionable)
    }

    // MARK: - sheetText(for:verb:) -- the locked strings, computed here and nowhere else

    func testSheetTextForEnableWithRunAtLoadTrueAddsTheStartsNowLine() {
        let job = fixtureJob(runAtLoad: true, path: NSHomeDirectory() + "/Library/LaunchAgents/com.example.nightly-report.plist")
        let text = JobActions.sheetText(for: job, verb: .enable)
        XCTAssertEqual(text.messageText, "Enable com.example.nightly-report?")
        XCTAssertTrue(text.informativeText.contains("Launch Agent · ~/Library/LaunchAgents/com.example.nightly-report.plist · runs at load: Yes"))
        XCTAssertTrue(text.informativeText.contains("It will run again at login."))
        XCTAssertTrue(text.informativeText.contains("Enabling starts it now."))
    }

    func testSheetTextForEnableWithoutRunAtLoadOmitsTheStartsNowLine() {
        let job = fixtureJob(runAtLoad: false)
        let text = JobActions.sheetText(for: job, verb: .enable)
        XCTAssertTrue(text.informativeText.contains("runs at load: No"))
        XCTAssertFalse(text.informativeText.contains("Enabling starts it now."))
    }

    func testSheetTextForEnableRunAtLoadNilRendersAsEmDash() {
        let job = fixtureJob(runAtLoad: nil)
        let text = JobActions.sheetText(for: job, verb: .enable)
        XCTAssertTrue(text.informativeText.contains("runs at load: —"))
    }

    func testSheetTextForDisableMatchesTheLockedSecondLine() {
        let job = fixtureJob()
        let text = JobActions.sheetText(for: job, verb: .disable)
        XCTAssertEqual(text.messageText, "Disable com.example.nightly-report?")
        let expectedSecondLine =
            "This runs launchctl disable and unloads the job now. It will not run again at login until it is enabled."
        XCTAssertTrue(text.informativeText.contains(expectedSecondLine))
    }

    func testSheetTextForStartMatchesTheLockedSecondLine() {
        let job = fixtureJob()
        let text = JobActions.sheetText(for: job, verb: .start)
        XCTAssertEqual(text.messageText, "Start com.example.nightly-report?")
        let expectedSecondLine = "This runs launchctl kickstart and starts the job now."
        XCTAssertTrue(text.informativeText.contains(expectedSecondLine))
    }

    func testSheetTextForStopWithoutKeepAliveOmitsTheRelaunchLine() {
        let job = fixtureJob(keepAlive: nil)
        let text = JobActions.sheetText(for: job, verb: .stop)
        XCTAssertEqual(text.messageText, "Stop com.example.nightly-report?")
        XCTAssertFalse(text.informativeText.contains("KeepAlive is set"))
    }

    func testSheetTextForStopWithKeepAliveFalseOmitsTheRelaunchLine() {
        let job = fixtureJob(keepAlive: "false")
        let text = JobActions.sheetText(for: job, verb: .stop)
        XCTAssertFalse(text.informativeText.contains("KeepAlive is set"))
    }

    func testSheetTextForStopWithKeepAliveTrueAddsTheRelaunchLine() {
        let job = fixtureJob(keepAlive: "true")
        let text = JobActions.sheetText(for: job, verb: .stop)
        let expectedRelaunchLine =
            "KeepAlive is set — launchd will relaunch it. To keep it stopped, disable it in Startup Apps."
        XCTAssertTrue(text.informativeText.contains(expectedRelaunchLine))
    }

    func testSheetTextForStopWithKeepAliveDictionarySummaryAddsTheRelaunchLine() {
        let job = fixtureJob(keepAlive: "NetworkState, SuccessfulExit")
        let text = JobActions.sheetText(for: job, verb: .stop)
        XCTAssertTrue(text.informativeText.contains("KeepAlive is set"))
    }
}
