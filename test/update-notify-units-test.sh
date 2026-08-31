#!/bin/bash
# Fixture suite for the staged-update notification units, both transports
# (bootc-update-notify.* in base, snosi-update-notify.* in the ab-root
# tree). Pins the trigger-shape contract root-caused live 2026-08-26:
#
#   The /run/snosi/update-staged semaphore persists until the applying
#   reboot BY DESIGN, and systemd's level-triggered path conditions
#   (PathExists=, PathExistsGlob=, DirectoryNotEmpty=) re-arm every time
#   the triggered oneshot exits -- an infinite retrigger loop that runs
#   into the path trigger limit (200 in 2s) and permanently fails the
#   watcher with 'trigger-limit-hit'. (The earlier StartLimitIntervalSec=0
#   fix had only unmasked this second limiter.) The notify path units must
#   therefore stay edge-triggered (PathModified= only), and the
#   login-while-pending case must be covered by a static
#   graphical-session.target.wants/ link on the SERVICE, which is
#   condition- and ack-gated.
#
# This is the seventh defect in this subsystem caused by twin bootc/native
# paths drifting, so the suite also asserts the two pairs stay equivalent
# modulo transport naming.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
base_user="$root/mkosi.images/base/mkosi.extra/usr/lib/systemd/user"
ab_user="$root/shared/outformat/ab-root/tree/usr/lib/systemd/user"

test_number=0
failures=0

ok() { test_number=$((test_number + 1)); echo "ok $test_number - $1"; }
fail() {
    test_number=$((test_number + 1)); failures=$((failures + 1))
    echo "not ok $test_number - $1"
}

for pair in "$base_user:bootc-update-notify" "$ab_user:snosi-update-notify"; do
    dir="${pair%%:*}"; name="${pair##*:}"
    path_unit="$dir/$name.path"
    svc_unit="$dir/$name.service"

    if grep -qE '^(PathExists|PathExistsGlob|DirectoryNotEmpty)=' "$path_unit"; then
        fail "$name.path has no level-triggered path condition (retrigger-loops on the persistent semaphore)"
    else
        ok "$name.path has no level-triggered path condition"
    fi

    if grep -q '^PathModified=/run/snosi/update-staged$' "$path_unit"; then
        ok "$name.path watches the semaphore via PathModified="
    else
        fail "$name.path watches the semaphore via PathModified="
    fi

    for u in "$path_unit" "$svc_unit"; do
        if grep -q '^StartLimitIntervalSec=0$' "$u"; then
            ok "$(basename "$u") keeps StartLimitIntervalSec=0 (staging burst)"
        else
            fail "$(basename "$u") keeps StartLimitIntervalSec=0 (staging burst)"
        fi
    done

    if grep -q '^ConditionPathExists=/run/snosi/update-staged$' "$svc_unit"; then
        ok "$name.service is condition-gated on the semaphore"
    else
        fail "$name.service is condition-gated on the semaphore"
    fi

    for u in path service; do
        link="$dir/graphical-session.target.wants/$name.$u"
        if [[ -L "$link" && "$(readlink "$link")" == "../$name.$u" ]]; then
            ok "$name.$u has a static graphical-session.target.wants/ link"
        else
            fail "$name.$u has a static graphical-session.target.wants/ link"
        fi
    done

    if grep -q '^\[Install\]' "$path_unit" "$svc_unit"; then
        fail "$name units carry no [Install] section (static-link activation only)"
    else
        ok "$name units carry no [Install] section (static-link activation only)"
    fi
done

# Twin parity: directive-level equality modulo transport naming, so a fix
# landing in one transport's pair cannot silently miss the other.
# ExecStart= is exempt: BOTH transports deliberately run the shared
# /usr/libexec/bootc-update-notify script (pinned by
# test/native-ab-contracts-test.sh), so it must not be name-normalized.
normalize() { # file transport-name
    grep -vE '^\s*#|^\s*$|^ExecStart=' "$1" | sed "s/$2/NAME/g; s/Description=.*/Description=/"
}
for u in path service; do
    if diff -q <(normalize "$base_user/bootc-update-notify.$u" bootc-update-notify) \
               <(normalize "$ab_user/snosi-update-notify.$u" snosi-update-notify) >/dev/null; then
        ok "bootc and native .$u units are directive-equivalent"
    else
        fail "bootc and native .$u units are directive-equivalent"
        diff <(normalize "$base_user/bootc-update-notify.$u" bootc-update-notify) \
             <(normalize "$ab_user/snosi-update-notify.$u" snosi-update-notify) | sed 's/^/#   /' || true
    fi
done

# The ask-password serial path unit is the one legitimate level-triggered
# path unit in the tree: its triggered agent is LONG-RUNNING (--watch), so
# it cannot retrigger-loop. Pin that exemption reasoning: level-triggered
# path conditions are only allowed when the triggered unit stays active.
serial="$root/shared/outformat/ab-root/tree/usr/lib/systemd/system/snosi-ask-password-serial.path"
if [[ -f "$serial" ]] && grep -q '^DirectoryNotEmpty=' "$serial"; then
    agent="$root/shared/outformat/ab-root/tree/usr/lib/systemd/system/snosi-ask-password-serial.service"
    if grep -q -- '--watch' "$agent"; then
        ok "ask-password serial pair: level-triggered condition is backed by a long-running (--watch) agent"
    else
        fail "ask-password serial pair: level-triggered condition requires a long-running triggered unit"
    fi
fi

# --- notify script: ack only after a successful send ----------------------
# The login-time run races the session's notification daemon (some shells
# start in parallel with graphical-session.target). The script
# must retry notify-send, write the ack ONLY on success, and exit 0 when
# every attempt fails (so the unit never shows failed and a later trigger
# still notifies).
script="$root/mkosi.images/base/mkosi.extra/usr/libexec/bootc-update-notify"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/run"
sem="$work/run/update-staged"
printf 'image=x\ndigest=sha256:%064d\n' 7 >"$sem"
run_script() { # notify-send behavior script body
    cat >"$work/bin/notify-send" <<EOF
#!/bin/bash
$1
EOF
    chmod +x "$work/bin/notify-send"
    rm -rf "$work/state"
    (
        export PATH="$work/bin:$PATH" XDG_STATE_HOME="$work/state" HOME="$work" SNOSI_NOTIFY_RETRY_DELAY=0
        # shellcheck disable=SC2030,SC2031
        sed "s|SEM=/run/snosi/update-staged|SEM=$sem|" "$script" >"$work/script"
        bash "$work/script"
    )
}
if run_script 'echo 1 >> "'"$work"'/calls"; exit 0' && [[ -f "$work/state/snosi/update-staged.ack" ]]; then
    ok "notify script writes the ack after a successful send"
else
    fail "notify script writes the ack after a successful send"
fi
rm -f "$work/calls"
if run_script 'echo 1 >> "'"$work"'/calls"; [[ $(wc -l < "'"$work"'/calls") -ge 2 ]]' \
    && [[ -f "$work/state/snosi/update-staged.ack" && $(wc -l <"$work/calls") -ge 2 ]]; then
    ok "notify script retries notify-send until the daemon answers"
else
    fail "notify script retries notify-send until the daemon answers"
fi
rm -f "$work/calls"
if run_script 'exit 1'; then
    if [[ ! -e "$work/state/snosi/update-staged.ack" ]]; then
        ok "notify script exits 0 without an ack when every send fails"
    else
        fail "notify script must not ack an unsent notification"
    fi
else
    fail "notify script exits 0 when every send fails (no spurious failed unit)"
fi

echo
echo "# Results: $((test_number - failures)) passed, $failures failed, $test_number total"
((failures == 0))
