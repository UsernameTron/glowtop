import Darwin
import Foundation

/// SPEC.md §11.1's Accounts row.
public struct AccountRow: Sendable, Equatable {
    public let name: String
    /// `pw_gecos`'s first comma-separated field -- the rest is office/phone, not a name.
    public let fullName: String
    public let uid: uid_t
    public let group: String
    public let homeDirectory: String
    public let shell: String
    /// `getgrnam("admin")`'s member list and nothing else -- a user whose *primary* gid is
    /// 80 would not appear here, which §11.1 accepts as a known narrowness.
    public let admin: Bool

    public init(name: String, fullName: String, uid: uid_t, group: String, homeDirectory: String, shell: String, admin: Bool) {
        self.name = name
        self.fullName = fullName
        self.uid = uid
        self.group = group
        self.homeDirectory = homeDirectory
        self.shell = shell
        self.admin = admin
    }
}

/// SPEC.md §11.1's Sessions row.
public struct SessionRow: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case console = "Console"
        case terminal = "terminal"
        case remote = "remote"
    }

    public let user: String
    public let kind: Kind
    public let line: String
    /// Empty for a local session.
    public let host: String
    public let elapsedText: String

    public init(user: String, kind: Kind, line: String, host: String, elapsedText: String) {
        self.user = user
        self.kind = kind
        self.line = line
        self.host = host
        self.elapsedText = elapsedText
    }
}

/// SPEC.md §11.1's two sections: `getpwent`/`getgrnam` accounts and `getutxent` sessions --
/// both **public**, both read-only. §11.1's filter as written (`UID >= 500`) is wrong on this
/// machine's own `getpwent` table (plan-time reconnaissance): `nobody`'s `pw_uid` is `-2`,
/// which read through the unsigned `uid_t` passes `>= 500`, and `getpwent` returns it twice.
/// Both corrections land here rather than being worked around at the call site.
public enum UsersReader {
    // MARK: - Accounts

    struct RawAccount: Equatable {
        let name: String
        let uid: uid_t
        let gid: gid_t
        let gecos: String
        let homeDirectory: String
        let shell: String
    }

    public static func readAccounts() -> [AccountRow] {
        var raw: [RawAccount] = []
        setpwent()
        defer { endpwent() }
        while let entry = getpwent() {
            let pw = entry.pointee
            raw.append(RawAccount(
                name: String(cString: pw.pw_name),
                uid: pw.pw_uid,
                gid: pw.pw_gid,
                gecos: String(cString: pw.pw_gecos),
                homeDirectory: String(cString: pw.pw_dir),
                shell: String(cString: pw.pw_shell)
            ))
        }
        return project(raw, admins: Set(adminGroupMembers()), groupName: groupName(gid:))
    }

    /// Pure: §11.1's UID floor plus the root exception, deduped on `(name, uid)`, mapped
    /// through the caller's group/admin lookups so this stays testable from fixture rows with
    /// no real `getpwent`/`getgrnam` call.
    static func project(
        _ raw: [RawAccount], admins: Set<String>, groupName: (gid_t) -> String?
    ) -> [AccountRow] {
        var seen = Set<String>()
        var result: [AccountRow] = []
        for entry in raw where isRealAccount(uid: entry.uid) {
            let key = "\(entry.name)#\(entry.uid)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(AccountRow(
                name: entry.name,
                fullName: firstGecosField(entry.gecos),
                uid: entry.uid,
                group: groupName(entry.gid) ?? String(entry.gid),
                homeDirectory: entry.homeDirectory,
                shell: entry.shell,
                admin: admins.contains(entry.name)
            ))
        }
        return result
    }

    /// §11.1's floor is "UID >= 500 ... plus root shown explicitly". `nobody`'s `pw_uid` is
    /// `-2`, which read through the unsigned `uid_t` is `4294967294` and passes a bare
    /// `>= 500` -- excluded here by also requiring the value stay below the signed range's
    /// top, which every real account (never allocated anywhere near `UInt32.max`) satisfies.
    static func isRealAccount(uid: uid_t) -> Bool {
        uid == 0 || (uid >= 500 && uid < 0x7FFF_FFFF)
    }

    /// The GECOS field is comma-delimited (full name, office, work phone, home phone); §11.1
    /// wants only the first.
    static func firstGecosField(_ gecos: String) -> String {
        String(gecos.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(gecos))
    }

    private static func groupName(gid: gid_t) -> String? {
        guard let group = getgrgid(gid) else { return nil }
        return String(cString: group.pointee.gr_name)
    }

    private static func adminGroupMembers() -> [String] {
        guard let group = getgrnam("admin"), let members = group.pointee.gr_mem else { return [] }
        var names: [String] = []
        var index = 0
        while let member = members[index] {
            names.append(String(cString: member))
            index += 1
        }
        return names
    }

    // MARK: - Sessions

    struct RawSession: Equatable {
        let user: String
        let line: String
        let host: String
        let type: Int16
        let epochSeconds: Double
    }

    public static func readSessions(now: Date = Date()) -> [SessionRow] {
        var raw: [RawSession] = []
        setutxent()
        defer { endutxent() }
        while let entry = getutxent() {
            let ut = entry.pointee
            raw.append(RawSession(
                user: cString(from: ut.ut_user),
                line: cString(from: ut.ut_line),
                host: cString(from: ut.ut_host),
                type: ut.ut_type,
                epochSeconds: Double(ut.ut_tv.tv_sec) + Double(ut.ut_tv.tv_usec) / 1_000_000
            ))
        }
        return project(raw, now: now)
    }

    /// Pure: §11.1 names `ut_type` and `ut_line` but does not say to filter -- unfiltered,
    /// `getutxent` returns `BOOT_TIME` and `DEAD_PROCESS` records with empty `ut_user`/`ut_line`
    /// alongside the real sessions. Only `USER_PROCESS` records are sessions.
    static func project(_ raw: [RawSession], now: Date) -> [SessionRow] {
        raw.compactMap { entry in
            guard entry.type == USER_PROCESS else { return nil }
            let elapsed = max(0, now.timeIntervalSince1970 - entry.epochSeconds)
            return SessionRow(
                user: entry.user, kind: sessionKind(line: entry.line, host: entry.host),
                line: entry.line, host: entry.host, elapsedText: Format.duration(seconds: elapsed)
            )
        }
    }

    /// `console` -> Console; a tty with no remote host -> terminal; a non-empty host ->
    /// remote -- §11.1's own three-way split, and the row Sessions exists to surface.
    static func sessionKind(line: String, host: String) -> SessionRow.Kind {
        if line == "console" { return .console }
        return host.isEmpty ? .terminal : .remote
    }
}

/// Reads a fixed-size C character array (`ut_user`, `ut_line`, `ut_host`, all imported from
/// `<utmpx.h>` as tuples) as a null-terminated string, with no assumption about which
/// specific tuple arity is bound -- every one of `utmpx`'s fields is contiguous `CChar`
/// storage the same way `ProcessProvider`'s own C buffers already are.
private func cString<T>(from tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        guard let base = raw.baseAddress else { return "" }
        return String(cString: base.assumingMemoryBound(to: CChar.self))
    }
}
