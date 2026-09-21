import Foundation

/// SPEC.md §12's configured-jobs inventory. `launchctl` stdout is never parsed (§12.1's
/// permanent ruling, §14.9's 2026-08-25 approval) -- the inventory comes from two sources:
/// `LaunchdReader`'s jobs (one reader, two panes, so §10 and §12 cannot disagree about what is
/// configured) and §5.5's process snapshot for running-state correlation. `SMAppService` was
/// §12.1's third source and never surfaced anything: it can only answer for an identifier the
/// caller already holds, i.e. GlowTop itself. Its unused accessor left in 1.1.3.
public struct ServiceRow: Sendable, Equatable {
    /// §12.2's three states, decided here from data, never guessed in a view (§7.1).
    public enum Status: String, Sendable, Equatable {
        case running = "Running"
        case configured = "Configured"
        case unknown = "Unknown"
    }

    public let label: String
    public let type: String
    public let program: String
    public let path: String
    public let status: Status
    public let pid: Int32?
    public let cpuText: String
    public let memoryText: String

    public init(
        label: String, type: String, program: String, path: String,
        status: Status, pid: Int32?, cpuText: String, memoryText: String
    ) {
        self.label = label
        self.type = type
        self.program = program
        self.path = path
        self.status = status
        self.pid = pid
        self.cpuText = cpuText
        self.memoryText = memoryText
    }
}

public enum ServicesModel {
    /// Correlates `jobs` against `processes` by **full executable path**, never basename
    /// (§12.1's own rule -- a basename match pairs every `python3` job to whatever `python3`
    /// happens to be running and shows one process's numbers under another job's label).
    public static func correlate(jobs: [LaunchdJob], processes: [ProcessRow]) -> [ServiceRow] {
        var byPath: [String: ProcessRow] = [:]
        for row in processes {
            guard let path = row.path, byPath[path] == nil else { continue }
            byPath[path] = row
        }

        // Homebrew installs under Cellar/ and symlinks from opt/ -- a job's Program is the
        // opt/ symlink while `proc_pidpath` on the live process (§5.5's process table, above
        // in `byPath`) already names the resolved Cellar/ path. Resolve the job side only:
        // `proc_pidpath` names the vnode, not the symlink that reached it, so resolving both
        // sides is a redundant filesystem walk per process per second (§12.1, 4.1). Cached by
        // raw string -- at most a few dozen jobs, and plists do not change between ticks.
        var resolvedPrograms: [String: String] = [:]
        func resolved(_ program: String) -> String {
            if let cached = resolvedPrograms[program] { return cached }
            let path = URL(fileURLWithPath: program).resolvingSymlinksInPath().path
            resolvedPrograms[program] = path
            return path
        }

        // A job invoked as an interpreter plus a script (`ProgramArguments: [/bin/bash,
        // script.sh]`) has `program == "/bin/bash"` -- §12.1's own literal rule ("Program, or
        // the first element of ProgramArguments"). When more than one configured job shares
        // that same bare interpreter path, one live interpreter process cannot be attributed
        // to a specific one of them: matching anyway would show whatever `/bin/bash` happens
        // to be running (any shell, not necessarily that job's) as "Running" under every job
        // that shares the string, and the label's numbers would belong to a process that may
        // have nothing to do with it. Found live on this machine's three cron-style agents,
        // all launched via `/bin/bash <script>`. The guard counts **resolved** programs, not
        // raw ones -- two jobs whose different symlinks resolve to one binary are exactly the
        // ambiguity it exists for, and counting the raw strings would let both match.
        let programCounts = jobs.reduce(into: [String: Int]()) { $0[resolved($1.program), default: 0] += 1 }

        let rows = jobs.map { job -> ServiceRow in
            let resolvedProgram = resolved(job.program)
            let matched = programCounts[resolvedProgram] == 1 ? byPath[resolvedProgram] : nil
            let status = statusFor(job: job, matched: matched)
            return ServiceRow(
                label: job.label, type: job.type, program: job.program, path: job.path,
                status: status, pid: matched?.pid,
                cpuText: matched?.cpuPercent.map { Format.percent(points: $0) } ?? Format.unknown,
                memoryText: matched.map { Format.bytes($0.residentBytes) } ?? Format.unknown
            )
        }
        return sortStatusThenLabel(rows)
    }

    /// §12.1's rule, stated in full: a matched PID is `Running`. Without one, a job that
    /// **could plausibly be running invisibly** -- `RunAtLoad: true` (it may have already run
    /// and exited, or still be running) or a `Launch Daemon` (root-owned, and §5.5.1 says
    /// ~40% of PIDs, disproportionately root's, refuse inspection) -- reads `Unknown` rather
    /// than a guessed `Configured`. Anything else genuinely has no signal suggesting it is
    /// running right now, and reads `Configured`.
    static func statusFor(job: LaunchdJob, matched: ProcessRow?) -> ServiceRow.Status {
        if matched != nil { return .running }
        if job.type == "Launch Daemon" || job.runAtLoad == true { return .unknown }
        return .configured
    }

    /// §12.2: sorted by Status (running first), then Label.
    static func sortStatusThenLabel(_ rows: [ServiceRow]) -> [ServiceRow] {
        rows.sorted {
            rank($0.status) != rank(($1.status)) ? rank($0.status) < rank($1.status) : $0.label < $1.label
        }
    }

    private static func rank(_ status: ServiceRow.Status) -> Int {
        switch status {
        case .running: return 0
        case .configured: return 1
        case .unknown: return 2
        }
    }
}
