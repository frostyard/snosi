#!/bin/bash
# Hard CI gate: shipped systemd units must never use RequiredBy= enablement,
# and payload trees must never ship *.requires/ enablement links.
#
# Why: first boot's preset pass materializes [Install] sections into the
# persistent /etc (the overlay upper on /var for native A/B, the merged
# /etc for bootc). A WantedBy= link that later dangles is harmless, but a
# RequiredBy= link becomes a Requires= on a unit that no longer loads, and
# PID 1's very first transaction — starting default.target — is then
# invalid: the machine dies at "Failed to isolate default target" before
# any service runs and before the journal persists. Retiring such a unit
# from the image therefore bricks every install whose first boot enabled
# it. Root-caused live 2026-08-12: e08311f retired
# snow-linux-live-setup.service (RequiredBy=multi-user.target,
# display-manager.service) and image 20260812205454 failed all three
# counted boots on an enrolled snow-ab machine. The initrd now prunes
# stale .requires links defensively (etc-overlay-prune.sh), but shipped
# units must not create the hazard in the first place. See docs/adr/0013
# and frostyard/core ADR-0030.
#
# What it scans: every git-tracked file inside an image payload directory
# (any `mkosi.extra/` dir or `shared/**/tree/` dir) — the same payload
# boundary as check-runtime-etc-guard.sh. Two violations:
#   1. a `RequiredBy=` line in any payload file (unit files and drop-ins);
#   2. a tracked path containing a `*.requires/` component under a systemd
#      unit directory (a hand-shipped hard-dependency link).
# Startup ordering that must be hard should use Requires=/BindsTo= in the
# [Unit] section of the DEPENDENT unit, or the static-wants pattern from
# CLAUDE.md — both live in /usr and update atomically with the image.
#
# Escape hatch: append `# requiredby-guard-allow: <reason>` to a flagged
# RequiredBy= line if it is provably safe (e.g. the unit and its
# dependents are removed and retired strictly together, with a shipped
# migration for existing installs).
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
guard_root=${SNOSI_REQUIRED_BY_GUARD_ROOT:-$script_dir}
cd "$guard_root"

fail=0

flag() { # file lineno line reason
    printf '%s:%s: %s\n    %s\n' "$1" "$2" "$4" "$3"
    fail=1
}

while IFS= read -r -d '' f; do
    case "$f" in
        */mkosi.extra/*|mkosi.extra/*|shared/*/tree/*) ;;
        *) continue ;;
    esac

    case "$f" in
        */systemd/system/*.requires/*|*/systemd/user/*.requires/*)
            flag "$f" 0 "(path)" \
                "shipped .requires enablement link: a retired target unit bricks boot at PID 1; use Requires= in the dependent unit or the static-wants pattern"
            continue
            ;;
    esac
    [ -f "$f" ] || continue

    n=0
    while IFS= read -r line; do
        n=$((n + 1))
        [[ $line =~ ^[[:space:]]*RequiredBy= ]] || continue
        [[ $line == *"# requiredby-guard-allow:"* ]] && continue
        flag "$f" "$n" "$line" \
            "RequiredBy= enablement in a shipped unit: preset-created .requires links persist in /etc and brick boot when the unit is later retired; use WantedBy= (plus Requires= in the dependent unit if hard ordering is needed)"
    done <"$f"
done < <(git ls-files -z)

if [ "$fail" -ne 0 ]; then
    echo
    echo "check-required-by-guard: violations found. See docs/adr/0013-no-requiredby-enablement-prune-stale-requires.md."
    exit 1
fi
echo "check-required-by-guard: OK"
