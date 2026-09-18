#!/usr/bin/env bash
#
# Print the CHANGELOG.md section for one version, without its heading.
#
#     scripts/changelog-section.sh <version> [changelog-path]
#
# Sections are Keep a Changelog level-2 headings, "## 1.1.0 - 2026-09-05", so a
# section runs from its own heading to the next "## " line. Exits 1 when the
# version has no section, which lets the caller fall back to generated notes.
set -euo pipefail

VERSION="${1:-}"
CHANGELOG="${2:-CHANGELOG.md}"

if [ -z "$VERSION" ]; then
    echo "usage: $0 <version> [changelog-path]" >&2
    exit 2
fi

test -f "$CHANGELOG" || { echo "ERROR: no such file: $CHANGELOG" >&2; exit 1; }

# Matched by string prefix rather than by regex: a version is full of dots, and
# every one of them would otherwise match any character.
awk -v version="$VERSION" '
    BEGIN { heading = "## " version; n = length(heading); found = 0 }
    !inside && substr($0, 1, n) == heading &&
        (length($0) == n || substr($0, n + 1, 1) == " ") {
        inside = 1; found = 1; next
    }
    inside && substr($0, 1, 3) == "## " { inside = 0 }
    inside { print }
    END { exit found ? 0 : 1 }
' "$CHANGELOG" | sed -e '/./,$!d' | awk '
    # Buffer blank lines and emit them only once more content follows, which
    # drops the run of blanks before the next heading.
    /./ { for (i = 1; i <= held; i++) print ""; held = 0; print; next }
    { held++ }
'
