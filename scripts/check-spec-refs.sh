#!/bin/bash
# Gate 13 (SPEC.md §13.7): every section citation resolves to a heading in SPEC.md.
#
# Sources: every "§N.N" or "SPEC N.N" citation in SPEC.md, the planning records when present,
# CLAUDE.md, and scripts/*.sh, plus the "Spec §" column of the §14.8 traceability table. A
# citation to a section that does not exist is a reading that measures nothing — §13.1.4–13.1.6
# were cited across three commits before they were written, and the planning state record cited
# §13.1.9 before it existed (§13.7.1).
#
#   scripts/check-spec-refs.sh [path/to/SPEC.md]
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
spec=${1:-"$root/SPEC.md"}

headings=$(grep -E '^#{2,5} [0-9]+(\.[0-9]+)* ' "$spec" | sed -E 's/^#+ ([0-9.]+) .*/\1/' | sort -u)
# Convention: §13.7.N cites shipping gate N, a numbered list item under §13.7, not a heading.
gates=$(awk '/^### 13\.7 /,/^#### 13\.7\.1 /' "$spec" | grep -oE '^[0-9]+\. \*\*' | tr -dc '0-9\n' | sed 's/^/13.7./')
headings=$(printf '%s\n%s\n' "$headings" "$gates")

# Every citation as file:line:ref. Literal alternation, no "?", so it also works in the C locale.
sources=$(printf '%s\n' "$spec" "$root/CLAUDE.md" "$root"/scripts/*.sh; [ -d "$root/.planning" ] && find "$root/.planning" -name '*.md')
cited=$(IFS=$'\n'; grep -noE '(SPEC §|SPEC |§)[0-9]+(\.[0-9]+)*' $sources | sed -E 's/:(SPEC §|SPEC |§)([0-9])/:\2/')
table=$(awk -F'|' '/^### 14\.8/,/^### 14\.9/ { print $3 }' "$spec" | tr ',' '\n' | tr -d ' ' \
        | grep -E '^[0-9]+(\.[0-9]+)*$' | sed "s|^|$spec:§14.8 table:|")
all=$(printf '%s\n%s\n' "$cited" "$table")

missing=0
for ref in $(awk -F: '{ print $NF }' <<< "$all" | sort -u); do
    if ! grep -qx "$ref" <<< "$headings"; then
        where=$(grep -E ":${ref//./\\.}$" <<< "$all" | head -1 | cut -d: -f1,2 | sed "s|^$root/||")
        echo "unresolved: §$ref (first cited at ${where:-?})"
        missing=$((missing + 1))
    fi
done

if [ "$missing" -eq 0 ]; then echo "spec refs: PASS"; else echo "spec refs: $missing unresolved"; exit 1; fi
