#!/bin/bash
# Hard CI gate: a unit upheld from a shipped Upholds= must not carry a
# Condition*= unless it is a RemainAfterExit=yes oneshot.
#
# Why: systemd retries an upheld unit whose condition fails, forever
# (snosi#1100: k3s upheld k3s.service and k3s-agent.service, one of which
# always had an unmet condition; 93,566 journal lines on one host). The fix
# pattern is to uphold a RemainAfterExit=yes oneshot that Wants= the gated
# unit (himmelblau-sysext-setup.service, k3s-sysext-setup.service).
#
# What it scans: git-tracked payload files (`mkosi.extra/` or
# `shared/*/tree/`) under `*/systemd/system/`. For every Upholds= target T
# defined in the repo (`T` or `T.d/*.conf`), if any defining file has a
# Condition*= line, T must resolve to Type=oneshot and RemainAfterExit=yes
# (last assignment wins: main unit, then drop-ins in basename order).
# Targets with no definition in the repo (package-shipped units) are skipped
# here; sysext builds check those on the delta and the base tree with
# shared/sysext/finalize/sysext-upholds-guard.sh (snosi#1113).
#
# Escape hatch: a comment line `# upholds-guard-allow: <reason>` IMMEDIATELY
# above the Condition*= line exempts that line. It must be its own line:
# systemd has no inline comments, so a trailing comment would corrupt the
# value.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
guard_root=${SNOSI_UPHOLDS_GUARD_ROOT:-$script_dir}
cd "$guard_root"

fail=0
payload=()
while IFS= read -r -d '' f; do
    case "$f" in
        */mkosi.extra/*|mkosi.extra/*|shared/*/tree/*) ;;
        *) continue ;;
    esac
    case "$f" in
        */systemd/system/*) ;;
        *) continue ;;
    esac
    [ -f "$f" ] || continue
    payload+=("$f")
done < <(git ls-files -z)

# target<TAB>upholding file<TAB>lineno, one per target
declare -A seen=()
targets=()
origins=()
for f in "${payload[@]}"; do
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        [[ $line =~ ^[[:space:]]*Upholds=(.*)$ ]] || continue
        read -r -a vals <<<"${BASH_REMATCH[1]}"
        for t in "${vals[@]}"; do
            [ -n "${seen[$t]:-}" ] && continue
            seen[$t]=1
            targets+=("$t")
            origins+=("$f:$n")
        done
    done <"$f"
done

truthy() {
    case "${1,,}" in yes|true|on|1) return 0 ;; *) return 1 ;; esac
}

# last assignment of key in the given files (in order); prints value or empty
last_value() {
    local key=$1
    shift
    local v="" file line
    for file in "$@"; do
        while IFS= read -r line || [ -n "$line" ]; do
            if [[ $line =~ ^[[:space:]]*${key}=(.*)$ ]]; then
                v=${BASH_REMATCH[1]}
            fi
        done <"$file"
    done
    printf '%s' "$v"
}

for i in "${!targets[@]}"; do
    t=${targets[$i]}
    origin=${origins[$i]}
    main=()
    dropins=()
    for f in "${payload[@]}"; do
        case "$f" in
            */systemd/system/"$t") main+=("$f") ;;
            */systemd/system/"$t".d/*.conf) dropins+=("$f") ;;
        esac
    done
    [ $((${#main[@]} + ${#dropins[@]})) -gt 0 ] || continue

    if [ ${#dropins[@]} -gt 0 ]; then
        mapfile -t dropins < <(
            for d in "${dropins[@]}"; do
                printf '%s\t%s\n' "$(basename "$d")" "$d"
            done | LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2 | cut -f2-
        )
    fi
    ordered=("${main[@]}" "${dropins[@]}")

    # Condition lines not exempted by an allow comment directly above.
    cond_file=""
    cond_n=0
    cond_line=""
    for f in "${ordered[@]}"; do
        n=0
        prev=""
        while IFS= read -r line || [ -n "$line" ]; do
            n=$((n + 1))
            if [[ $line =~ ^[[:space:]]*Condition[A-Za-z]+= ]] &&
                ! [[ $prev =~ ^[[:space:]]*#[[:space:]]*upholds-guard-allow: ]]; then
                cond_file=$f
                cond_n=$n
                cond_line=$line
                break 2
            fi
            prev=$line
        done <"$f"
    done
    [ -n "$cond_file" ] || continue

    type=$(last_value Type "${ordered[@]}")
    rae=$(last_value RemainAfterExit "${ordered[@]}")
    if [ "${type,,}" = oneshot ] && truthy "$rae"; then
        continue
    fi

    printf '%s:%s: %s is upheld by %s but has a condition (%s): an upheld unit whose condition fails is retried forever (snosi#1100); uphold a RemainAfterExit=yes oneshot that Wants= the unit (the himmelblau/k3s pattern)\n' \
        "$cond_file" "$cond_n" "$t" "$origin" "$cond_line"
    fail=1
done

if [ "$fail" -ne 0 ]; then
    echo
    echo "check-upholds-guard: violations found. See docs/design/sysexts.md \"Service Activation Pattern (Upholds=)\"."
    exit 1
fi
echo "check-upholds-guard: OK"
