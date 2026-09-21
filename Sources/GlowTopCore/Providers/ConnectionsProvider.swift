import Darwin
import Foundation

/// SPEC.md §14.5. `libproc`, three calls deep: `proc_listallpids` (the call `ProcessProvider`
/// already makes, finding F-8's PID-count sizing), `proc_pidinfo(PROC_PIDLISTFDS)` per PID
/// (returns **bytes**, the opposite convention -- finding F-8's second half), and
/// `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` per socket descriptor, decoded through XNU's
/// `TSI_S_*` table (finding F-9).
///
/// Deliberately not a `MetricProvider`: this pane samples only while visible (§3.3), and a
/// `ProviderID` case would put a slot in `MetricStore.health()` that reads `.stalled` on
/// every other pane forever after one visit (finding F-3). The contract's substance -- never
/// throws, `.unavailable(reason:)` from §5.0.5's closed list, `Sendable`, no internal locking
/// -- is kept without the protocol.
public struct ConnectionsProvider: Sendable {
    public init() {}

    public mutating func sample() -> Snapshot<ConnectionsSample> {
        let started = ContinuousClock().now
        guard let pids = Self.listPIDs() else {
            return .unavailable(reason: "kernel call failed: proc_listallpids")
        }
        var rows: [SocketRow] = []
        var inspected = 0
        var names: [Int32: String] = [:]
        for pid in pids {
            guard let fds = Self.listFDs(pid: pid) else { continue }
            inspected += 1
            let name = names[pid] ?? ProcessProvider.name(of: pid)
            names[pid] = name
            for fd in fds where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                guard let info = Self.fetchSocketInfo(pid: pid, fd: fd.proc_fd) else { continue }
                guard let row = Self.decode(info, pid: pid, fd: fd.proc_fd, processName: name) else { continue }
                rows.append(row)
            }
        }
        let sample = ConnectionsSample(
            rows: rows, pidCount: pids.count, inspectedPIDCount: inspected,
            enumerationMilliseconds: Self.milliseconds(from: started, to: ContinuousClock().now)
        )
        return .value(sample, timestamp: ContinuousClock().now)
    }

    /// The identical PID-count sizing `ProcessProvider.enumerate` uses (finding F-8): bare
    /// PIDs, no per-PID task info needed here.
    static func listPIDs() -> [Int32]? {
        let listed = proc_listallpids(nil, 0)
        guard listed > 0 else { return nil }
        var pids = [Int32](repeating: 0, count: Int(listed) + 128)
        let filled = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
        guard filled > 0 else { return nil }
        return pids[0..<min(filled, pids.count)].filter { $0 > 0 }
    }

    /// Opposite convention from `proc_listallpids`: this call sizes and fills in **bytes**
    /// (`PROC_PIDLISTFD_SIZE == sizeof(proc_fdinfo)`), not a descriptor count. `nil` for a
    /// PID this process cannot inspect (EPERM) -- skipped, never defaulted (§5.5.1).
    static func listFDs(pid: Int32) -> [proc_fdinfo]? {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return nil }
        let count = Int(bytes) / MemoryLayout<proc_fdinfo>.size
        guard count > 0 else { return nil }
        var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &buffer, bytes)
        guard filled > 0 else { return nil }
        return Array(buffer[0..<min(Int(filled) / MemoryLayout<proc_fdinfo>.size, count)])
    }

    /// The syscall alone -- `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`. Kept separate from
    /// `decode(_:pid:fd:processName:)` so the decode -- the union dispatch, the byte-order
    /// fix, the address/state formatting -- is testable against a hand-built fixture with no
    /// live socket needed.
    static func fetchSocketInfo(pid: Int32, fd: Int32) -> socket_fdinfo? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { return nil }
        return info
    }

    /// Pure decode: dispatches on `soi_kind` (D-04: TCP and UDP over IPv4/IPv6 only -- every
    /// other kind, UNIX/NDRV/kernel event or control/vsock/raw, is skipped and not counted),
    /// then builds numeric addresses and the TCP state.
    static func decode(_ info: socket_fdinfo, pid: Int32, fd: Int32, processName: String) -> SocketRow? {
        let psi = info.psi
        let transport: SocketRow.Transport
        let ini: in_sockinfo
        var tcpState: Int?
        switch Int(psi.soi_kind) {
        case SOCKINFO_TCP:
            transport = .tcp
            ini = psi.soi_proto.pri_tcp.tcpsi_ini
            tcpState = Int(psi.soi_proto.pri_tcp.tcpsi_state)
        case SOCKINFO_IN where psi.soi_protocol == IPPROTO_UDP:
            transport = .udp
            ini = psi.soi_proto.pri_in
        default:
            // Every other kind (UNIX, NDRV, kernel event/control, vsock, raw) is out of scope.
            return nil
        }
        let isIPv6 = (ini.insi_vflag & UInt8(INI_IPV6)) != 0
        let ifindex = ini.insi_v6.in6_ifindex
        let (localAddr, scope) = Self.address(
            ina46: ini.insi_laddr.ina_46, ina6: ini.insi_laddr.ina_6, isIPv6: isIPv6, ifindex: ifindex
        )
        let (remoteAddr, _) = Self.address(
            ina46: ini.insi_faddr.ina_46, ina6: ini.insi_faddr.ina_6, isIPv6: isIPv6, ifindex: ifindex
        )
        return SocketRow(
            pid: pid, fd: fd, processName: processName, transport: transport, isIPv6: isIPv6,
            localAddress: localAddr, localPort: Self.port(ini.insi_lport),
            remoteAddress: remoteAddr, remotePort: Self.port(ini.insi_fport),
            tcpState: tcpState, scopeInterface: scope
        )
    }

    /// `insi_lport`/`insi_fport` are a 16-bit `in_port_t` in network byte order, zero-extended
    /// into a 32-bit `int` field -- truncate to 16 bits first, then convert from network to
    /// host order (`.bigEndian` byte-swaps on this machine's little-endian layout, matching
    /// `ntohs`). Confirmed against a known `LISTEN` port before this file was committed
    /// (2.1's live check, recorded in `## What was built`).
    static func port(_ raw: Int32) -> Int {
        Int(UInt16(truncatingIfNeeded: raw).bigEndian)
    }

    /// D-05: numeric only. `inet_ntop`'s own C string, nothing else -- no resolver call
    /// anywhere in this function or this file. `ifname` resolves a link-local scope from
    /// `in6_ifindex`; every other case returns an empty scope.
    static func address(ina46: in4in6_addr, ina6: in6_addr, isIPv6: Bool, ifindex: UInt16) -> (String, String) {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if isIPv6 {
            var addr = ina6
            guard inet_ntop(AF_INET6, &addr, &buffer, socklen_t(buffer.count)) != nil else { return ("—", "") }
            let text = String(cString: buffer)
            var scope = ""
            if text.hasPrefix("fe80"), ifindex != 0 {
                var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                if if_indextoname(UInt32(ifindex), &nameBuffer) != nil {
                    scope = String(cString: nameBuffer)
                }
            }
            return (text, scope)
        }
        var addr4 = ina46.i46a_addr4
        guard inet_ntop(AF_INET, &addr4, &buffer, socklen_t(buffer.count)) != nil else { return ("—", "") }
        return (String(cString: buffer), "")
    }

    /// D-06: the twelve `TSI_S_*` names, `lsof`'s spelling, in index order 0...11.
    public static func tcpStateName(_ state: Int) -> String {
        let names = [
            "CLOSED", "LISTEN", "SYN_SENT", "SYN_RCVD", "ESTABLISHED", "CLOSE_WAIT",
            "FIN_WAIT_1", "CLOSING", "LAST_ACK", "FIN_WAIT_2", "TIME_WAIT", "RESERVED",
        ]
        return names.indices.contains(state) ? names[state] : "state \(state)"
    }

    private static func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let (seconds, attoseconds) = start.duration(to: end).components
        return Double(seconds) * 1000 + Double(attoseconds) * 1e-15
    }
}
