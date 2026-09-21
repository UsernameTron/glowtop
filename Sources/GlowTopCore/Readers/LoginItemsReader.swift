import Foundation

/// SPEC.md §10.1's fourth source. 4.2's timeboxed investigation took **outcome B**: nothing is
/// built, and this always reads `.unavailable`. The finding, in full, is recorded in this
/// plan's execution summary rather than named here by its specific store path or tool name --
/// gate 13 resolves every literal path/tool reference in source comments against what the
/// codebase actually touches, and outcome B's whole point is that this codebase touches
/// neither.
///
/// In short: the public unarchiving route this section's original source named returns no
/// result and no error. A private route exists and does decode the underlying store, but at
/// least one record on the reference machine carries an identifier and no name at all --
/// §10.1's own rule is that **every** item must yield both a name and an identifier or the
/// whole read fails, because a partial list is worse than none. That rule is not weakened to
/// make the count look clean; the timebox exists precisely so a marginal result is not argued
/// into a yes by whoever spent the time on it. The would-be cross-check instrument could not
/// be run in this environment either (it requests interactive admin authorization, which
/// §2.4 forbids the app from ever raising) -- independent of, not a cause of, the decision.
public enum LoginItemsReader {
    public enum Result: Sendable, Equatable {
        case unavailable(String)
    }

    /// §5.0.5's reason vocabulary. The SPEC.md §10.1 amendment (landing in wave 5's spec
    /// commit) carries the full explanation; this is the short, fixed string every other
    /// `.unavailable` reading already uses that vocabulary for.
    public static func read() -> Result {
        .unavailable("unsupported on this Mac")
    }
}
