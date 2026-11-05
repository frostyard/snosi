#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixture suite for mkosi.images/base/mkosi.extra/usr/bin/snosi-health
# (ADR-0029): the collector, its problems.json and details.json contract,
# its units, and the vendored schema copy and validator. No root, network,
# journal or image build: journalctl, systemctl and bootc are PATH stubs that
# serve test/fixtures/snosi-health/base, and the paired test hooks
# (SNOSI_HEALTH_TEST_HOOKS=1 plus SNOSI_HEALTH_TEST_ROOT, ADR-0009) point every
# input and output path into a scratch root.
# shellcheck disable=SC2016 # some checks match literal shell source
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COLLECTOR="$ROOT_DIR/mkosi.images/base/mkosi.extra/usr/bin/snosi-health"
UNIT_DIR="$ROOT_DIR/mkosi.images/base/mkosi.extra/usr/lib/systemd/system"
SERVICE="$UNIT_DIR/snosi-health.service"
TIMER="$UNIT_DIR/snosi-health.timer"
PRESET="$ROOT_DIR/mkosi.images/base/mkosi.extra/usr/lib/systemd/system-preset/06-snosi-health.preset"
FIXTURES="$ROOT_DIR/test/fixtures/snosi-health"
SCHEMA="$FIXTURES/schema/v1.json"
VALIDATOR="$ROOT_DIR/test/lib/json_schema_subset.py"
# Byte copy of frostyard/core docs/specs/schemas/problem-report/v1.json and
# its examples at core commit f1b62e0 (PR #196). A change to the copy must
# change this pin.
readonly CORE_COMMIT=f1b62e0692adc1da6050c6f4733814f06b7476c6
readonly SCHEMA_SHA256=6c053ee3a9b4fd399d1d011b2be833dc6b17f25e727161fc576b0ce64cc14c3a

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

PASS=0
FAIL=0
pass() {
    PASS=$((PASS + 1))
    echo "ok - $*"
}
fail() {
    FAIL=$((FAIL + 1))
    echo "not ok - $*" >&2
}
check() { # description command...
    local description=$1
    shift
    if "$@"; then pass "$description"; else fail "$description"; fi
}

# --- 1. the schema copy and the validator ----------------------------------

check "v1.json is the byte copy of core $CORE_COMMIT" \
    test "$(sha256sum "$SCHEMA" | cut -d' ' -f1)" = "$SCHEMA_SHA256"
check "the 9 core examples are vendored" \
    test "$(find "$FIXTURES/schema/examples" -name '*.json' | wc -l)" -eq 9
check "every core example validates" \
    python3 "$VALIDATOR" "$SCHEMA" "$FIXTURES"/schema/examples/*.json

negative() { # description jq-filter-on-the-unit_failed-example
    local doc="$WORK_DIR/negative.json"
    jq "$2" "$FIXTURES/schema/examples/unit_failed.json" >"$doc"
    if python3 "$VALIDATOR" "$SCHEMA" "$doc" 2>/dev/null; then
        fail "the validator rejects $1"
    else
        pass "the validator rejects $1"
    fi
}
negative "an unknown envelope field" '. + {hostname: "frosty-desk"}'
negative "an unknown detail field" '.detail += {message: "x"}'
negative "a bad week pattern" '.week = "2026-W60"'
negative "a trailing newline in a pattern value" '.image.version = "20261031093822\n"'
negative "a wrong kind detail" '.kind = "crash"'
negative "a unit instance" '.detail.unit = "user@1000.service"'
negative "shipped false" '.detail.shipped = false'
negative "an unknown image id" '.image.id = "debian"'
negative "a missing envelope field" 'del(.report_id)'
negative "an app_problem error without its code" \
    '.kind = "app_problem" | .detail = {app_id: "org.frostyard.nsl", app_version: "0.9.2", runtime: "go", component: "daemon", class: "error"}'
negative "a panic with a code (a false boolean schema)" \
    '.kind = "app_problem" | .detail = {app_id: "org.frostyard.nsl", app_version: "0.9.2", runtime: "go", component: "daemon", class: "panic", code: "x.y"}'
negative "33 frames" \
    '.kind = "app_problem" | .detail = {app_id: "org.frostyard.nsl", app_version: "0.9.2", runtime: "go", component: "daemon", class: "panic", frames: [range(33) | "main.main"]}'
negative "retries out of range" \
    '.kind = "tpm_unlock" | .detail = {outcome: "ok_after_retry", tpm_rc: "PCR_CHANGED", retries: 11}'

# Every pattern of v1.json (except report_id's, which only a sender uses)
# appears in the collector as the same JSON string, so the collector's jq
# rules cannot drift from the schema copy.
missing_patterns=$(python3 - "$SCHEMA" "$COLLECTOR" <<'PY'
import json, sys
schema = json.load(open(sys.argv[1]))
text = open(sys.argv[2]).read()
found = []
def walk(node, parent):
    if isinstance(node, dict):
        for key, value in node.items():
            # problems.json has no report_id: a sender makes one per report.
            if key == "pattern" and parent != "report_id":
                found.append(value)
            walk(value, key)
    elif isinstance(node, list):
        for value in node:
            walk(value, parent)
walk(schema, None)
for pattern in found:
    if json.dumps(pattern) not in text:
        print(pattern)
PY
)
check "every v1.json pattern appears verbatim in snosi-health${missing_patterns:+ (missing: $missing_patterns)}" \
    test -z "$missing_patterns"

# --- 2. the units, the preset and the script's static contract ------------

unit_has() { grep -qxF -- "$2" "$1"; }
unit_lacks_re() { ! grep -qE -- "$2" "$1"; }
check "service is a oneshot" unit_has "$SERVICE" 'Type=oneshot'
check "service runs /usr/bin/snosi-health" unit_has "$SERVICE" 'ExecStart=/usr/bin/snosi-health'
check "service uses StateDirectory=snosi-health" unit_has "$SERVICE" 'StateDirectory=snosi-health'
check "service runs at idle I/O priority" unit_has "$SERVICE" 'IOSchedulingClass=idle'
check "service runs at idle CPU priority" unit_has "$SERVICE" 'CPUSchedulingPolicy=idle'
check "service has a start timeout" grep -qE '^TimeoutStartSec=[0-9]+(min|s)?$' "$SERVICE"
check "service has no network" unit_has "$SERVICE" 'PrivateNetwork=yes'
check "service allows only AF_UNIX sockets" unit_has "$SERVICE" 'RestrictAddressFamilies=AF_UNIX'
check "service sets NoNewPrivileges" unit_has "$SERVICE" 'NoNewPrivileges=yes'
check "service has no Before=" unit_lacks_re "$SERVICE" '^Before='
check "service has no [Install] section" unit_lacks_re "$SERVICE" '^\[Install\]'
check "service orders after no login or graphical unit" unit_lacks_re "$SERVICE" \
    '^(After|Wants|Requires|BindsTo|PartOf)=.*(graphical|display-manager|gdm|sddm|logind|getty|user@|multi-user)'
check "timer starts 3 minutes after boot" unit_has "$TIMER" 'OnBootSec=3min'
check "timer runs hourly" unit_has "$TIMER" 'OnUnitActiveSec=1h'
check "timer has no Before=" unit_lacks_re "$TIMER" '^Before='
check "timer is wanted by timers.target only" \
    test "$(grep -E '^(WantedBy|RequiredBy|UpheldBy|Alias)=' "$TIMER")" = 'WantedBy=timers.target'
check "timer orders after no login or graphical unit" unit_lacks_re "$TIMER" \
    '^(After|Wants|Requires)=.*(graphical|display-manager|gdm|sddm|logind|getty|user@)'
check "06-snosi-health.preset enables the timer" unit_has "$PRESET" 'enable snosi-health.timer'
check "no preset enables the service directly" \
    bash -c "! grep -rqE '^[[:space:]]*enable[[:space:]]+snosi-health\.service' '$ROOT_DIR/mkosi.images/base/mkosi.extra/usr/lib/systemd/system-preset'"
check "no var-outcomes map names /var/lib/snosi-health (StateDirectory= creates it)" \
    bash -c "! grep -q 'snosi-health' '$ROOT_DIR'/shared/composition/*/var-outcomes.txt"
check "collector is executable" test -x "$COLLECTOR"
check "collector writes by temp file and rename" grep -qF 'mv -f "$tmp_problems" "$PROBLEMS"' "$COLLECTOR"
rename_order=$(grep -E '^[[:space:]]*mv -f "\$(tmp_problems|tmp_details|tmp_state|NEW_CURSOR)"' "$COLLECTOR" | sed 's/^[[:space:]]*mv -f "\$\([a-z_A-Z]*\)".*/\1/' | tr '\n' ' ')
check "renames run problems, details, state, then the cursor (got: $rename_order)" \
    test "$rename_order" = 'tmp_problems tmp_details tmp_state NEW_CURSOR '
check "every temp file is written before the first rename" \
    test "$(grep -n 'fill_temp "\$tmp_state"' "$COLLECTOR" | cut -d: -f1)" -lt "$(grep -n '^mv -f "\$tmp_problems"' "$COLLECTOR" | cut -d: -f1)"
check "collector takes a lock" grep -qF 'flock -n "$lock_fd"' "$COLLECTOR"
check "collector puts a timeout on external commands" grep -qF 'timeout --kill-after=5 "$CMD_TIMEOUT" "$@"' "$COLLECTOR"
help=$("$COLLECTOR" --help)
check "--help documents --list" grep -qF -- '--list' <<<"$help"
check "--help keeps the test hooks out" bash -c "! grep -q SNOSI_HEALTH <<<\"\$1\"" _ "$help"

# Readers of /run/snosi/update-check read keys by name, so the new
# error_class line cannot change what they print.
check "the motd hook reads update-check keys by name" \
    grep -qF "outcome=\$(sed -n 's/^outcome=//p' \"\$CHECK\")" \
    "$ROOT_DIR/mkosi.images/base/mkosi.extra/etc/update-motd.d/86-bootc-update-staged"
check "snosi-update-status reads update-check keys by name" \
    grep -qF 'outcome=$(key outcome "$CHECK")' \
    "$ROOT_DIR/mkosi.images/base/mkosi.extra/usr/bin/snosi-update-status"

# --- 3. the collector on fixtures -----------------------------------------

STUBS="$WORK_DIR/bin"
mkdir -p "$STUBS"
cat >"$STUBS/journalctl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$FIX/journalctl-calls"
after="" events=0 kernel=0 crypt=0 unit=0 since=0
for arg in "$@"; do
    case $arg in
        --after-cursor=*) after=${arg#*=} ;;
        --since=*) since=1 ;;
        --cursor-file=* | --cursor=*) echo "stub: the collector keeps its own cursor" >&2; exit 1 ;;
        MESSAGE_ID=*) events=1 ;;
        -k) kernel=1 ;;
        -u) unit=1 ;;
        SYSLOG_IDENTIFIER=systemd-cryptsetup) crypt=1 ;;
    esac
done
# Like journalctl 262: --since with a cursor option is refused.
if [[ -n $after ]] && ((since)); then
    echo 'Please specify only one of --since=, --cursor=, --cursor-file=, and --after-cursor=.' >&2
    exit 1
fi
if ((unit)); then cat "$FIX/unit-journal.json" 2>/dev/null; exit 0; fi
if ((kernel)); then cat "$FIX/kernel.json" 2>/dev/null; exit 0; fi
if ((crypt)); then cat "$FIX/cryptsetup.json" 2>/dev/null; exit 0; fi
if ((events)); then
    printing=1
    [[ -z $after ]] || printing=0
    [[ -f $FIX/events.json ]] || exit 0
    while IFS= read -r line; do
        cursor=$(jq -r '.__CURSOR' <<<"$line")
        if ((printing)); then printf '%s\n' "$line"; fi
        [[ $cursor == "$after" ]] && printing=1
    done <"$FIX/events.json"
fi
exit 0
STUB
cat >"$STUBS/systemctl" <<'STUB'
#!/bin/bash
case $1 in
    list-units) cat "$FIX/units.json" 2>/dev/null || echo '[]' ;;
    show) cat "$FIX/units/${*: -1}.show" ;;
    *) exit 1 ;;
esac
STUB
cat >"$STUBS/bootc" <<'STUB'
#!/bin/bash
case $1 in
    --version) echo 'bootc 1.17.3' ;;
    status) cat "$FIX/bootc-status.json" 2>/dev/null || echo '{}' ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$STUBS"/*

FIX="$WORK_DIR/fix"
HROOT="$WORK_DIR/root"
STATE="$HROOT/var/lib/snosi-health"
PROBLEMS="$STATE/problems.json"
DETAILS="$STATE/details.json"
now_s=$(date -u +%s)

# shift_times FILE -- move every journal timestamp so the newest one is an
# hour ago: the 90-day pruning then never depends on the date of the run.
shift_times() {
    local file=$1 newest delta
    [[ -s $file ]] || return 0
    newest=$(jq -s 'map(.__REALTIME_TIMESTAMP | tonumber) | max' "$file")
    delta=$(((now_s - 3600) * 1000000 - newest))
    jq -c --argjson d "$delta" '.__REALTIME_TIMESTAMP = ((.__REALTIME_TIMESTAMP | tonumber) + $d | tostring)' \
        "$file" >"$file.new"
    mv "$file.new" "$file"
}

setup_fixture() {
    rm -rf "$FIX" "$HROOT"
    cp -r "$FIXTURES/base" "$FIX"
    for f in unit-journal.json cryptsetup.json kernel.json events.json; do
        shift_times "$FIX/$f"
    done
    mkdir -p "$HROOT/usr/lib" "$HROOT/proc/sys/kernel/random" "$HROOT/run/snosi" "$HROOT/var/lib/updex"
    cp "$FIX/os-release" "$HROOT/usr/lib/os-release"
    cp "$FIX/cmdline" "$HROOT/proc/cmdline"
    cp "$FIX/boot_id" "$HROOT/proc/sys/kernel/random/boot_id"
    sed "s/^checked_at=.*/checked_at=$(date -u -d '-2 hours' --iso-8601=seconds)/" \
        "$FIX/update-check" >"$HROOT/run/snosi/update-check"
    jq --arg at "$(date -u -d '-3 hours' +%Y-%m-%dT%H:%M:%SZ)" '.finished = $at | .features[].at = $at' \
        "$FIX/last-run.json" >"$HROOT/var/lib/updex/last-run.json"
}

run_health() { # args...
    PATH="$STUBS:$PATH" FIX="$FIX" SNOSI_HEALTH_TEST_HOOKS=1 SNOSI_HEALTH_TEST_ROOT="$HROOT" \
        "$COLLECTOR" "$@"
}

collect() {
    if ! RUN_OUTPUT=$(run_health 2>&1); then
        fail "collector run failed: $RUN_OUTPUT"
        return 1
    fi
}

problem() { # jq-selector -> the matching problem records
    jq -c "[.problems[] | select($1)]" "$PROBLEMS"
}
count_of() { # jq-selector
    jq "[.problems[] | select($1)] | length" "$PROBLEMS"
}
occurrences() { # id -> occurrences
    jq -r --arg id "$1" '.problems[] | select(.id == $id) | .occurrences' "$PROBLEMS"
}
detail_is() { # jq-selector expected-detail-json
    test "$(jq -c "[.problems[] | select($1) | .detail]" "$PROBLEMS")" = "[$2]"
}

# validate_problems -- every reportable record validates against v1 as a full
# envelope; every field of every record matches its v1 property schema; and
# reportable is true exactly when the full envelope validates.
validate_problems() {
    python3 - "$SCHEMA" "$PROBLEMS" "$VALIDATOR" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("v", sys.argv[3])
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)
schema = json.load(open(sys.argv[1]))
doc = json.load(open(sys.argv[2]))
bad = []
top = {"format", "schema", "generated", "image", "secure", "client", "problems"}
if set(doc) != top:
    bad.append(f"top-level keys {sorted(doc)}")
for p in doc["problems"]:
    keys = {"id", "kind", "detail", "week", "first_seen", "last_seen", "occurrences", "reportable"}
    if set(p) != keys:
        bad.append(f"{p.get('id')}: record keys {sorted(p)}")
        continue
    envelope = {
        "schema": doc["schema"], "report_id": "00000000-0000-4000-8000-000000000000",
        "week": p["week"], "image": doc["image"], "secure": doc["secure"],
        "client": doc["client"], "kind": p["kind"], "detail": p["detail"],
    }
    errors = v.validate(schema, envelope)
    if bool(p["reportable"]) != (not errors):
        bad.append(f"{p['id']} {p['kind']}: reportable={p['reportable']} but errors={errors}")
    props = schema["$defs"][p["kind"]]["properties"]
    for field, value in p["detail"].items():
        if field not in props:
            bad.append(f"{p['id']}: unknown detail field {field}")
            continue
        field_errors = v.validate(props[field], value, root=schema)
        if field_errors:
            bad.append(f"{p['id']}: {field}: {field_errors}")
for line in bad:
    print(line, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
}

# Strings that the fixtures put in messages, unit names, paths and forged
# fields. None may reach the world-readable problems.json.
SENTINELS=(brian /home /opt /etc/ /run/ /usr/ /var/ frosty-desk @1000 1000.service luks
    'dumped core' 'Failed to start' 'FILE CORRUPTED' 'Esys' MESSAGE 'Stack trace' nautilus
    'org.frostyard.Evil' 'problem/9' 'forged' 'ghcr.io' '0f1e2d3c' 'Process 4711')
no_sentinels() {
    local s found=""
    for s in "${SENTINELS[@]}"; do
        if grep -qF -- "$s" "$PROBLEMS"; then
            found="$found '$s'"
        fi
    done
    if [[ -z $found ]]; then
        pass "problems.json holds no message, path, username, unit instance, hostname or boot ID"
    else
        fail "problems.json holds forbidden strings:$found"
    fi
}

mode_of() { stat -c %a "$1"; }

# --- 3a. --list before any run, and the hook gating ------------------------
setup_fixture
check "--list without a record says so and succeeds" \
    test "$(run_health --list)" = 'No problem record yet'

if [[ $EUID -ne 0 ]]; then
    if out=$(PATH="$STUBS:$PATH" FIX="$FIX" SNOSI_HEALTH_TEST_ROOT="$HROOT" "$COLLECTOR" 2>&1); then
        fail "a stray SNOSI_HEALTH_TEST_ROOT alone relaxes nothing (it ran: $out)"
    elif [[ $out == *"must run as root"* && ! -e $STATE ]]; then
        pass "a stray SNOSI_HEALTH_TEST_ROOT alone relaxes nothing"
    else
        fail "a stray SNOSI_HEALTH_TEST_ROOT alone relaxes nothing ($out)"
    fi
fi
set +e
SNOSI_HEALTH_TEST_HOOKS=yes SNOSI_HEALTH_TEST_ROOT="$HROOT" "$COLLECTOR" --list >/dev/null 2>&1
rc_yes=$?
SNOSI_HEALTH_TEST_HOOKS=1 "$COLLECTOR" --list >/dev/null 2>&1
rc_noroot=$?
set -e
check "a hooks value other than 0 or 1 is refused" test "$rc_yes" -eq 2
check "hooks=1 without a test root is refused" test "$rc_noroot" -eq 2

# --- 3b. the first run ----------------------------------------------------
collect
check "the first run writes problems.json" test -f "$PROBLEMS"
check "problems.json is mode 0644" test "$(mode_of "$PROBLEMS")" = 644
check "details.json is mode 0640" test "$(mode_of "$DETAILS")" = 640
check "state.json is mode 0600" test "$(mode_of "$STATE/state.json")" = 600
check "the journal cursor is mode 0600" test "$(mode_of "$STATE/journal.cursor")" = 600
check "chown to root:sudo is skipped only under the test hooks" \
    grep -qF 'if [[ $TEST_HOOKS -ne 1 ]]; then' "$COLLECTOR"
check "details.json is chowned to root:sudo" grep -qF 'fill_temp "$tmp_details" 0640 sudo .details' "$COLLECTOR"
check "no temp file is left" test -z "$(find "$STATE" -name '.*.json.*' -o -name '.journal.cursor.*')"
if validate_problems; then
    pass "records validate against the v1 schema copy (reportable exactly when the envelope is valid)"
else
    fail "records validate against the v1 schema copy"
fi
no_sentinels
check "the envelope carries the image id and version" \
    test "$(jq -c '.image' "$PROBLEMS")" = '{"id":"snow","version":"20261105100000"}'
check "secure follows lockdown=integrity on the command line" test "$(jq '.secure' "$PROBLEMS")" = true
check "client is snosi-health/<image version>" test "$(jq -r '.client' "$PROBLEMS")" = 'snosi-health/20261105100000'
check "week is the ISO week of last_seen" \
    test "$(jq '[.problems[] | select(.week != (.last_seen | fromdateiso8601 | strftime("%G-W%V")))] | length' "$PROBLEMS")" -eq 0

# S1
check "S1: a shipped template unit is reportable with its instance stripped" \
    detail_is '.kind == "unit_failed" and .detail.unit == "user@.service"' '{"unit":"user@.service","result":"exit-code","shipped":true}'
check "S1: an unknown Result maps to other" \
    test "$(count_of '.kind == "unit_failed" and .detail.unit == "snosi-etc-drift-report.service" and .detail.result == "other"')" -eq 1
check "S1: units that are not shipped stay local (no name, not reportable)" \
    test "$(jq -c '[.problems[] | select(.kind == "unit_failed" and (.detail | has("unit") | not)) | [.detail, .reportable]] | sort' "$PROBLEMS")" = '[[{"result":"exit-code"},false],[{"result":"timeout"},false]]'
check "S1: details.json keeps the full unit name" grep -qF '"user@1000.service"' "$DETAILS"
check "S1: details.json keeps the unit's journal text" grep -qF 'Failed to start backup of /home/brian' "$DETAILS"
check "details.json keeps at most 5 messages of at most 1024 characters" \
    test "$(jq '[.problems[] | (.messages | length > 5), (.messages[] | length > 1024)] | any' "$DETAILS")" = false

# S2 and S3
check "S2: a failed stage is reportable with the stager's error_class" \
    detail_is '.kind == "update_stage_failed"' '{"target_version":"20261104000000","error_class":"registry","bootc_version":"1.17.3"}'
check "S3: a newer rollback deployment records booted_older_image (how unknown without held-rollback)" \
    detail_is '.kind == "booted_older_image"' '{"newer_version":"20261104000000","how":"unknown"}'

# S4
check "S4: a failed image feature is reportable" \
    detail_is '.kind == "sysext_update_failed" and .detail.feature == "docker"' '{"feature":"docker","version":"29.0.1","outcome":"failed","error_class":"network"}'
check "S4: a busy catalog feature without a version is recorded, not reportable" \
    test "$(jq -c '[.problems[] | select(.detail.feature == "incus") | [.detail, .reportable]]' "$PROBLEMS")" = '[[{"feature":"incus","outcome":"skipped_busy"},false]]'
check "S4: unknown outcome and error_class values become other" \
    detail_is '.detail.feature == "podman"' '{"feature":"podman","version":"5.4.0","outcome":"other","error_class":"other"}'
check "S4: a local feature is not recorded" test "$(grep -c 'brian-tools' "$PROBLEMS" "$DETAILS" | awk -F: '{s+=$2} END {print s}')" -eq 0
check "S4: an updated feature is not recorded" test "$(count_of '.detail.feature == "tailscale"')" -eq 0

# S5 and S6
check "S5: 2 PCR_CHANGED retries then a TPM unlock" \
    detail_is '.kind == "tpm_unlock"' '{"outcome":"ok_after_retry","tpm_rc":"PCR_CHANGED","retries":2}'
check "S6: 2 fs-verity errors give the 2-10 bucket" \
    detail_is '.kind == "integrity_error" and .detail.subsystem == "fs-verity"' '{"subsystem":"fs-verity","count":"2-10"}'
check "S6: 1 dm-verity error gives the 1 bucket" \
    detail_is '.kind == "integrity_error" and .detail.subsystem == "dm-verity"' '{"subsystem":"dm-verity","count":"1"}'
check "S6: an overlayfs verity error counts as composefs" \
    detail_is '.kind == "integrity_error" and .detail.subsystem == "composefs"' '{"subsystem":"composefs","count":"1"}'

# S7
check "S7: a system crash of a /usr program is reportable" \
    detail_is '.kind == "crash" and .reportable' '{"exe":"gnome-shell","signal":"SIGSEGV","package":"gnome-shell","package_version":"48.4-1"}'
check "S7: a crash outside /usr keeps no exe and is not reportable" \
    test "$(jq -c '[.problems[] | select(.kind == "crash" and (.reportable | not)) | .detail]' "$PROBLEMS")" = '[{"signal":"SIGABRT"}]'
check "S7: a user crash (COREDUMP_UID >= 1000) is not recorded" test "$(count_of '.kind == "crash"')" -eq 2
check "S7: details.json keeps the crash text" grep -qF 'dumped core' "$DETAILS"

# S8
check "S8: a valid system app error is reportable" \
    detail_is '.kind == "app_problem" and .detail.class == "error"' '{"app_id":"org.frostyard.Frostmail","app_version":"1.2.0","runtime":"go","component":"daemon","class":"error","code":"store.migrate_failed"}'
check "S8: a valid Go panic keeps its frames" \
    detail_is '.kind == "app_problem" and .detail.class == "panic"' '{"app_id":"org.frostyard.pilothouse","app_version":"2.0.1","runtime":"go","component":"daemon","class":"panic","frames":["runtime.gopanic","github.com/frostyard/pilothouse/internal/broker.(*Broker).Probe","main.main"]}'
check "S8: forged values, an unknown schema and user entries are dropped" \
    test "$(count_of '.kind == "app_problem"')" -eq 2
check "S8: forged records leave nothing in details.json" \
    bash -c "! grep -qE 'forged|unknown schema|chairlift reads it|may not carry' '$DETAILS'"

check "S7/S8: the first run reads 90 days" \
    grep -qE -- '^--system .*--since=-90d .*MESSAGE_ID=' "$FIX/journalctl-calls"
check "S7/S8: the first run has no cursor option" \
    bash -c "! grep -qE -- '--(after-)?cursor' '$FIX/journalctl-calls'"
check "S7/S8: the cursor advances to the newest entry" test "$(cat "$STATE/journal.cursor")" = e13

list=$(run_health --list)
check "--list prints 1 line for each problem" \
    test "$(wc -l <<<"$list")" -eq "$(jq '.problems | length' "$PROBLEMS")"
check "--list names the unit, the result and the reportable flag" \
    grep -qF 'user@.service failed (exit-code)' <<<"$list"
check "--list shows reportable yes and no" \
    bash -c 'grep -q "reportable: yes" <<<"$1" && grep -q "reportable: no" <<<"$1"' _ "$list"

# --- 3c. a second run adds no duplicate ----------------------------------
before=$(jq -c '[.problems[] | [.id, .occurrences]] | sort' "$PROBLEMS")
: >"$FIX/journalctl-calls"
collect
after=$(jq -c '[.problems[] | [.id, .occurrences]] | sort' "$PROBLEMS")
check "a second run with no new input changes no occurrence count" test "$before" = "$after"
check "the second run reads after the saved cursor, not 90 days" \
    bash -c "grep -qF -- '--after-cursor=e13' '$FIX/journalctl-calls' && ! grep -qF -- '--since=-90d' '$FIX/journalctl-calls'"

# A new crash entry of the same program: only that record grows.
crash_id=$(jq -r '.problems[] | select(.kind == "crash" and .reportable) | .id' "$PROBLEMS")
jq -c '.__CURSOR = "e14" | .__REALTIME_TIMESTAMP = ((.__REALTIME_TIMESTAMP | tonumber) + 60000000 | tostring)' \
    <(head -n1 "$FIX/events.json") >>"$FIX/events.json"
collect
check "a new crash entry adds 1 occurrence to its record" test "$(occurrences "$crash_id")" -eq 2
check "other records do not change" \
    test "$(jq -c --arg id "$crash_id" '[.problems[] | select(.id != $id) | [.id, .occurrences]] | sort' "$PROBLEMS")" = \
    "$(jq -c --arg id "$crash_id" '[.[] | select(.[0] != $id)]' <<<"$before")"

# A new stager result (a new checked_at) is a new S2 occurrence; the same
# file is not.
s2_id=$(jq -r '.problems[] | select(.kind == "update_stage_failed") | .id' "$PROBLEMS")
sed -i "s/^checked_at=.*/checked_at=$(date -u -d '-1 hour' --iso-8601=seconds)/" "$HROOT/run/snosi/update-check"
collect
check "a new failed stage result adds 1 occurrence" test "$(occurrences "$s2_id")" -eq 2

# A new updex run is a new S4 occurrence.
s4_id=$(jq -r '.problems[] | select(.detail.feature == "docker") | .id' "$PROBLEMS")
jq --arg at "$(date -u -d '-30 minutes' +%Y-%m-%dT%H:%M:%SZ)" '.finished = $at | .features[].at = $at' \
    "$HROOT/var/lib/updex/last-run.json" >"$WORK_DIR/lr" && mv "$WORK_DIR/lr" "$HROOT/var/lib/updex/last-run.json"
collect
check "a new updex run adds 1 occurrence" test "$(occurrences "$s4_id")" -eq 2
collect
check "an unchanged updex record adds no occurrence" test "$(occurrences "$s4_id")" -eq 2

# updex carries the previous entry of a feature, with its own at, into a run
# that names another feature. The file changes, but the old failure is not a
# new occurrence; the new feature's failure is.
jq --arg at "$(date -u -d '-20 minutes' +%Y-%m-%dT%H:%M:%SZ)" '
    .finished = $at | .selected = true
    | .features += [{feature: "k3s", origin: "catalog", outcome: "failed", error_class: "checksum",
                     version: "1.33.1", at: $at, transfers: []}]' \
    "$HROOT/var/lib/updex/last-run.json" >"$WORK_DIR/lr" && mv "$WORK_DIR/lr" "$HROOT/var/lib/updex/last-run.json"
collect
check "a carried updex entry with its old at adds no occurrence" test "$(occurrences "$s4_id")" -eq 2
check "the new feature of that run is recorded once" \
    test "$(jq '[.problems[] | select(.detail.feature == "k3s") | .occurrences] == [1]' "$PROBLEMS")" = true

# More fs-verity errors in the same boot move the record to the >10 bucket
# instead of adding a second record for the boot.
for i in $(seq 1 10); do
    jq -c --arg c "jx$i" '.__CURSOR = $c' <(sed -n 2p "$FIX/kernel.json") >>"$FIX/kernel.json"
done
collect
check "a bucket change in the same boot replaces the record" \
    test "$(count_of '.kind == "integrity_error" and .detail.subsystem == "fs-verity"')" -eq 1
check "the new bucket is >10" \
    detail_is '.kind == "integrity_error" and .detail.subsystem == "fs-verity"' '{"subsystem":"fs-verity","count":">10"}'
fs_id=$(jq -r '.problems[] | select(.detail.subsystem == "fs-verity") | .id' "$PROBLEMS")
check "the boot counts once" test "$(occurrences "$fs_id")" -eq 1

# A new boot with the same errors is a second occurrence.
echo '11111111-2222-4333-8444-555555555555' >"$HROOT/proc/sys/kernel/random/boot_id"
tpm_id=$(jq -r '.problems[] | select(.kind == "tpm_unlock") | .id' "$PROBLEMS")
collect
check "a new boot adds 1 occurrence to a boot-scoped record" test "$(occurrences "$fs_id")" -eq 2
check "a new boot adds 1 occurrence to the TPM record" test "$(occurrences "$tpm_id")" -eq 2
check "the boot ID stays out of problems.json" bash -c "! grep -qF 11111111 '$PROBLEMS'"
no_sentinels

# A held lock: the run exits 0 and writes nothing.
stamp=$(jq -r '.generated' "$PROBLEMS")
sleep 1
exec {held}>"$STATE/.lock"
flock -n "$held"
if out=$(run_health 2>&1) && [[ $out == *"not running concurrently"* ]] &&
        [[ $(jq -r '.generated' "$PROBLEMS") == "$stamp" ]]; then
    pass "a run that finds the lock held writes nothing"
else
    fail "a run that finds the lock held writes nothing ($out)"
fi
exec {held}>&-

# --- 3d. S5 variants -------------------------------------------------------
tpm_case() { # description expected-detail-or-empty jsonl-messages...
    local description=$1 expected=$2 i=0
    shift 2
    setup_fixture
    : >"$FIX/cryptsetup.json"
    for message in "$@"; do
        i=$((i + 1))
        jq -nc --arg m "$message" --arg c "k$i" --arg t "$(((now_s - 600 + i) * 1000000))" \
            '{__CURSOR: $c, __REALTIME_TIMESTAMP: $t, _UID: ($ENV.TPM_UID // "0"), MESSAGE: $m}' >>"$FIX/cryptsetup.json"
    done
    collect || return 0
    if [[ -z $expected ]]; then
        check "S5: $description" test "$(count_of '.kind == "tpm_unlock"')" -eq 0
    else
        check "S5: $description" detail_is '.kind == "tpm_unlock"' "$expected"
    fi
}
tpm_case "a clean first-try unlock is not recorded" '' \
    'Automatically discovered security TPM2 token unlocks volume luks-brian.'
tpm_case "a policy mismatch and a passphrase fallback" '{"outcome":"other","tpm_rc":"POLICY_FAIL","retries":0}' \
    'TPM policy does not match current system state. Either system has been tampered with or policy out-of-date: Operation not permitted' \
    'TPM2 operation failed, falling back to traditional unlocking: Operation not permitted'
tpm_case "a lockout fallback" '{"outcome":"other","tpm_rc":"LOCKOUT","retries":0}' \
    'TPM is in dictionary attack lock-out mode.' \
    'TPM2 operation failed, falling back to traditional unlocking: No locks available'
tpm_case "exhausted PCR retries" '{"outcome":"other","tpm_rc":"PCR_CHANGED","retries":0}' \
    'TPM2 operation failed, falling back to traditional unlocking: Structure needs cleaning'
tpm_case "the systemd debug retry text counts retries" '{"outcome":"ok_after_retry","tpm_rc":"PCR_CHANGED","retries":3}' \
    'A PCR value changed during the TPM2 policy session, restarting HMAC key unsealing (9 tries left).' \
    'A PCR value changed during the TPM2 policy session, restarting HMAC key unsealing (8 tries left).' \
    'A PCR value changed during the TPM2 policy session, restarting HMAC key unsealing (7 tries left).'
tpm_case "an ESYS POLICY_FAIL code" '{"outcome":"other","tpm_rc":"POLICY_FAIL","retries":0}' \
    'ERROR:esys:src/tss2-esys/api/Esys_Unseal.c:98:Esys_Unseal() Esys Finish ErrorCode (0x0000099d) ' \
    'TPM2 operation failed, falling back to traditional unlocking: Operation not permitted'
tpm_case "no TPM2 metadata for this boot state" '{"outcome":"other","tpm_rc":"POLICY_FAIL","retries":0}' \
    'No TPM2 metadata matching the current system state found in LUKS2 header, falling back to traditional unlocking.'
mapfile -t many < <(for _ in $(seq 1 14); do echo 'ERROR:esys:src/tss2-esys/api/Esys_PolicyPCR.c:103:Esys_PolicyPCR() Esys Finish ErrorCode (0x00000128) '; done)
tpm_case "retries are capped at 10" '{"outcome":"ok_after_retry","tpm_rc":"PCR_CHANGED","retries":10}' "${many[@]}"

TPM_UID=1000 tpm_case "a user entry with the fallback text is not recorded" '' \
    'TPM2 operation failed, falling back to traditional unlocking: Operation not permitted' \
    'ERROR:esys:src/tss2-esys/api/Esys_Unseal.c:98:Esys_Unseal() Esys Finish ErrorCode (0x00000128) '
check "every journalctl call reads only the system journal" \
    bash -c "! grep -v -- '--system' '$FIX/journalctl-calls' | grep -q ."
check "S5 asks journalctl for UID 0 only" grep -qE 'SYSLOG_IDENTIFIER=systemd-cryptsetup _UID=0' "$FIX/journalctl-calls"

# --- 3e. a stop between the renames loses nothing ------------------------
# Reference: one clean run.
setup_fixture
collect
ref=$(jq -c '[.problems[] | {key: .id, value: [.kind, .occurrences]}] | from_entries' "$PROBLEMS")
# A run that stops after the problems.json, details.json or state.json rename
# (the later files and the cursor stay old), then a normal run.
for fault in problems details state; do
    setup_fixture
    if PATH="$STUBS:$PATH" FIX="$FIX" SNOSI_HEALTH_TEST_HOOKS=1 SNOSI_HEALTH_TEST_ROOT="$HROOT" \
        SNOSI_HEALTH_TEST_FAULT=$fault "$COLLECTOR" >/dev/null 2>&1; then
        fail "the fault hook stops the run after the $fault rename"
        continue
    fi
    # A stop must leave the problems of this run already on disk.
    stopped_ids=$(jq -c '[.problems[].id] | sort' "$PROBLEMS" 2>/dev/null) || stopped_ids=null
    collect
    got=$(jq -c '[.problems[] | {key: .id, value: [.kind, .occurrences]}] | from_entries' "$PROBLEMS")
    check "after a stop at the $fault rename the next run loses no problem" \
        test "$(jq -n --argjson r "$ref" --argjson g "$got" --argjson s "$stopped_ids" \
            '($r | keys) == ($g | keys) and ($s == ($r | keys))')" = true
    check "after a stop at the $fault rename no event record counts twice" \
        test "$(jq -n --argjson r "$ref" --argjson g "$got" '
            [$r | to_entries[] | select(.value[0] | IN("update_stage_failed", "sysext_update_failed", "crash", "app_problem"))
             | .value[1] == $g[.key][1]] | all')" = true
    check "after a stop at the $fault rename a boot record over-counts by at most 1" \
        test "$(jq -n --argjson r "$ref" --argjson g "$got" '
            [$r | to_entries[] | select(.value[0] | IN("unit_failed", "booted_older_image", "tpm_unlock", "integrity_error"))
             | $g[.key][1] - .value[1] | . >= 0 and . <= 1] | all')" = true
    check "no temp file is left after a stop at the $fault rename and a new run" \
        test -z "$(find "$STATE" -name '.*.json.*' -o -name '.journal.cursor.*')"
done

# --- 3f. inputs that give no record --------------------------------------
setup_fixture
rm -f "$FIX/events.json" "$FIX/kernel.json" "$FIX/cryptsetup.json" "$FIX/units.json" "$FIX/bootc-status.json"
jq '.format = 2' "$FIX/last-run.json" >"$HROOT/var/lib/updex/last-run.json"
printf 'outcome=held-rollback\nchecked_at=2026-11-05T09:00:00+00:00\nimage=x\nrunning_version=1\nremote_version=2\n' \
    >"$HROOT/run/snosi/update-check"
collect
check "an unknown last-run format, held-rollback alone and empty journals give no record" \
    test "$(jq '.problems | length' "$PROBLEMS")" -eq 0
check "--list with an empty record says so" grep -qF 'No problems recorded' <<<"$(run_health --list)"

# held-rollback plus a newer rollback deployment: manual_rollback.
cp "$FIXTURES/base/bootc-status.json" "$FIX/bootc-status.json"
collect
check "S3: held-rollback with a newer rollback deployment is manual_rollback" \
    detail_is '.kind == "booted_older_image"' '{"newer_version":"20261104000000","how":"manual_rollback"}'

# An update-check without error_class (an older stager): recorded, not reportable.
printf 'outcome=failed\nchecked_at=2026-11-05T09:00:00+00:00\nimage=x\nrunning_version=1\nremote_version=20261104000000\n' \
    >"$HROOT/run/snosi/update-check"
collect
check "S2: no error_class key gives a record that is not reportable" \
    test "$(jq -c '[.problems[] | select(.kind == "update_stage_failed") | [.detail, .reportable]]' "$PROBLEMS")" = \
    '[[{"target_version":"20261104000000","bootc_version":"1.17.3"},false]]'
printf 'outcome=failed\nchecked_at=2026-11-05T10:00:00+00:00\nimage=x\nrunning_version=1\nremote_version=20261104000000\nerror_class=gremlins\n' \
    >"$HROOT/run/snosi/update-check"
collect
check "S2: an unknown error_class becomes other" \
    test "$(count_of '.kind == "update_stage_failed" and .detail.error_class == "other"')" -eq 1

# An unknown image id: nothing is reportable, and the envelope says why.
sed -i 's/^IMAGE_ID=.*/IMAGE_ID=debian/' "$HROOT/usr/lib/os-release"
collect
check "an image id outside the enum makes nothing reportable" \
    test "$(jq '[.problems[] | select(.reportable)] | length' "$PROBLEMS")" -eq 0
check "an image id outside the enum is stored as null" test "$(jq -c '.image.id' "$PROBLEMS")" = null
if validate_problems; then pass "records still validate with an unknown image id"; else fail "records still validate with an unknown image id"; fi

# --- 3g. pruning and re-sanitizing an older file -------------------------
setup_fixture
rm -f "$FIX/events.json" "$FIX/kernel.json" "$FIX/cryptsetup.json" "$FIX/units.json" "$FIX/bootc-status.json"
rm -f "$HROOT/run/snosi/update-check" "$HROOT/var/lib/updex/last-run.json"
mkdir -p "$STATE"
jq -n --argjson now "$now_s" '
    def rec($i; $age): {
        id: ("\($i + 1000000000000000)" | .[0:16] | gsub("[^0-9]"; "a")),
        kind: "integrity_error", detail: {subsystem: "fs-verity", count: "1"},
        week: "2026-W01",
        first_seen: (($now - $age) | todate), last_seen: (($now - $age) | todate),
        occurrences: 1, reportable: true};
    {format: 1, schema: "frostyard.problem/1", generated: ($now | todate), image: null, secure: false, client: null,
     problems: ([range(0; 250) | rec(.; . * 3600)]
                + [range(250; 255) | rec(.; 91 * 86400 + .)]
                + [{id: "ffffffffffffffff", kind: "unit_failed", detail: {unit: "user@1000.service", result: "exit-code", shipped: true, message: "/home/brian"},
                    week: "2026-W01", first_seen: ($now | todate), last_seen: ($now | todate), occurrences: 1, reportable: true, MESSAGE: "leak"}])}
' >"$PROBLEMS"
collect
check "at most 200 records are kept" test "$(jq '.problems | length' "$PROBLEMS")" -eq 200
check "records older than 90 days are dropped" \
    test "$(jq --argjson now "$now_s" '[.problems[] | select((.last_seen | fromdateiso8601) < $now - 90 * 86400)] | length' "$PROBLEMS")" -eq 0
check "the newest records are the ones kept" \
    test "$(jq --argjson now "$now_s" '[.problems[] | select((.last_seen | fromdateiso8601) < $now - 199 * 3600)] | length' "$PROBLEMS")" -eq 0
check "a previous record is re-sanitized (no extra key, no instance, no unknown field)" \
    test "$(jq -c '.problems[] | select(.id == "ffffffffffffffff") | [keys, .detail, .reportable]' "$PROBLEMS")" = \
    '[["detail","first_seen","id","kind","last_seen","occurrences","reportable","week"],{"result":"exit-code","shipped":true},false]'
no_sentinels
if validate_problems; then pass "pruned records validate"; else fail "pruned records validate"; fi

printf '# Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ $FAIL -eq 0 ]]
