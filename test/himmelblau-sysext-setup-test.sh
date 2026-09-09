#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixture suite for the himmelblau sysext's runtime integration and setup tool.
#
# What this pins:
#  - usr/lib/himmelblau/himmelblau-sysext-setup replays the deb maintainer
#    scripts' /etc integration (nsswitch, pam-auth-update, GDM keyring
#    use_authtok, krb5 includedir, sshd reload) idempotently: a second run is
#    byte-identical, and it only ever ADDS (no deletions, no systemctl
#    enable/disable -- the bootc /etc-merge rule).
#  - usr/bin/snosi-himmelblau-setup writes a DROP-IN, not a main file (an
#    /etc main file would mask the deb's Debian defaults), merges existing
#    keys on re-run, merges the user map by local name, validates inputs,
#    and restarts the daemons without enabling anything.
#  - static wiring parity: every tmpfiles `C` rule has its factory source
#    pinned in required-paths.txt, every deb-shipped factory file is captured
#    by mkosi.finalize, and the Upholds= drop-in names the setup unit and
#    himmelblaud.
# Everything runs against a scratch root through HIMMELBLAU_SETUP_ROOT with
# PATH stubs for pam-auth-update/systemctl/aad-tool. No root, network, or
# image build.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image="$root/mkosi.images/himmelblau"
extra="$image/mkosi.extra"
integrate="$extra/usr/lib/himmelblau/himmelblau-sysext-setup"
wizard="$extra/usr/bin/snosi-himmelblau-setup"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

test_number=0
failures=0
ok() { test_number=$((test_number + 1)); echo "ok $test_number - $1"; }
fail() {
    test_number=$((test_number + 1)); failures=$((failures + 1))
    echo "not ok $test_number - $1"
    [[ -n ${2:-} ]] && sed "s/^/#   /" <<<"$2"
    return 0
}
check() { # description condition-command...
    local desc=$1; shift
    if "$@"; then ok "$desc"; else fail "$desc"; fi
}
check_fails() { # description command... (must exit non-zero, and not 127)
    local desc=$1 rc=0; shift
    "$@" >/dev/null 2>&1 || rc=$?
    if (( rc == 0 )); then fail "$desc" "command unexpectedly succeeded"
    elif (( rc == 127 )); then fail "$desc" "command not found (rc=127)"
    else ok "$desc"; fi
}

# --- fixture root ------------------------------------------------------------
make_root() { # name -> path
    local r="$work/$1"
    mkdir -p "$r/etc/pam.d" "$r/etc/ssh/sshd_config.d" "$r/usr/lib/himmelblau"
    cat >"$r/etc/nsswitch.conf" <<'NSS'
# /etc/nsswitch.conf
passwd:         files systemd
group:          files systemd
shadow:         files systemd
gshadow:        files systemd

hosts:          files mdns4_minimal [NOTFOUND=return] dns
NSS
    cat >"$r/etc/pam.d/common-auth" <<'PAM'
auth	[success=1 default=ignore]	pam_unix.so nullok
auth	requisite			pam_deny.so
auth	required			pam_permit.so
PAM
    cat >"$r/etc/pam.d/gdm-password" <<'PAM'
auth    requisite       pam_nologin.so
@include common-auth
auth    optional        pam_gnome_keyring.so
@include common-account
PAM
    cat >"$r/etc/krb5.conf" <<'KRB'
[libdefaults]
	default_realm = EXAMPLE.ORG
KRB
    echo "$r"
}

# PATH stubs. pam-auth-update appends the profile line into the fixture's
# common-auth so the second run sees it as already enabled; systemctl logs
# every call and reports ssh.service active when the fixture says so.
make_stubs() { # name -> bindir
    local bin="$work/$1/bin"
    mkdir -p "$bin"
    cat >"$bin/pam-auth-update" <<STUB
#!/bin/bash
printf 'pam-auth-update %s\n' "\$*" >>"$work/$1/calls"
printf 'auth\t[success=2 default=ignore]    pam_himmelblau.so ignore_unknown_user set_authtok\n' >>"\$HIMMELBLAU_SETUP_ROOT/etc/pam.d/common-auth"
STUB
    cat >"$bin/systemctl" <<STUB
#!/bin/bash
printf 'systemctl %s\n' "\$*" >>"$work/$1/calls"
if [[ \$1 == is-active ]]; then
    [[ -e "$work/$1/ssh-active" ]]
    exit
fi
exit 0
STUB
    cat >"$bin/aad-tool" <<STUB
#!/bin/bash
printf 'aad-tool %s\n' "\$*" >>"$work/$1/calls"
echo "working!"
STUB
    chmod +x "$bin"/*
    echo "$bin"
}

run_integrate() { # rootdir bindir
    HIMMELBLAU_SETUP_ROOT=$1 PATH="$2:$PATH" "$integrate"
}

# ==== integration script =====================================================
r=$(make_root int); bin=$(make_stubs int)
touch "$work/int/ssh-active"
out=$(run_integrate "$r" "$bin" 2>&1) || fail "integration script exits 0" "$out"

check "nsswitch: passwd gains himmelblau" grep -qx 'passwd:         files systemd himmelblau' "$r/etc/nsswitch.conf"
check "nsswitch: group gains himmelblau" grep -qx 'group:          files systemd himmelblau' "$r/etc/nsswitch.conf"
check "nsswitch: shadow gains himmelblau" grep -qx 'shadow:         files systemd himmelblau' "$r/etc/nsswitch.conf"
check "nsswitch: gshadow is left alone (deb postinst does not touch it)" grep -qx 'gshadow:        files systemd' "$r/etc/nsswitch.conf"
check "nsswitch: hosts is left alone" grep -q '^hosts:          files mdns4_minimal' "$r/etc/nsswitch.conf"
check "pam: pam-auth-update --package --enable himmelblau invoked" grep -qx 'pam-auth-update --package --enable himmelblau' "$work/int/calls"
check "gdm: pam_gnome_keyring auth line gains use_authtok" grep -qE '^auth[[:space:]]+optional[[:space:]]+pam_gnome_keyring\.so use_authtok$' "$r/etc/pam.d/gdm-password"
check "krb5: includedir appended to an existing krb5.conf" grep -qx 'includedir /etc/krb5.conf.d' "$r/etc/krb5.conf"
check "krb5: existing realm config preserved" grep -qx $'\tdefault_realm = EXAMPLE.ORG' "$r/etc/krb5.conf"
check "krb5: /etc/krb5.conf.d created" test -d "$r/etc/krb5.conf.d"
check "sshd: running ssh.service reload is queued with --no-block (blocking would deadlock behind Before=ssh.service)" grep -qx 'systemctl --no-block try-reload-or-restart ssh.service' "$work/int/calls"
check "guard: no systemctl enable/disable/preset at runtime" bash -c "! grep -Eq 'systemctl (enable|disable|preset|unmask|revert)' '$work/int/calls'"

snap=$(mktemp -d)
cp -a "$r/etc" "$snap/"
: >"$work/int/calls"
out=$(run_integrate "$r" "$bin" 2>&1) || fail "second run exits 0" "$out"
check "idempotent: second run leaves /etc byte-identical" diff -r "$snap/etc" "$r/etc"
check "idempotent: pam-auth-update not re-run once the profile is active" bash -c "! grep -q pam-auth-update '$work/int/calls'"

# krb5.conf with the trailing-slash spelling and a stopped sshd
r=$(make_root int2); bin=$(make_stubs int2)
printf 'includedir /etc/krb5.conf.d/\n[libdefaults]\n' >"$r/etc/krb5.conf"
rm -f "$r/etc/pam.d/gdm-password"
run_integrate "$r" "$bin" >/dev/null 2>&1 || fail "integration without gdm-password exits 0"
check "krb5: includedir with trailing slash is recognised, not duplicated" test "$(grep -c includedir "$r/etc/krb5.conf")" = 1
check "sshd: inactive ssh.service is not reloaded" bash -c "! grep -q try-reload-or-restart '$work/int2/calls'"
check "gdm: absent gdm-password (server) is skipped" test ! -e "$r/etc/pam.d/gdm-password"

# nsswitch with initgroups present and himmelblau already on one line
r=$(make_root int3); bin=$(make_stubs int3)
cat >"$r/etc/nsswitch.conf" <<'NSS'
passwd:         files systemd himmelblau
group:          files systemd
shadow:         files
initgroups:     files
NSS
run_integrate "$r" "$bin" >/dev/null 2>&1 || fail "integration with initgroups exits 0"
check "nsswitch: pre-existing himmelblau entry not duplicated" grep -qx 'passwd:         files systemd himmelblau' "$r/etc/nsswitch.conf"
check "nsswitch: initgroups gains himmelblau when present" grep -qx 'initgroups:     files himmelblau' "$r/etc/nsswitch.conf"

# ==== setup wizard ===========================================================
run_wizard() { # rootdir bindir args...
    local rr=$1 bb=$2; shift 2
    HIMMELBLAU_SETUP_ROOT=$rr PATH="$bb:$PATH" "$wizard" "$@" </dev/null
}
r=$(make_root wiz); bin=$(make_stubs wiz)
cp "$integrate" "$r/usr/lib/himmelblau/himmelblau-sysext-setup"
dropin="$r/etc/himmelblau/himmelblau.conf.d/50-snosi-setup.conf"
umap="$r/etc/himmelblau/user-map"

out=$(run_wizard "$r" "$bin" --domain Example.COM --map bjk=bketelsen@example.com --join-type register --set enable_experimental_mfa=true 2>&1) || fail "wizard exits 0" "$out"
check "wizard: writes the drop-in, not /etc/himmelblau/himmelblau.conf" test -f "$dropin" -a ! -e "$r/etc/himmelblau/himmelblau.conf"
check "wizard: drop-in has a [global] section" grep -qx '\[global\]' "$dropin"
check "wizard: domain lower-cased" grep -qx 'domain = example.com' "$dropin"
check "wizard: join_type written" grep -qx 'join_type = register' "$dropin"
check "wizard: --set passthrough written" grep -qx 'enable_experimental_mfa = true' "$dropin"
check "wizard: user_map_file points at the map" grep -qx 'user_map_file = /etc/himmelblau/user-map' "$dropin"
check "wizard: apply_policy defaults to true (Intune enrollment gate, upstream installer default)" grep -qx 'apply_policy = true' "$dropin"
check "wizard: user map entry written" grep -qx 'bjk:bketelsen@example.com' "$umap"
check "wizard: drop-in mode 0644" test "$(stat -c %a "$dropin")" = 644
check "wizard: runs the /etc integration" grep -qx 'passwd:         files systemd himmelblau' "$r/etc/nsswitch.conf"
check "wizard: restarts himmelblaud and tasks" grep -qx 'systemctl restart himmelblaud.service himmelblaud-tasks.service' "$work/wiz/calls"
check "wizard: reports status" grep -qx 'aad-tool status' "$work/wiz/calls"
check "wizard: never enables units at runtime" bash -c "! grep -Eq 'systemctl (enable|disable|preset)' '$work/wiz/calls'"
check "wizard: no stray temp files left in the config dir" bash -c "! ls '$r/etc/himmelblau/himmelblau.conf.d'/.snosi-setup.* 2>/dev/null"

# re-run merges: adds a map and a key, keeps the domain, drops a key
: >"$work/wiz/calls"
out=$(run_wizard "$r" "$bin" --map alice=alice@example.com --no-apply-policy --unset enable_experimental_mfa --no-restart 2>&1) || fail "wizard re-run exits 0" "$out"
check "re-run: domain preserved without --domain" grep -qx 'domain = example.com' "$dropin"
check "re-run: join_type preserved" grep -qx 'join_type = register' "$dropin"
check "re-run: --no-apply-policy overrides the default" grep -qx 'apply_policy = false' "$dropin"
check "re-run: only one apply_policy line" test "$(grep -c '^apply_policy' "$dropin")" = 1
check "re-run: --unset removes the key" bash -c "! grep -q enable_experimental_mfa '$dropin'"
check "re-run: first mapping kept" grep -qx 'bjk:bketelsen@example.com' "$umap"
check "re-run: second mapping added" grep -qx 'alice:alice@example.com' "$umap"
check "re-run: --no-restart skips systemctl" test ! -s "$work/wiz/calls"
out=$(run_wizard "$r" "$bin" --map bjk=brian@example.com --no-restart 2>&1) || fail "wizard map replace exits 0" "$out"
check "re-run: mapping replaced by local name, not duplicated" test "$(grep -c '^bjk:' "$umap")" = 1
check "re-run: replaced mapping has the new UPN" grep -qx 'bjk:brian@example.com' "$umap"
check "--show prints the drop-in" grep -qx 'domain = example.com' <(run_wizard "$r" "$bin" --show)

# rejections leave nothing behind
r=$(make_root rej); bin=$(make_stubs rej)
bad_dropin="$r/etc/himmelblau/himmelblau.conf.d/50-snosi-setup.conf"
check_fails "rejects an invalid domain" run_wizard "$r" "$bin" --domain 'not a domain'
check_fails "rejects a malformed --map" run_wizard "$r" "$bin" --domain example.com --map nobody
check_fails "rejects a UPN without @" run_wizard "$r" "$bin" --domain example.com --map bjk=bjk
check_fails "rejects an invalid --set key" run_wizard "$r" "$bin" --domain example.com --set 'Bad Key=1'
check_fails "rejects an unknown --join-type" run_wizard "$r" "$bin" --domain example.com --join-type sometimes
check_fails "rejects an unknown argument" run_wizard "$r" "$bin" --domain example.com --bogus
check_fails "requires --domain when stdin is not a terminal" run_wizard "$r" "$bin"
check "rejected runs write no drop-in" test ! -e "$bad_dropin"

# ==== static wiring parity ===================================================
tmpfiles="$extra/usr/lib/tmpfiles.d/himmelblau-sysext.conf"
required="$image/required-paths.txt"
finalize="$image/mkosi.finalize"
upholds="$extra/usr/lib/systemd/system/multi-user.target.d/10-himmelblau.conf"
preset="$extra/usr/lib/systemd/system-preset/40-himmelblau.preset"

parity_failed=""
while read -r path; do
    factory="/usr/share/factory$path"
    grep -qx "$factory" "$required" || parity_failed+="$factory not in required-paths.txt"$'\n'
    if [[ ! -e "$extra$factory" ]]; then
        rel=${path#/etc/}
        grep -q "^    $rel\$" "$finalize" || parity_failed+="$factory neither static in mkosi.extra nor captured by mkosi.finalize"$'\n'
    fi
done < <(awk '$1 == "C" {print $2}' "$tmpfiles")
if [[ -z $parity_failed ]]; then ok "every tmpfiles C rule has a pinned factory source"; else fail "tmpfiles/factory parity" "$parity_failed"; fi

parity_failed=""
while read -r rel; do
    grep -qx "C /etc/$rel - - - - -" "$tmpfiles" || parity_failed+="mkosi.finalize captures $rel but no tmpfiles C rule places it"$'\n'
done < <(sed -n '/^FACTORY_PATHS=(/,/^)/p' "$finalize" | grep -E '^    [a-z]')
if [[ -z $parity_failed ]]; then ok "every mkosi.finalize capture has a tmpfiles C rule"; else fail "finalize/tmpfiles parity" "$parity_failed"; fi

check "tmpfiles: no removal types aimed at /etc" bash -c "! awk '\$1 ~ /^[rR]\$/ && \$2 ~ /^\\/etc/' '$tmpfiles' | grep -q ."
check "Upholds drop-in upholds ONLY the setup unit" grep -qx 'Upholds=himmelblau-sysext-setup.service' "$upholds"
check "Upholds drop-in never upholds himmelblaud directly (condition-failed upheld units are retried forever)" bash -c "! grep -E '^Upholds=.*himmelblaud\.service' '$upholds'"
check "setup unit Wants= himmelblaud (one-shot pull, clean skip when unconfigured)" grep -qx 'Wants=himmelblaud.service' "$extra/usr/lib/systemd/system/himmelblau-sysext-setup.service"
gate="$extra/usr/lib/systemd/system/himmelblaud.service.d/10-snosi-configured.conf"
check "himmelblaud gate: main file OR any conf.d drop-in counts as configured" bash -c "grep -qx 'ConditionPathExists=|/etc/himmelblau/himmelblau.conf' '$gate' && grep -qx 'ConditionPathExistsGlob=|/etc/himmelblau/himmelblau.conf.d/\*.conf' '$gate'"
check "himmelblaud gate is pinned in required-paths" grep -qx /usr/lib/systemd/system/himmelblaud.service.d/10-snosi-configured.conf "$required"
check "preset enables the setup unit" grep -qx 'enable himmelblau-sysext-setup.service' "$preset"
check "preset enables himmelblaud" grep -qx 'enable himmelblaud.service' "$preset"
check "setup unit orders after reload-sysext and before himmelblaud/ssh/display-manager" bash -c "grep -q '^After=.*reload-sysext.service' '$extra/usr/lib/systemd/system/himmelblau-sysext-setup.service' && grep -Eq '^Before=.*himmelblaud.service.*display-manager.service.*ssh.service' '$extra/usr/lib/systemd/system/himmelblau-sysext-setup.service'"
check "setup unit has no RequiredBy" bash -c "! grep -q RequiredBy '$extra/usr/lib/systemd/system/himmelblau-sysext-setup.service'"
check "user timer static wants link resolves inside the sysext" test -f "$extra/usr/lib/systemd/user/timers.target.wants/himmelblau-compliance-check.timer" -o "$(readlink "$extra/usr/lib/systemd/user/timers.target.wants/himmelblau-compliance-check.timer")" = ../himmelblau-compliance-check.timer
check "required-paths pins the wizard and the integration script" bash -c "grep -qx /usr/bin/snosi-himmelblau-setup '$required' && grep -qx /usr/lib/himmelblau/himmelblau-sysext-setup '$required'"

echo "1..$test_number"
if (( failures )); then
    echo "# $failures failure(s)"
    exit 1
fi
