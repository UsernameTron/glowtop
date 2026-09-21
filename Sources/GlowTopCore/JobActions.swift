import Darwin
import Foundation

/// SPEC.md §14.4 — the deferred halves of §10 and §12: enable/disable a launch agent, start/stop
/// a service, all in the `gui/<uid>` domain. The only `Process` call site in `GlowTopCore` is the
/// private `run(_:)` below; every public verb is a fixed argv, never a passthrough (ACT-07).
public enum JobVerb: String, Sendable, CaseIterable {
    case enable, disable, start, stop

    /// §14.4's log word: `ENABLE`, `DISABLE`, `START`, `STOP`.
    public var logWord: String { rawValue.uppercased() }
}

/// §14.4's closed `result=` vocabulary (D-09) — the state the poll **observed**, never the
/// API's own return value.
public enum JobResult: Sendable, Equatable {
    case enabled
    case disabled
    case started
    case stopped
    case blockedGuardrail
    case failed(Int32)
    case failedTimeout

    public var rawValue: String {
        switch self {
        case .enabled: return "enabled"
        case .disabled: return "disabled"
        case .started: return "started"
        case .stopped: return "stopped"
        case .blockedGuardrail: return "blocked-guardrail"
        case .failed(let code): return "failed:\(code)"
        case .failedTimeout: return "failed:timeout"
        }
    }
}

/// One verb call's full result: what `logLine` recorded, and the pid the poll last observed
/// (present only for `started`, and for a `failedTimeout` a relaunched `KeepAlive` job produced).
public struct JobOutcome: Sendable, Equatable {
    public let result: JobResult
    public let pid: Int32?
    public let logLine: String

    public init(result: JobResult, pid: Int32?, logLine: String) {
        self.result = result
        self.pid = pid
        self.logLine = logLine
    }
}

/// Whether a menu item should be offered at all, before the function is ever called (layer 1 of
/// D-03's two-layer guardrail). The function itself re-checks independently (layer 2) — this
/// enum is advisory to the UI, never load-bearing on its own.
public enum JobActionability: Sendable, Equatable {
    case actionable
    case readOnly(tooltip: String)
    case denied
}

public enum JobActions {
    /// §14.4's two read-only tooltips, verbatim. `Launch Agent` (the user's own
    /// `~/Library/LaunchAgents`) is the only type left actionable; `Launch Daemon` and
    /// `Launch Agent (system)` are read-only for this phase (D-08, flagged for Connor).
    public static func actionability(of job: LaunchdJob) -> JobActionability {
        switch job.type {
        case "Launch Daemon":
            return .readOnly(tooltip:
                "Read-only — this job runs as root in the system domain, and GlowTop never asks for root.")
        case "Launch Agent (system)":
            return .readOnly(tooltip:
                "Read-only — installed for every user by a package; only jobs in your own ~/Library/LaunchAgents can be changed here.")
        default:
            return guardrail(job) ? .denied : .actionable
        }
    }

    /// D-12's deny-list, four entries. `ownExecutablePath` defaults to the *calling* process's
    /// own executable (`GlowTopApp` in the app, `glowtop-probe` in the probe — O-2, F-10) and is
    /// overridable so a fixture can exercise the third entry without a real binary match.
    /// `com.glowtop.GlowTop` is an **exact** label match, never a `com.glowtop.` prefix, so the
    /// throwaway `com.glowtop.phase14-test` stays actionable.
    public static func guardrail(
        _ job: LaunchdJob,
        ownExecutablePath: String? = Bundle.main.executableURL?.resolvingSymlinksInPath().path
    ) -> Bool {
        if job.label.hasPrefix("com.apple.") { return true }
        if job.label == "com.glowtop.GlowTop" { return true }
        if let ownExecutablePath, !job.program.isEmpty, job.program == ownExecutablePath { return true }
        if job.type == "Unparseable" { return true }
        // No `Label` key: the reader fell back to the plist's own file stem (this Mac's two
        // Google Keystone plists are empty dictionaries) -- `LaunchdJob` carries no flag for
        // this, so the shape is detected from what it already has, never a new field.
        let stem = URL(fileURLWithPath: job.path).deletingPathExtension().lastPathComponent
        if job.label == stem && job.program.isEmpty { return true }
        return false
    }

    /// §8.5's format extended with §14.4's verb word: one line, `pid=` appended only when a pid
    /// was observed. `label` is escaped by the same rule a process name is (D-01).
    public static func logLine(
        timestamp: Date, verb: JobVerb, label: String, uid: uid_t, result: JobResult, pid: Int32?
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        let ts = formatter.string(from: timestamp)
        var line = "\(ts) \(verb.logWord) label=\"\(ProcessActions.escapeLogField(label))\" "
            + "domain=gui/\(uid) result=\(result.rawValue)"
        if let pid {
            line += " pid=\(pid)"
        }
        return line
    }

    /// The sheet's own text, pure and unit-tested -- `JobActionSheet` (3.1) computes no string
    /// of its own, so the sheet and this log can never disagree about what the action was.
    public static func sheetText(for job: LaunchdJob, verb: JobVerb) -> (messageText: String, informativeText: String) {
        let messageText = "\(verb.rawValue.capitalized) \(job.label)?"
        let runsAtLoad = job.runAtLoad.map { $0 ? "Yes" : "No" } ?? Format.unknown
        let path = (job.path as NSString).abbreviatingWithTildeInPath
        var lines = ["\(job.type) · \(path) · runs at load: \(runsAtLoad)"]

        switch verb {
        case .enable:
            lines.append("This runs launchctl enable and loads the job now. It will run again at login.")
            if job.runAtLoad == true {
                lines.append("Enabling starts it now.")
            }
        case .disable:
            lines.append(
                "This runs launchctl disable and unloads the job now. It will not run again at login until it is enabled."
            )
        case .start:
            lines.append("This runs launchctl kickstart and starts the job now.")
        case .stop:
            lines.append("This runs launchctl kill TERM and stops the running process now.")
            if let keepAlive = job.keepAlive, keepAlive != "false" {
                lines.append(
                    "KeepAlive is set — launchd will relaunch it. To keep it stopped, disable it in Startup Apps."
                )
            }
        }

        return (messageText, lines.joined(separator: "\n\n"))
    }

    // MARK: - The four verbs (§14.4's table, verbatim argv)

    public static func enable(_ job: LaunchdJob, uid: uid_t = getuid()) -> JobOutcome {
        perform(.enable, job: job, uid: uid) { uid, label, plistPath in
            let enabled = run(["enable", "gui/\(uid)/\(label)"])
            if enabled.status != 0 { return enabled.status }
            let check = run(["print", "gui/\(uid)/\(label)"])
            if check.status == 113 {
                let bootstrapped = run(["bootstrap", "gui/\(uid)", plistPath])
                if bootstrapped.status != 0 { return bootstrapped.status }
            }
            return nil
        } interpret: { loaded, _ in
            loaded ? (.enabled, nil) : nil
        }
    }

    public static func disable(_ job: LaunchdJob, uid: uid_t = getuid()) -> JobOutcome {
        perform(.disable, job: job, uid: uid) { uid, label, _ in
            let disabled = run(["disable", "gui/\(uid)/\(label)"])
            if disabled.status != 0 { return disabled.status }
            let check = run(["print", "gui/\(uid)/\(label)"])
            if check.status == 0 {
                let booted = run(["bootout", "gui/\(uid)/\(label)"])
                if booted.status != 0 { return booted.status }
            }
            return nil
        } interpret: { loaded, _ in
            loaded ? nil : (.disabled, nil)
        }
    }

    public static func start(_ job: LaunchdJob, uid: uid_t = getuid()) -> JobOutcome {
        perform(.start, job: job, uid: uid) { uid, label, plistPath in
            let check = run(["print", "gui/\(uid)/\(label)"])
            if check.status == 113 {
                let bootstrapped = run(["bootstrap", "gui/\(uid)", plistPath])
                if bootstrapped.status != 0 { return bootstrapped.status }
            }
            let kickstarted = run(["kickstart", "gui/\(uid)/\(label)"])
            if kickstarted.status != 0 { return kickstarted.status }
            return nil
        } interpret: { _, pid in
            pid.map { (.started, $0) }
        }
    }

    public static func stop(_ job: LaunchdJob, uid: uid_t = getuid()) -> JobOutcome {
        perform(.stop, job: job, uid: uid) { uid, label, _ in
            let killed = run(["kill", "TERM", "gui/\(uid)/\(label)"])
            return killed.status == 0 ? nil : killed.status
        } interpret: { _, pid in
            pid == nil ? (.stopped, nil) : nil
        }
    }

    // MARK: - The shared skeleton

    /// Refuse-and-log (both guardrail layers collapse to one `result=`, O-3), run the verb's
    /// fixed argv sequence, poll, log the observed result -- in a `defer`-adjacent shape so no
    /// return path skips the log line (`ProcessActions.attempt`'s discipline, D-01).
    ///
    /// - `sequence` runs the verb's launchctl calls in order and returns the first non-zero
    ///   exit code, or `nil` once every call in the sequence has exited 0.
    /// - `interpret` reads one poll's `(loaded, pid)` and returns the verb's result once its own
    ///   success condition is met, or `nil` to keep polling.
    private static func perform(
        _ verb: JobVerb, job: LaunchdJob, uid: uid_t,
        sequence: (_ uid: uid_t, _ label: String, _ plistPath: String) -> Int32?,
        interpret: (_ loaded: Bool, _ pid: Int32?) -> (JobResult, Int32?)?
    ) -> JobOutcome {
        let timestamp = Date()
        let result: JobResult
        let pid: Int32?

        switch actionability(of: job) {
        case .readOnly, .denied:
            result = .blockedGuardrail
            pid = nil
        case .actionable:
            if let code = sequence(uid, job.label, job.path) {
                result = .failed(code)
                pid = nil
            } else {
                var lastPid: Int32?
                var matched: (JobResult, Int32?)?
                var elapsed = 0.0
                while true {
                    let observed = poll(label: job.label, uid: uid)
                    lastPid = observed.pid
                    if let found = interpret(observed.loaded, observed.pid) {
                        matched = found
                        break
                    }
                    if elapsed >= 5.0 { break }
                    Thread.sleep(forTimeInterval: 0.5)
                    elapsed += 0.5
                }
                if let matched {
                    result = matched.0
                    pid = matched.1
                } else {
                    result = .failedTimeout
                    pid = lastPid
                }
            }
        }

        let line = logLine(timestamp: timestamp, verb: verb, label: job.label, uid: uid, result: result, pid: pid)
        ProcessActions.append(line)
        return JobOutcome(result: result, pid: pid, logLine: line)
    }

    /// `launchctl print gui/<uid>/<label>` -- §14.4's poll. The contract with its stdout is
    /// exactly this and nothing more: the exit status (`0` loaded, `113` not) and the **first**
    /// `pid = ` line at **one** tab of indentation; a nested block's own `pid =`/`state =` sits
    /// at two tabs or more and is never read as the job's own (Phase 0, pass 1 step 4).
    /// `started` keys on this `pid =` line, never on `state = running` -- `xpcproxy` shows
    /// transiently between `kickstart` and the pid's arrival.
    private static func poll(label: String, uid: uid_t) -> (loaded: Bool, pid: Int32?) {
        let result = run(["print", "gui/\(uid)/\(label)"])
        let loaded = result.status == 0
        var pid: Int32?
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("\tpid = "), !line.hasPrefix("\t\t") else { continue }
            pid = Int32(line.dropFirst("\tpid = ".count).trimmingCharacters(in: .whitespaces))
            break
        }
        return (loaded, pid)
    }

    /// The only `Process` call site in `GlowTopCore`. Fixed argv, no shell, stdout captured and
    /// stderr discarded -- §12.1's ruling against parsing anything beyond this poll's own
    /// two-line contract applies here at the source, not just at the caller.
    private static func run(_ argv: [String]) -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = argv
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
