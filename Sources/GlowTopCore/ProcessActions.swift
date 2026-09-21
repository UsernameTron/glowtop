import Darwin
import Foundation

/// SPEC.md §8.5 — the only destructive action in M01, and the only file in the project that
/// calls `kill(2)`. Copied from the spec rather than interpreted: the sheet text, the
/// guardrails, the errno vocabulary and the log-line format are all verbatim.
public enum ProcessActions {
    /// PID 0 (`kernel_task`) and PID 1 (`launchd`) are never killable. `<= 1` also covers a
    /// negative PID, which `kill(2)` reads as a **process group** — not a thing GlowTop offers
    /// and the single worst way this feature could go wrong.
    public static func guardrail(pid: Int32) -> Bool {
        pid <= 1
    }

    /// The only call site of `kill(2)` in the project.
    ///
    /// The guardrail runs first: if it blocks, `kill(2)` is never called at all, and the
    /// block itself is logged as `blocked-guardrail` — §8.5's own example line shows exactly
    /// that entry, so a block is an attempt that gets recorded, not one that gets suppressed.
    ///
    /// The log line is appended on every path out, in a `defer`, so an early return can never
    /// skip it — the same discipline `DiskProvider.readCounters()` applies to a read, applied
    /// here to a write.
    public static func attempt(
        pid: Int32, name: String, uid: uid_t, signal: KillSignal
    ) -> KillResult {
        var result: KillResult = .ok
        defer {
            append(logLine(timestamp: Date(), pid: pid, name: name, signal: signal,
                            uid: uid, result: result))
        }

        guard !guardrail(pid: pid) else {
            result = .blockedGuardrail
            return result
        }

        if kill(pid, signal.rawSignal) == 0 {
            result = .ok
        } else {
            switch errno {
            case EPERM: result = .eperm
            case ESRCH: result = .esrch
            default: result = .failed(errno)
            }
        }
        return result
    }

    /// §8.5's format, character for character:
    /// `2026-08-25T14:32:07Z KILL pid=48213 name="Google Chrome Helper" signal=SIGTERM uid=501 result=ok`
    ///
    /// A static pure function, so the format is testable without a filesystem. Timestamp is
    /// ISO 8601 UTC to whole seconds, no fractional part.
    public static func logLine(
        timestamp: Date, pid: Int32, name: String, signal: KillSignal, uid: uid_t, result: KillResult
    ) -> String {
        // A fresh formatter per call rather than a cached static one: `ISO8601DateFormatter`
        // is not `Sendable`, and a kill is logged a handful of times a day (§8.5) -- nowhere
        // near often enough for the allocation to matter.
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        let ts = formatter.string(from: timestamp)
        return "\(ts) KILL pid=\(pid) name=\"\(escapeLogField(name))\" signal=\(signal.logName) "
            + "uid=\(uid) result=\(result.rawValue)"
    }

    /// A `"` inside a process name becomes `'`; any control character or newline is dropped —
    /// one process named `foo" result=ok` must not write a log line that lies about its own
    /// fields.
    static func escapeLogField(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            if scalar == "\"" {
                scalars.append("'")
            } else if CharacterSet.controlCharacters.contains(scalar) {
                continue
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// `~/Library/Logs/GlowTop/actions.log` — gate 11's one permitted write path outside the
    /// repository.
    public static let logURL: URL =
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/GlowTop/actions.log")

    /// Directory and file created lazily; the file is mode `0600` and append-only, opened for
    /// writing and closed on every call rather than held open — §8.5 says never rotated by the
    /// app, and a held handle is a leaked file descriptor across a 30-minute gate-10 run for a
    /// feature used a handful of times a day.
    ///
    /// Every failure is swallowed: a monitor that cannot write its log still kills the process
    /// the user asked it to, and does not throw a dialog about a log file.
    /// `to` defaults to `logURL`, so the production call site is unchanged and its behaviour is
    /// byte-identical. The parameter exists so the test suite can write to a temp file instead of
    /// appending to the user's real action log (§13.7 gate 11).
    public static func append(_ line: String, to url: URL = logURL) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil,
                                    attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// §8.5's failure strings, verbatim. `ESRCH` has none: the sheet closes silently and the
    /// row is removed, so there is nothing to show the user.
    public static func userMessage(for result: KillResult) -> String? {
        switch result {
        case .eperm: return "Not permitted — this process belongs to another user or the system."
        case .ok, .blockedGuardrail, .esrch, .failed: return nil
        }
    }
}

/// SPEC.md §8.5's `Quit` / `Force Quit` buttons.
public enum KillSignal: Sendable, Equatable {
    case term
    case kill

    public var logName: String {
        switch self {
        case .term: return "SIGTERM"
        case .kill: return "SIGKILL"
        }
    }

    fileprivate var rawSignal: Int32 {
        switch self {
        case .term: return SIGTERM
        case .kill: return SIGKILL
        }
    }
}

/// §8.5's closed result vocabulary, resolved in the plan's discretion table and amended into
/// the spec at 5.2: `ok`, `blocked-guardrail`, `eperm`, `esrch`, plus `failed:<errno>` for
/// anything else `kill(2)` returns. A cancelled sheet produces **no** result and **no** line —
/// it is not an attempt.
public enum KillResult: Sendable, Equatable {
    case ok
    case blockedGuardrail
    case eperm
    case esrch
    case failed(Int32)

    public var rawValue: String {
        switch self {
        case .ok: return "ok"
        case .blockedGuardrail: return "blocked-guardrail"
        case .eperm: return "eperm"
        case .esrch: return "esrch"
        case .failed(let errno): return "failed:\(errno)"
        }
    }
}
