import Foundation

/// SPEC.md §10.2's seven columns, one row per configured launchd job.
public struct LaunchdJob: Sendable, Equatable {
    public let label: String
    public let type: String
    public let program: String
    public let runAtLoad: Bool?
    /// `nil` when the plist carries no `KeepAlive` key. Otherwise `"true"`/`"false"` for the
    /// boolean form or the dictionary's sorted keys joined with `", "` -- §10.2's "boolean or
    /// dictionary summary", never a bare `true` for a dictionary that says more than that.
    public let keepAlive: String?
    public let path: String
    /// `disposition`-style Enabled column (§10.3): reflects state, is never a control.
    public let enabled: Bool?
    /// §12's correlation needs the full argument list, not just its first element.
    public let programArguments: [String]

    public init(
        label: String, type: String, program: String, runAtLoad: Bool?,
        keepAlive: String?, path: String, enabled: Bool?, programArguments: [String]
    ) {
        self.label = label
        self.type = type
        self.program = program
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.path = path
        self.enabled = enabled
        self.programArguments = programArguments
    }
}

/// §10.1's three plist sources, decoded. `footerNotes` carries §10.4's "unreadable directory"
/// disclosures -- the pane renders them, never swallows them.
public struct LaunchdInventory: Sendable, Equatable {
    public let jobs: [LaunchdJob]
    public let footerNotes: [String]

    public init(jobs: [LaunchdJob], footerNotes: [String]) {
        self.jobs = jobs
        self.footerNotes = footerNotes
    }
}

/// §10.1, §10.2, §10.4. Shared by the Startup Apps pane (§10) and the Services inventory
/// (§12) -- one reader, two panes, so they cannot disagree about what is configured.
public enum LaunchdReader {
    /// §10.1's three sources, in order, with their §10.1 type strings verbatim.
    public static var defaultSources: [(url: URL, type: String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            (home.appendingPathComponent("Library/LaunchAgents"), "Launch Agent"),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), "Launch Agent (system)"),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), "Launch Daemon"),
        ]
    }

    public static func read(
        sources: [(url: URL, type: String)] = defaultSources, overrides: [String: Bool] = [:]
    ) -> LaunchdInventory {
        var jobs: [LaunchdJob] = []
        var footerNotes: [String] = []

        for source in sources {
            let directory = source.url
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ) else {
                // §10.4: an unreadable directory contributes no rows and names itself in the
                // footer, rather than a silently shorter list.
                footerNotes.append("\(directory.path) is unreadable")
                continue
            }

            for file in contents.filter({ $0.pathExtension == "plist" }).sorted(by: { $0.path < $1.path }) {
                jobs.append(job(at: file, type: source.type, overrides: overrides))
            }
        }

        return LaunchdInventory(jobs: jobs, footerNotes: footerNotes)
    }

    private static func job(at file: URL, type: String, overrides: [String: Bool]) -> LaunchdJob {
        let stem = file.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: file),
              let raw = try? PropertyListDecoder().decode(RawJob.self, from: data)
        else {
            // §10.4: a malformed plist is a visible row, never a `continue`d one -- the one
            // launch agent macOS itself cannot parse is exactly the row worth seeing.
            return LaunchdJob(
                label: stem, type: "Unparseable", program: "", runAtLoad: nil,
                keepAlive: nil, path: file.path, enabled: nil, programArguments: []
            )
        }

        let arguments = raw.ProgramArguments ?? []
        let program = raw.Program ?? arguments.first ?? ""

        return LaunchdJob(
            label: raw.Label ?? stem,
            type: type,
            program: program,
            runAtLoad: raw.RunAtLoad,
            keepAlive: raw.KeepAlive?.summary,
            path: file.path,
            // §14.4: the override store wins over the plist's own `Disabled` key, because
            // launchd honours the store -- `launchctl disable` never touches the plist.
            enabled: overrides[raw.Label ?? stem].map { !$0 } ?? !(raw.Disabled ?? false),
            programArguments: arguments
        )
    }
}

/// Decodes only the keys §10.2 and §12 read. Every other key in a real launchd plist is
/// ignored by `Decodable`'s own rule, not filtered here.
private struct RawJob: Decodable {
    let Label: String?
    let Program: String?
    let ProgramArguments: [String]?
    let RunAtLoad: Bool?
    let Disabled: Bool?
    let KeepAlive: KeepAliveValue?
}

/// launchd's own schema: `KeepAlive` is a bare boolean **or** a dictionary of condition keys
/// (`SuccessfulExit`, `NetworkState`, ...). Decoding straight to `Bool` with `try?` would read
/// every dictionary form as `nil` -- roughly a third of real agents use it.
private enum KeepAliveValue: Decodable {
    case bool(Bool)
    case dictionaryKeys([String])

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(), let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
            return
        }
        let keyed = try decoder.container(keyedBy: DynamicKey.self)
        self = .dictionaryKeys(keyed.allKeys.map(\.stringValue).sorted())
    }

    /// `nil` for the boolean form: §10.2's column is a string, and the boolean is rendered
    /// as `"true"`/`"false"` by the one place that already knows which case it decoded --
    /// callers use `RawJob.KeepAlive` directly for that, `summary` only for the dictionary form.
    var summary: String? {
        switch self {
        case .bool(let value): return value ? "true" : "false"
        case .dictionaryKeys(let keys): return keys.joined(separator: ", ")
        }
    }
}

private struct DynamicKey: CodingKey {
    var stringValue: String
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}
