#!/usr/bin/env bash
#
# Assert every piece of code inside a signed .app carries OUR signature.
#
#     scripts/verify-nested-signatures.sh <path to .app> <team id>
#
# This is the check `codesign --verify --deep --strict` does NOT do. A vendored
# framework that ships pre-signed (Sparkle ships adhoc-signed, and so do the
# four helpers nested inside it) verifies perfectly well on this Mac: the
# signature is valid, it just is not ours. The notary service is the first thing
# in the pipeline to object, which means a build plus a round trip to Apple has
# already been spent by the time anyone finds out.
#
# Walks every nested bundle and dylib under Contents, plus the loose Mach-O
# helpers Sparkle keeps inside its framework, and fails on anything that is
# adhoc-signed, unsigned, or signed by a different team.
set -euo pipefail

APP="${1:-}"
TEAM="${2:-}"

if [ -z "$APP" ] || [ -z "$TEAM" ]; then
    echo "usage: $0 <path to .app> <team id>" >&2
    exit 2
fi

test -d "$APP" || { echo "ERROR: no app bundle at $APP" >&2; exit 1; }

# What counts as a target, and why the list is built this way.
#
# `-prune` stops the walk descending into a bundle once it has been listed:
# codesign checks a bundle as a whole, and its Versions/Current symlink would
# otherwise yield the same framework a second time. The cost of pruning is that
# bundles nested INSIDE a framework are never reached, which is exactly where
# Sparkle keeps its helpers, so those are named explicitly below.
#
# Resource-only bundles are skipped. Several Flutter plugins ship a `.bundle`
# holding nothing but assets (no Contents/MacOS, no Mach-O anywhere), and macOS
# neither signs nor requires a signature on those: they carry no code to run.
# Flagging them would make this check cry wolf on every build. A code bundle is
# recognised the way the OS recognises one, by having an executable in
# Contents/MacOS (or, for a framework, a binary under Versions/Current).
carries_code() {
    local target="$1"
    case "$target" in
        *.framework)
            # Frameworks name their binary after themselves.
            local name
            name="$(basename "$target" .framework)"
            [ -f "$target/Versions/Current/$name" ] || [ -f "$target/$name" ]
            ;;
        *.dylib)
            return 0 ;;
        *)
            # .app, .xpc, .bundle: a code bundle has an executable in Contents/MacOS.
            [ -n "$(find "$target/Contents/MacOS" -maxdepth 1 -type f -print -quit 2>/dev/null)" ]
            ;;
    esac
}

collect_targets() {
    find "$APP/Contents" \
        \( -name "*.framework" -o -name "*.app" -o -name "*.xpc" -o -name "*.bundle" \) \
        -print -prune
    find "$APP/Contents" -name "*.dylib" -print

    # Sparkle's own nested code, unreachable above because the walk prunes at
    # Sparkle.framework. Each is listed only when present, so this script stays
    # correct for a bundle built without Sparkle and for a future Sparkle that
    # drops its XPC services.
    local sparkle="$APP/Contents/Frameworks/Sparkle.framework/Versions/Current"
    if [ -d "$sparkle" ]; then
        for nested in XPCServices/Downloader.xpc XPCServices/Installer.xpc \
                      Updater.app Autoupdate Sparkle; do
            if [ -e "$sparkle/$nested" ]; then echo "$sparkle/$nested"; fi
        done
    fi

    # The app itself, last: its own signature is the one Gatekeeper reads first.
    echo "$APP"
}

problems=()
checked=0
skipped=0   # resource-only bundles, which hold no code to sign

while IFS= read -r target; do
    [ -n "$target" ] || continue
    if ! carries_code "$target"; then
        skipped=$((skipped + 1))
        continue
    fi
    checked=$((checked + 1))
    info="$(codesign -dv --verbose=2 "$target" 2>&1 || true)"
    case "$info" in
        *"code object is not signed at all"*)
            problems+=("unsigned:     $target") ;;
        *"Signature=adhoc"*)
            problems+=("adhoc:        $target") ;;
        *"TeamIdentifier=$TEAM"*)
            ;;
        *)
            problems+=("wrong team:   $target") ;;
    esac
done < <(collect_targets)

if [ ${#problems[@]} -gt 0 ]; then
    echo "ERROR: $((${#problems[@]})) of $checked signatures in the bundle are not $TEAM:" >&2
    printf '  %s\n' "${problems[@]}" >&2
    cat >&2 <<'EOF'

       Notarization rejects a bundle containing code signed by anyone else, so
       every nested binary has to be re-signed with the Developer ID identity.
       Vendored frameworks are the usual cause: Sparkle, for one, ships
       adhoc-signed along with its XPC services, Updater.app and Autoupdate.
       See SIGN_SPARKLE_HELPERS in the Makefile for how those are handled, and
       extend it if this names something new.
EOF
    exit 1
fi

echo "  $checked signatures checked, all $TEAM ($skipped resource-only bundles skipped)."
