import Foundation

/// SPEC.md §4.9. One set of rules, applied everywhere, so no two panes format the same
/// quantity differently. Pure string math with no `NumberFormatter`: every rule here is
/// fixed-width and locale-independent by design — a monitor that renders `18,4 GB` on a
/// German machine and `18.4 GB` on an American one has two presentations of one number.
public enum Format {
    /// §4.9: unknown is an em dash, never `0` and never an empty string. Rendering a missing
    /// reading as zero is how a monitor lies (§4.8).
    public static let unknown = "—"

    // MARK: - Percentage

    /// 1 decimal, always, with `%` and no space. Takes a fraction in 0...1, which is the
    /// convention every provider payload uses for utilization.
    public static func percent(fraction: Double) -> String {
        percent(points: fraction * 100)
    }

    /// 1 decimal, always, with `%` and no space. Takes points already on a 0...100 scale.
    /// Values above 100 are expected and correct for per-process CPU, where a process
    /// saturating all 14 cores reads 1400 % (§5.5.2) — this must not clamp.
    public static func percent(points: Double) -> String {
        String(format: "%.1f%%", points)
    }

    // MARK: - Bytes

    private static let byteUnits = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// Base-1024, 1 decimal at GB and above, 0 decimals below (§4.9).
    ///
    /// The labels are `KB`/`MB`/`GB` over the SI-correct `KiB`, matching Activity Monitor so
    /// the two tools agree on the same screen. §4.9 calls this "a deliberate wrongness" and
    /// says so here so it is not "fixed" later by accident.
    ///
    /// A trailing `.0` is dropped, which is what reproduces §4.9's own three examples:
    /// `512 KB`, `18.4 GB`, and `128 GB` — the last would otherwise read `128.0 GB`.
    public static func bytes(_ count: UInt64) -> String {
        let (mantissa, unit) = scale(Double(count), by: 1024)
        // "GB and above" is index 3 in the unit table.
        guard let index = byteUnits.firstIndex(of: unit), index >= 3 else {
            return "\(Int(mantissa.rounded())) \(unit)"
        }
        return "\(trimmed(mantissa, decimals: 1)) \(unit)"
    }

    /// Base-1024, auto-scaled so the mantissa stays in 1–999, 1 decimal (§4.9).
    ///
    /// Bytes per second carry no decimal: §4.9's own example is `948 B/s`, not `948.0 B/s`,
    /// and a fractional byte is not a thing. Scaled units get their decimal.
    public static func byteRate(_ bytesPerSecond: Double) -> String {
        let (mantissa, unit) = scale(max(0, bytesPerSecond), by: 1024)
        if unit == "B" { return "\(Int(mantissa.rounded())) B/s" }
        return "\(trimmed(mantissa, decimals: 1)) \(unit)/s"
    }

    private static func scale(_ value: Double, by base: Double) -> (Double, String) {
        var mantissa = value
        var index = 0
        while mantissa >= base, index < byteUnits.count - 1 {
            mantissa /= base
            index += 1
        }
        return (mantissa, byteUnits[index])
    }

    // MARK: - Physical quantities

    /// 1 decimal, `°C` after a non-breaking space so a tile never wraps between the number
    /// and its unit (§4.9).
    public static func temperature(celsius: Double) -> String {
        String(format: "%.1f\u{00A0}°C", celsius)
    }

    /// 1 decimal, `W` after a regular space (§4.9).
    public static func power(watts: Double) -> String {
        String(format: "%.1f W", watts)
    }

    /// 0 decimals in MHz below 1000, 2 decimals in GHz at or above (§4.9).
    public static func frequency(megahertz: Double) -> String {
        if megahertz < 1000 { return "\(Int(megahertz.rounded())) MHz" }
        return String(format: "%.2f GHz", megahertz / 1000)
    }

    // MARK: - Duration and count

    /// `1d 4h`, `4h 12m`, `12m 30s`, `30.4s` (§4.9) — two units at most, largest first, and
    /// the smaller unit truncated rather than rounded so a duration never reads as longer
    /// than it is.
    public static func duration(seconds: Double) -> String {
        let total = max(0, seconds)
        if total >= 86_400 {
            let days = Int(total / 86_400)
            return "\(days)d \(Int((total - Double(days) * 86_400) / 3600))h"
        }
        if total >= 3600 {
            let hours = Int(total / 3600)
            return "\(hours)h \(Int((total - Double(hours) * 3600) / 60))m"
        }
        if total >= 60 {
            let minutes = Int(total / 60)
            return "\(minutes)m \(Int(total - Double(minutes) * 60))s"
        }
        return String(format: "%.1fs", total)
    }

    /// Grouped with thin spaces above 9999, ungrouped at or below (§4.9): `1138`, `12 400`.
    /// A thin space rather than a comma keeps the column monospaced-friendly and sidesteps
    /// the comma-versus-period question entirely.
    public static func count(_ value: Int) -> String {
        let digits = String(value.magnitude)
        let sign = value < 0 ? "-" : ""
        guard value.magnitude > 9999 else { return sign + digits }

        var grouped: [String] = []
        var remaining = Substring(digits)
        while remaining.count > 3 {
            grouped.append(String(remaining.suffix(3)))
            remaining = remaining.dropLast(3)
        }
        grouped.append(String(remaining))
        return sign + grouped.reversed().joined(separator: "\u{2009}")
    }

    // MARK: - Shared

    /// Rounds to `decimals` places and drops a trailing `.0`, so `128.0` prints as `128`.
    private static func trimmed(_ value: Double, decimals: Int) -> String {
        let text = String(format: "%.\(decimals)f", value)
        guard text.hasSuffix(".0") else { return text }
        return String(text.dropLast(2))
    }
}
