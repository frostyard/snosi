#!/bin/bash
# Fixture suite for the native A/B / nbc end-of-life notice (docs/adr/0015).
# Pins:
#   - /usr/libexec/snosi-eol-notice is the ONE place holding the detection
#     predicate and the wording; the motd hook, the desktop notify script,
#     and snosi-update-status all delegate to it (no forked copies).
#   - the predicate: native-ab marker => native notice; no composefs= on the
#     kernel command line AND no /run/ostree-booted => nbc notice; composefs
#     (every supported bootc install) => silent; ostree-booted => silent;
#     container => silent.
#   - the wording carries the user-facing sentence and flips tense after
#     the EOL date.
#   - the current roadmap and org-ADR index retain the Accepted cutoff,
#     four-product surface, and non-support migration-help boundary.
#   - the notify unit is static-wants activated (no [Install]), pre-filtered
#     on !composefs, and the script acks ONLY after a successful send, so
#     each user sees exactly one toast.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
base="$root/mkosi.images/base/mkosi.extra"
notice="$base/usr/libexec/snosi-eol-notice"
notify="$base/usr/libexec/snosi-eol-notify"
motd="$base/etc/update-motd.d/80-snosi-eol"
unit="$base/usr/lib/systemd/user/snosi-eol-notify.service"
status="$base/usr/bin/snosi-update-status"
roadmap="$root/ROADMAP.md"
org_adrs="$root/docs/org-adrs.md"

test_number=0
failures=0
ok() { test_number=$((test_number + 1)); echo "ok $test_number - $1"; }
fail() {
    test_number=$((test_number + 1)); failures=$((failures + 1))
    echo "not ok $test_number - $1"
}
# check DESC CMD... : CMD's exit status decides.
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d"; fi; }
has() { [[ "$1" == *"$2"* ]]; }
lacks() { [[ "$1" != *"$2"* ]]; }
empty() { [[ -z "$1" ]]; }
has_line() { grep -q -- "$2" "$1"; }
no_match() { ! grep -Eq -- "$2" "$1"; }

# --- current documentation contract --------------------------------------
roadmap_text=$(tr '\n' ' ' <"$roadmap")
check "roadmap has the Accepted native A/B and nbc cutoff" \
    has "$roadmap_text" "Native A/B and nbc support and routine publication end on **2026-09-30**."
check "roadmap names all four current bootc products" \
    has "$roadmap_text" 'four bootc products (`snow`, `snowfield`, `sundog`, and `floe`)'
check "roadmap does not retain the superseded October 28 cutoff" \
    no_match "$roadmap" "2026-10-28"
check "roadmap keeps October 31 help separate from product support" \
    has "$roadmap_text" "**2026-10-31 for the four known users**. That limited arrangement does not extend product support"
check "org ADR index records the binding retirement decision" \
    has_line "$org_adrs" "ADR-0047.*2026-09-30"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/fx"
# Deterministic container answer: the real host may or may not be one.
printf '#!/bin/sh\nexit "${FAKE_CONTAINER_RC:-1}"\n' >"$work/bin/systemd-detect-virt"
chmod +x "$work/bin/systemd-detect-virt"

echo 'BOOT_IMAGE=/EFI/Linux/x.efi roothash=abc rw' >"$work/fx/cmdline-native"
echo 'BOOT_IMAGE=/EFI/Linux/x.efi root=UUID=1234 rw' >"$work/fx/cmdline-nbc"
echo 'rw composefs=?0123abcd' >"$work/fx/cmdline-composefs"
echo 'rw composefs=0123abcd' >"$work/fx/cmdline-composefs-plain"
touch "$work/fx/marker" "$work/fx/ostree-booted"

# run_notice MARKER CMDLINE OSTREE [TODAY] [CONTAINER_RC]
run_notice() {
    PATH="$work/bin:$PATH" FAKE_CONTAINER_RC="${5:-1}" \
    SNOSI_EOL_MARKER="$1" SNOSI_EOL_CMDLINE="$2" SNOSI_EOL_OSTREE_BOOTED="$3" \
    SNOSI_EOL_TODAY="${4:-2026-09-08}" bash "$notice"
}

for f in "$notice" "$notify" "$motd"; do
    check "$(basename "$f") is executable" test -x "$f"
done

out=$(run_notice "$work/fx/marker" "$work/fx/cmdline-native" "$work/fx/nope")
check "native-ab marker produces the native A/B notice" has "$out" "native A/B (-ab) snosi image"
check "notice carries the user-facing sentence (first half)" \
    has "$out" "These images will no longer receive updates. Please backup and install the"
check "notice carries the user-facing sentence (second half)" \
    has "$out" "bootc variants for continued support."
check "notice names the EOL date" has "$out" "2026-09-30"
check "before the EOL date the notice uses the future tense" \
    has "$out" "reaches end of life on 2026-09-30"
check "notice starts with a blank line like its motd siblings" has "${out:0:1}" $'\n'

out=$(run_notice "$work/fx/marker" "$work/fx/cmdline-native" "$work/fx/nope" 2026-10-01)
check "after the EOL date the notice uses the past tense" \
    has "$out" "reached end of life on 2026-09-30"

out=$(run_notice "$work/fx/nope" "$work/fx/cmdline-nbc" "$work/fx/nope")
check "no composefs= and no ostree-booted produces the nbc notice" has "$out" "installed with nbc"

out=$(run_notice "$work/fx/nope" "$work/fx/cmdline-composefs" "$work/fx/nope")
check "composefs=?<digest> (bootc) is silent" empty "$out"
out=$(run_notice "$work/fx/nope" "$work/fx/cmdline-composefs-plain" "$work/fx/nope")
check "composefs=<digest> (bootc) is silent" empty "$out"

out=$(run_notice "$work/fx/nope" "$work/fx/cmdline-nbc" "$work/fx/ostree-booted")
check "ostree-backend bootc deployment is not mistaken for nbc" empty "$out"

out=$(run_notice "$work/fx/marker" "$work/fx/cmdline-native" "$work/fx/nope" 2026-09-08 0)
check "containers are silent even with the marker present" empty "$out"

rc=0; run_notice "$work/fx/nope" "$work/fx/cmdline-composefs" "$work/fx/nope" >/dev/null || rc=$?
check "helper exits 0 when silent" test "$rc" -eq 0

# --- single source: consumers delegate, never re-implement ----------------
check "motd hook execs the shared helper" has_line "$motd" "^exec /usr/libexec/snosi-eol-notice$"
check "motd hook carries no detection of its own" no_match "$motd" "composefs|native-ab|ostree"
check "notify script runs the shared helper" has_line "$notify" "/usr/libexec/snosi-eol-notice"
check "notify script carries no detection of its own" \
    no_match "$notify" "composefs|/usr/lib/snosi/native-ab|ostree-booted"
check "snosi-update-status prints the shared helper output" has_line "$status" "/usr/libexec/snosi-eol-notice"
check "the EOL sentence exists in exactly one shipped file" \
    test "$(grep -rl "no longer receive updates. Please backup" "$base" | wc -l)" -eq 1

# --- unit shape -----------------------------------------------------------
check "notify unit exists" test -f "$unit"
check "notify unit has no [Install] section (static-link activation only)" no_match "$unit" "^\[Install\]"
link="$base/usr/lib/systemd/user/graphical-session.target.wants/snosi-eol-notify.service"
check "notify unit has a static graphical-session.target.wants/ link" \
    test -L "$link" -a "$(readlink "$link")" = "../snosi-eol-notify.service"
check "notify unit pre-filters on !composefs (bootc hosts never start it)" \
    has_line "$unit" "^ConditionKernelCommandLine=!composefs$"
check "notify unit is a oneshot" has_line "$unit" "^Type=oneshot$"
check "notify unit runs the notify script" has_line "$unit" "^ExecStart=/usr/libexec/snosi-eol-notify$"
check "notify unit is not RequiredBy= anything (ADR-0013)" no_match "$unit" "RequiredBy="

# --- notify script: one toast per user, ack only after success -------------
fake_notice="$work/bin/fake-notice"
# Same shape as the real helper: leading blank line, multi-line body.
printf '#!/bin/sh\nprintf "\\nNOTICE: fixture\\nbody line\\n"\n' >"$fake_notice"
chmod +x "$fake_notice"
run_notify() { # notify-send body
    cat >"$work/bin/notify-send" <<EOF2
#!/bin/bash
$1
EOF2
    chmod +x "$work/bin/notify-send"
    (
        export PATH="$work/bin:$PATH" XDG_STATE_HOME="$work/state" HOME="$work" \
            SNOSI_NOTIFY_RETRY_DELAY=0 SNOSI_EOL_NOTICE_CMD="$fake_notice"
        bash "$notify"
    )
}
# Calls are counted in their own file: the toast body is multi-line, so
# the argument log cannot double as a call counter.
rm -rf "$work/state" "$work/calls" "$work/args"
run_notify 'echo 1 >> "'"$work"'/calls"; echo "$@" >> "'"$work"'/args"; exit 0'
check "notify script sends once" test "$(wc -l <"$work/calls")" -eq 1
check "notify script writes the ack after a successful send" test -s "$work/state/snosi/eol-notice.ack"
check "toast is critical urgency (persists until dismissed)" has_line "$work/args" "--urgency=critical"
check "toast body carries the helper text" has_line "$work/args" "NOTICE: fixture"
check "toast body drops the helper's leading blank line" \
    has "$(cat "$work/args")" "--urgency=critical This OS image is being retired NOTICE: fixture"
check "toast title picks no tense (body says reaches/reached)" \
    no_match "$work/args" "is end of life|reaches|reached"
run_notify 'echo 1 >> "'"$work"'/calls"; exit 0'
check "second login does not re-notify (ack-gated)" test "$(wc -l <"$work/calls")" -eq 1

rm -rf "$work/state" "$work/calls"
run_notify 'echo 1 >> "'"$work"'/calls"; [[ $(wc -l < "'"$work"'/calls") -ge 2 ]]'
check "notify script retries notify-send until the daemon answers" \
    test -s "$work/state/snosi/eol-notice.ack" -a "$(wc -l <"$work/calls")" -ge 2

rm -rf "$work/state" "$work/calls"
rc=0; run_notify 'exit 1' || rc=$?
check "notify script exits 0 when every send fails" test "$rc" -eq 0
check "notify script writes no ack when every send fails" test ! -e "$work/state/snosi/eol-notice.ack"

rm -rf "$work/state" "$work/calls"
printf '#!/bin/sh\nexit 0\n' >"$fake_notice"
run_notify 'echo 1 >> "'"$work"'/calls"; exit 0'
check "notify script is silent when the helper prints nothing" test ! -e "$work/calls"
check "notify script writes no ack when the helper prints nothing" test ! -e "$work/state/snosi/eol-notice.ack"

echo
echo "# Results: $((test_number - failures)) passed, $failures failed, $test_number total"
((failures == 0))
