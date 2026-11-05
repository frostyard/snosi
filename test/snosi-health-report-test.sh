#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Fixture suite for Floe's problem-report sender (ADR-0030): the static
# contract of the Floe tree (the sender, its units, its preset and the motd
# line) and the behaviour of shared/snosi-report/tree/usr/libexec/snosi-health-report.
# The intake is a fake HTTP server on 127.0.0.1 that logs every request and
# answers with the status of a fixture file. Sends run against a scratch root
# with copies of the collector and the sender and the paired collector hooks
# (SNOSI_HEALTH_TEST_HOOKS=1 and SNOSI_HEALTH_TEST_ROOT) plus the sender's own
# SNOSI_HEALTH_TEST_NOW and SNOSI_HEALTH_TEST_PACE.
# No root, no image build, and no network other than 127.0.0.1.
# shellcheck disable=SC2016 # some checks match literal shell source
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COLLECTOR="$ROOT_DIR/mkosi.images/base/mkosi.extra/usr/bin/snosi-health"
REPORT_TREE="$ROOT_DIR/shared/snosi-report/tree"
SENDER="$REPORT_TREE/usr/libexec/snosi-health-report"
UNIT_DIR="$REPORT_TREE/usr/lib/systemd/system"
SERVICE="$UNIT_DIR/snosi-health-report.service"
TIMER="$UNIT_DIR/snosi-health-report.timer"
PRESET="$REPORT_TREE/usr/lib/systemd/system-preset/06-snosi-health-report.preset"
MOTD="$REPORT_TREE/etc/update-motd.d/87-snosi-health-reporting"
ADR="$ROOT_DIR/docs/adr/0030-floe-sends-problem-reports-with-admin-consent.md"
SCHEMA="$ROOT_DIR/test/fixtures/snosi-health/schema/v1.json"
EXAMPLES="$ROOT_DIR/test/fixtures/snosi-health/schema/examples"
VALIDATOR="$ROOT_DIR/test/lib/json_schema_subset.py"

WORK_DIR="$(mktemp -d)"
RROOT="$WORK_DIR/root"
STATE="$RROOT/var/lib/snosi-health"
CONF="$RROOT/etc/snosi-health/reporting.conf"
SENT="$STATE/sent.jsonl"
SRV="$WORK_DIR/intake"
STUBS="$WORK_DIR/bin"
SERVER_PID=""

cleanup() {
    if [[ -n $SERVER_PID ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    chmod -R u+rwX "$WORK_DIR" 2>/dev/null || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

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
neg() { # description command...
    local description=$1
    shift
    if "$@"; then fail "$description"; else pass "$description"; fi
}

# jq_ok FILTER FILE -- every JSON value of FILE (1 per line) passes FILTER.
jq_ok() { jq -e -s "$1" "$2" >/dev/null 2>&1; }

# schema_ok FILE -- every line of FILE is 1 valid frostyard.problem/1 document.
schema_ok() {
    python3 - "$SCHEMA" "$VALIDATOR" "$1" <<'PY'
import importlib.util
import json
import sys

spec = importlib.util.spec_from_file_location("v", sys.argv[2])
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)
schema = json.load(open(sys.argv[1]))
bad = []
count = 0
for number, line in enumerate(open(sys.argv[3]), 1):
    line = line.strip()
    if not line:
        continue
    count += 1
    try:
        doc = json.loads(line)
    except ValueError as error:
        bad.append(f"line {number}: not JSON ({error})")
        continue
    for error in v.validate(schema, doc):
        bad.append(f"line {number}: {error}")
if count == 0:
    bad.append("no document")
for line in bad:
    print(line, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
}

unit_has() { grep -qxF -- "$2" "$1"; }
unit_lacks_re() { ! grep -qE -- "$2" "$1"; }

tracked_files() { git -C "$ROOT_DIR" ls-files --cached --others --exclude-standard; }

# --- 1. the static contract ------------------------------------------------

outside=$(tracked_files | grep -F 'snosi-health-report' |
    grep -vE '^(shared/snosi-report/tree/|docs/|test/|\.github/)' || true)
check "only the Floe report tree, docs, test and CI name snosi-health-report${outside:+ ($outside)}" \
    test -z "$outside"

payload_consent=$(tracked_files | grep -E '(^|/)mkosi\.extra/|^shared/[^/]+/tree/' |
    grep -F 'etc/snosi-health/' || true)
check "no image payload ships a path under etc/snosi-health${payload_consent:+ ($payload_consent)}" \
    test -z "$payload_consent"

foreign_presets=$(tracked_files | grep -E '\.preset$' | grep -vE '^shared/snosi-report/tree/' |
    xargs -r grep -lE '^[[:space:]]*enable[[:space:]]+snosi-health-report\.timer' 2>/dev/null || true)
check "no preset outside the Floe report tree enables the report timer${foreign_presets:+ ($foreign_presets)}" \
    test -z "$foreign_presets"

# Only mkosi configuration can add a tree; this test file names the line too.
report_trees=$(git -C "$ROOT_DIR" grep -F -l 'ExtraTrees=%D/shared/snosi-report/tree' -- '*.conf' |
    grep -vx 'shared/composition/floe/mkosi.conf' || true)
check "only shared/composition/floe/mkosi.conf adds the report tree${report_trees:+ ($report_trees)}" \
    test -z "$report_trees"

check "the sender is executable" test -x "$SENDER"
check "the motd hook is executable" test -x "$MOTD"
check "the service is gated on the consent file" \
    grep -qxF 'ConditionPathExists=/etc/snosi-health/reporting.conf' "$SERVICE"

check "service is a oneshot" unit_has "$SERVICE" 'Type=oneshot'
check "service runs the sender" unit_has "$SERVICE" 'ExecStart=/usr/libexec/snosi-health-report send'
check "service uses StateDirectory=snosi-health" unit_has "$SERVICE" 'StateDirectory=snosi-health'
check "service creates the state dir 0755" unit_has "$SERVICE" 'StateDirectoryMode=0755'
check "service runs at nice 19" unit_has "$SERVICE" 'Nice=19'
check "service runs at idle I/O priority" unit_has "$SERVICE" 'IOSchedulingClass=idle'
check "service has a start timeout" unit_has "$SERVICE" 'TimeoutStartSec=15min'
check "service hardens the filesystem" unit_has "$SERVICE" 'ProtectSystem=strict'
check "service has no home" unit_has "$SERVICE" 'ProtectHome=yes'
check "service uses a private tmp" unit_has "$SERVICE" 'PrivateTmp=yes'
check "service sets NoNewPrivileges" unit_has "$SERVICE" 'NoNewPrivileges=yes'
check "service allows only the address families a send needs" \
    unit_has "$SERVICE" 'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6'
check "service orders after the network" unit_has "$SERVICE" 'After=network-online.target'
check "service wants the network" unit_has "$SERVICE" 'Wants=network-online.target'
check "service documents ADR-0030" \
    unit_has "$SERVICE" 'Documentation=https://github.com/frostyard/snosi/blob/main/docs/adr/0030-floe-sends-problem-reports-with-admin-consent.md'
check "service has no [Install] section" unit_lacks_re "$SERVICE" '^\[Install\]'
check "service has no Before=" unit_lacks_re "$SERVICE" '^Before='
check "timer runs daily" unit_has "$TIMER" 'OnCalendar=daily'
check "timer randomizes its run" unit_has "$TIMER" 'RandomizedDelaySec=4h'
check "timer catches up a missed day" unit_has "$TIMER" 'Persistent=true'
check "timer is wanted by timers.target only" \
    test "$(grep -E '^(WantedBy|RequiredBy|UpheldBy|Alias)=' "$TIMER")" = 'WantedBy=timers.target'
check "timer has no Before=" unit_lacks_re "$TIMER" '^Before='
check "06-snosi-health-report.preset enables the report timer" \
    unit_has "$PRESET" 'enable snosi-health-report.timer'
check "the preset says the sender gates on consent" \
    grep -qF 'gates on the consent file' "$PRESET"
neg "the sender enables no unit at runtime" \
    bash -c "grep -vE '^[[:space:]]*#' '$SENDER' | grep -qE 'systemctl[[:space:]]+(enable|disable)'"
neg "the sender follows no redirect" \
    grep -qE -- '(^|[[:space:]])-(L|--location)([[:space:]]|$)' "$SENDER"
check "the sender never posts a crash report" \
    grep -qF 'readonly REPORT_KINDS=' "$SENDER"
neg "the crash kind is not in the sendable kinds" \
    grep -qF '"crash"' <(grep -F 'readonly REPORT_KINDS=' "$SENDER")

help=$("$SENDER" --help)
check "--help says reporting is off by default" grep -qF 'off by default' <<<"$help"
check "--help names the privacy URL" grep -qF 'https://frostyard.org/privacy/problem-reports/' <<<"$help"
check "--help names the sent record" grep -qF '/var/lib/snosi-health/sent.jsonl' <<<"$help"
check "--help explains the daily limit and the weekly count" grep -qF 'at most 20 problem reports a day and 1 count a week' <<<"$help"
check "--help says a dry run sends nothing" grep -qF 'send --dry-run' <<<"$help"
check "--help says crash reports stay local" grep -qF 'Crash reports stay local' <<<"$help"
check "--help keeps the test hooks out" bash -c "! grep -q SNOSI_HEALTH <<<\"\$1\"" _ "$help"
check "ADR-0030 exists" test -f "$ADR"
check "ADR-0030 names the sender path" \
    grep -qF 'shared/snosi-report/tree/usr/libexec/snosi-health-report' "$ADR"
check "ADR-0030 names the report timer" grep -qF 'snosi-health-report.timer' "$ADR"
check "the units document ADR-0030" \
    grep -qF 'docs/adr/0030-floe-sends-problem-reports-with-admin-consent.md' "$SERVICE"

# --- 2. the fake intake on 127.0.0.1 ---------------------------------------

mkdir -p "$SRV" "$STUBS"
: >"$SRV/requests.jsonl"
printf '202\n' >"$SRV/status"

python3 - "$SRV" <<'PY' &
import http.server
import json
import os
import socketserver
import sys

directory = sys.argv[1]


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        record = {
            "method": self.command,
            "path": self.path,
            "headers": {key.lower(): value for key, value in self.headers.items()},
            "body": body.decode("utf-8", "replace"),
        }
        with open(os.path.join(directory, "requests.jsonl"), "a", encoding="utf-8") as log:
            log.write(json.dumps(record) + "\n")
        try:
            with open(os.path.join(directory, "status"), encoding="utf-8") as handle:
                status = int(handle.read().strip())
        except (OSError, ValueError):
            status = 202
        payload = json.dumps({"status": "accepted"}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


class Server(socketserver.TCPServer):
    allow_reuse_address = True


server = Server(("127.0.0.1", 0), Handler)
with open(os.path.join(directory, "port"), "w", encoding="utf-8") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
PY
SERVER_PID=$!

for _ in $(seq 1 100); do
    [[ -s $SRV/port ]] && break
    sleep 0.1
done
check "the fake intake listens on 127.0.0.1" test -s "$SRV/port"
PORT=$(cat "$SRV/port")
ENDPOINT="http://127.0.0.1:$PORT/v1/report"

requests() { wc -l <"$SRV/requests.jsonl" | tr -d ' '; }
reset_requests() { : >"$SRV/requests.jsonl"; }
# The log holds each body as an escaped JSON string, so a search looks at the
# decoded body, not at the log line.
requests_have() { jq -r '.body' "$SRV/requests.jsonl" | grep -qF -- "$1"; }
count_bodies() { jq -r '.body' "$SRV/requests.jsonl" | grep -cF -- '"kind":"count"' || true; }
bodies() { jq -r '.body' "$SRV/requests.jsonl"; }

# --- 3. the fixtures -------------------------------------------------------

# A bootc stub: its status JSON comes from a file, so a case can change the
# image tag.
cat >"$STUBS/bootc" <<'STUB'
#!/bin/bash
case $1 in
    status) cat "$BOOTC_STATUS_FILE" 2>/dev/null || exit 1 ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$STUBS/bootc"
BOOTC_STATUS_FILE="$WORK_DIR/bootc-status.json"
export BOOTC_STATUS_FILE
bootc_tag() { # tag
    printf '{"spec":{"image":{"image":"ghcr.io/frostyard/floe:%s"}}}\n' "$1" >"$BOOTC_STATUS_FILE"
}
bootc_tag latest

# NOW is a Tuesday, so +1 day is the same ISO week and +7 days is the next one.
NOW_FIXED=$(date -u -d '2026-11-03T12:00:00Z' +%s)
check "the fixed NOW is a Tuesday" test "$(date -u -d "@$NOW_FIXED" +%u)" = 2

write_problems() {
    jq -n '
      def rec($id; $kind; $detail; $last; $reportable):
        {id: $id, kind: $kind, detail: $detail, week: "2026-W45",
         first_seen: $last, last_seen: $last, occurrences: 1, reportable: $reportable};
      {format: 1, schema: "frostyard.problem/1", generated: "2026-11-03T11:00:00Z",
       image: {id: "floe", version: "20261101120000"}, secure: false,
       client: "snosi-health/20261101120000",
       problems: [
         rec("1111111111111111"; "unit_failed";
             {unit: "docker.service", result: "exit-code", shipped: true}; "2026-11-01T01:00:00Z"; true),
         rec("2222222222222222"; "update_stage_failed";
             {target_version: "20261104000000", error_class: "network", bootc_version: "1.17.3"}; "2026-11-01T02:00:00Z"; true),
         rec("3333333333333333"; "tpm_unlock";
             {outcome: "ok_after_retry", tpm_rc: "PCR_CHANGED", retries: 2}; "2026-11-01T03:00:00Z"; true),
         rec("4444444444444444"; "crash";
             {exe: "gnome-shell", signal: "SIGSEGV"}; "2026-11-01T04:00:00Z"; true),
         rec("5555555555555555"; "unit_failed";
             {result: "exit-code"}; "2026-11-01T05:00:00Z"; false),
         rec("6666666666666666"; "sysext_update_failed";
             {feature: "docker", version: "29.0.1", outcome: "failed", error_class: "network"}; "2026-11-01T06:00:00Z"; true),
         rec("7777777777777777"; "integrity_error";
             {subsystem: "fs-verity", count: "1"}; "2026-11-01T07:00:00Z"; true),
         rec("8888888888888888"; "app_problem";
             {app_id: "org.frostyard.nsl", app_version: "0.9.2", runtime: "go", component: "daemon",
              class: "error", code: "store.migrate_failed"}; "2026-11-01T08:00:00Z"; true)
       ]}
    ' >"$1"
}

# 25 reportable unit_failed records with distinct ids.
write_problems_25() {
    jq -n '
      [range(25) as $i
       | {id: (("abc000000000000" + ($i | tostring)) | .[-16:]),
          kind: "unit_failed",
          detail: {unit: ("svc" + ($i | tostring) + ".service"), result: "exit-code", shipped: true},
          week: "2026-W45",
          first_seen: "2026-11-01T00:00:00Z", last_seen: "2026-11-01T00:00:00Z",
          occurrences: 1, reportable: true}]
      | {format: 1, schema: "frostyard.problem/1", generated: "2026-11-03T11:00:00Z",
         image: {id: "floe", version: "20261101120000"}, secure: false,
         client: "snosi-health/20261101120000", problems: .}
    ' >"$1"
}

reset_root() {
    [[ -e $RROOT ]] && chmod -R u+rwX "$RROOT" 2>/dev/null
    rm -rf "$RROOT"
    mkdir -p "$RROOT/usr/bin" "$RROOT/usr/libexec" "$RROOT/etc" "$STATE"
    cp "$COLLECTOR" "$RROOT/usr/bin/snosi-health"
    cp "$SENDER" "$RROOT/usr/libexec/snosi-health-report"
    chmod 0755 "$RROOT/usr/bin/snosi-health" "$RROOT/usr/libexec/snosi-health-report"
    printf '0123456789abcdef0123456789abcdef\n' >"$RROOT/etc/machine-id"
}

write_conf() { # enabled schema [endpoint]
    mkdir -p "$(dirname -- "$CONF")"
    {
        printf '# fixture consent\n'
        printf 'enabled=%s\n' "$1"
        printf 'schema=%s\n' "$2"
        printf 'decided_at=2026-11-03T10:00:00Z\n'
        if [[ $# -ge 3 ]]; then
            printf 'endpoint=%s\n' "$3"
        fi
    } >"$CONF"
    chmod 0644 "$CONF"
}

consent_on() { write_conf 1 frostyard.problem/1 "$ENDPOINT"; }
consent_off() { write_conf 0 frostyard.problem/1 "$ENDPOINT"; }

conf_has() { grep -qxF -- "$1" "$CONF"; }
neg_has_sent() { ! grep -qF -- "$1" "$SENT"; }
conf_lacks_re() { ! grep -qE -- "$1" "$CONF"; }

OUT=""
SEND_RC=0
ERR_FILE="$WORK_DIR/stderr.txt"

run_sender() { # now args...
    local now=$1
    shift
    PATH="$STUBS:$PATH" SNOSI_HEALTH_TEST_HOOKS=1 SNOSI_HEALTH_TEST_ROOT="$RROOT" \
        SNOSI_HEALTH_TEST_NOW="$now" SNOSI_HEALTH_TEST_PACE=0 \
        "$RROOT/usr/libexec/snosi-health-report" "$@"
}

send_now() { # now [send args...]
    local now=$1
    shift
    SEND_RC=0
    OUT=$(run_sender "$now" send "$@" 2>"$ERR_FILE") || SEND_RC=$?
}

mode_of() { stat -c %a "$1"; }

# --- 4. consent, status and the off gate -----------------------------------

reset_root
reset_requests
send_now "$NOW_FIXED"
check "with no consent file a send posts nothing" test "$(requests)" -eq 0
check "with no consent file a send exits 0" test "$SEND_RC" -eq 0
check "with no consent file a send says reporting is off" \
    grep -qF 'problem reporting is off; nothing sent' <<<"$OUT"
check "with no consent file no sent record appears" test ! -e "$SENT"

reset_root
OUT=$(run_sender "$NOW_FIXED" reporting status)
check "status without a consent file says off (not chosen yet)" \
    grep -qxF 'off (not chosen yet)' <<<"$OUT"
check "status names the default endpoint" grep -qF 'https://report.frostyard.org/v1/report' <<<"$OUT"
check "status prints the sent count and the pending count" \
    bash -c '[ "$(grep -cE "^(sent reports|reports a send posts now): [0-9?]+$" <<<"$1")" = 2 ]' _ "$OUT"

reset_root
OUT=$(run_sender "$NOW_FIXED" reporting off)
check "reporting off works without a consent file" \
    grep -qF 'Problem reporting is off. Nothing is sent.' <<<"$OUT"
check "reporting off writes enabled=0" conf_has 'enabled=0'
check "reporting off writes the schema" conf_has 'schema=frostyard.problem/1'
check "reporting off writes the decision time" conf_has 'decided_at=2026-11-03T12:00:00Z'
check "reporting off writes no endpoint line" conf_lacks_re '^endpoint='
check "the consent file is mode 0644" test "$(mode_of "$CONF")" = 644
check "the consent directory is mode 0755" test "$(mode_of "$RROOT/etc/snosi-health")" = 755
before=$(cat "$CONF")
OUT=$(run_sender "$NOW_FIXED" reporting off)
check "reporting off again keeps the same file" test "$(cat "$CONF")" = "$before"
check "reporting off never deletes the file" test -f "$CONF"

reset_root
consent_off
write_problems "$STATE/problems.json"
reset_requests
send_now "$NOW_FIXED"
check "consent off posts nothing" test "$(requests)" -eq 0
check "consent off says nothing was sent" grep -qF 'problem reporting is off; nothing sent' <<<"$OUT"

reset_root
consent_off
OUT=$(run_sender "$NOW_FIXED" reporting on)
check "reporting on says the timer sends once a day" \
    grep -qF 'snosi-health-report.timer sends reportable problems and a weekly count once a day.' <<<"$OUT"
check "reporting on prints the privacy URL" \
    grep -qF 'Privacy: https://frostyard.org/privacy/problem-reports/' <<<"$OUT"
check "reporting on prints the preview command" grep -qF 'snosi-health send --dry-run' <<<"$OUT"
check "reporting on writes enabled=1" conf_has 'enabled=1'
check "reporting on keeps the endpoint across the change" conf_has "endpoint=$ENDPOINT"
check "reporting on writes a comment header with the privacy URL" \
    grep -qF "# Privacy: https://frostyard.org/privacy/problem-reports/" "$CONF"
OUT=$(run_sender "$NOW_FIXED" reporting off)
check "reporting off keeps the endpoint too" conf_has "endpoint=$ENDPOINT"
check "reporting off sets enabled=0" conf_has 'enabled=0'

reset_root
consent_on
write_problems "$STATE/problems.json"
OUT=$(run_sender "$NOW_FIXED" reporting status)
check "status says on with the consent date" \
    grep -qxF 'on (consent for frostyard.problem/1 since 2026-11-03T10:00:00Z)' <<<"$OUT"
check "status names the configured endpoint" grep -qxF "endpoint: $ENDPOINT" <<<"$OUT"
check "status counts the reports a send would post" \
    grep -qxF 'reports a send posts now: 7' <<<"$OUT"

reset_root
write_conf 1 'frostyard.problem/0' "$ENDPOINT"
write_problems "$STATE/problems.json"
reset_requests
OUT=$(run_sender "$NOW_FIXED" reporting status)
check "status says consent was given for another schema" \
    grep -qF 'off (consent was given for frostyard.problem/0; run sudo snosi-health reporting on to agree to frostyard.problem/1)' <<<"$OUT"
send_now "$NOW_FIXED"
check "consent for another schema posts nothing" test "$(requests)" -eq 0

reset_root
write_conf 1 frostyard.problem/1 'ftp:/not a url'
write_problems "$STATE/problems.json"
send_now "$NOW_FIXED"
check "an invalid endpoint line makes a send fail" test "$SEND_RC" -eq 1
check "an invalid endpoint line posts nothing" test "$(requests)" -eq 0
check "an invalid endpoint names the consent file" grep -qF 'is not a plain http(s) URL' "$ERR_FILE"

reset_root
SEND_RC=0
OUT=$(run_sender "$NOW_FIXED" reporting 2>"$ERR_FILE") || SEND_RC=$?
check "reporting without an argument exits 2" test "$SEND_RC" -eq 2
check "reporting without an argument prints the usage" grep -qF 'Usage: snosi-health reporting' "$ERR_FILE"
SEND_RC=0
OUT=$(run_sender "$NOW_FIXED" send --bogus 2>"$ERR_FILE") || SEND_RC=$?
check "an unknown send argument exits 2" test "$SEND_RC" -eq 2

check "the sender refuses a bad test clock" \
    bash -c "! SNOSI_HEALTH_TEST_HOOKS=1 SNOSI_HEALTH_TEST_ROOT='$RROOT' SNOSI_HEALTH_TEST_NOW=soon '$RROOT/usr/libexec/snosi-health-report' reporting status"
check "the sender refuses a bad test pace" \
    bash -c "! SNOSI_HEALTH_TEST_HOOKS=1 SNOSI_HEALTH_TEST_ROOT='$RROOT' SNOSI_HEALTH_TEST_PACE=99 '$RROOT/usr/libexec/snosi-health-report' reporting status"

# --- 5. the dry run --------------------------------------------------------

for state in off on; do
    reset_root
    if [[ $state == on ]]; then consent_on; else consent_off; fi
    write_problems "$STATE/problems.json"
    reset_requests
    send_now "$NOW_FIXED" --dry-run
    printf '%s\n' "$OUT" >"$WORK_DIR/dry.txt"
    check "dry run ($state): every line is a valid frostyard.problem/1 report" \
        schema_ok "$WORK_DIR/dry.txt"
    check "dry run ($state): 6 problems and 1 count" test "$(wc -l <"$WORK_DIR/dry.txt" | tr -d ' ')" -eq 7
    check "dry run ($state): the weekly count is present" \
        grep -qF '"kind":"count"' "$WORK_DIR/dry.txt"
    neg "dry run ($state): no crash report is printed" \
        grep -qF '"kind":"crash"' "$WORK_DIR/dry.txt"
    jq -r '.report_id' "$WORK_DIR/dry.txt" >"$WORK_DIR/dry-ids.txt"
    check "dry run ($state): 0 requests" test "$(requests)" -eq 0
    check "dry run ($state): no sent record" test ! -e "$SENT"
    check "dry run ($state): says nothing was sent" grep -qF 'nothing was sent' "$ERR_FILE"
    check "dry run ($state): says a real send makes new report_ids" \
        grep -qF 'report_id above is new in this preview' "$ERR_FILE"
done
reset_root
consent_off
write_problems "$STATE/problems.json"
send_now "$NOW_FIXED" --dry-run
check "dry run while off says a real send now sends nothing" \
    grep -qF 'problem reporting is off; a real send now sends nothing' "$ERR_FILE"

# --- 6. a real send --------------------------------------------------------

reset_root
consent_on
write_problems "$STATE/problems.json"
reset_requests
send_now "$NOW_FIXED"
check "a real send exits 0" test "$SEND_RC" -eq 0
check "a real send posts the 6 reportable non-crash problems and 1 count" test "$(requests)" -eq 7
bodies >"$WORK_DIR/bodies.txt"
check "every posted body is a valid frostyard.problem/1 report" schema_ok "$WORK_DIR/bodies.txt"
neg "no posted body is a crash report" grep -qF '"kind":"crash"' "$WORK_DIR/bodies.txt"
check "the count is posted" grep -qF '"kind":"count"' "$WORK_DIR/bodies.txt"
check "every request is a POST to /v1/report" \
    jq_ok 'all(.[]; .method == "POST" and .path == "/v1/report")' "$SRV/requests.jsonl"
check "every request is application/json" \
    jq_ok 'all(.[]; .headers["content-type"] == "application/json")' "$SRV/requests.jsonl"
check "no request carries a User-Agent header" \
    jq_ok 'all(.[]; (.headers | has("user-agent")) | not)' "$SRV/requests.jsonl"
jq -r '.report_id' "$WORK_DIR/bodies.txt" >"$WORK_DIR/ids.txt"
check "every report_id is a UUIDv4" \
    bash -c "! grep -vqE '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\$' '$WORK_DIR/ids.txt'"
check "every report has its own report_id" \
    test "$(sort -u "$WORK_DIR/ids.txt" | wc -l | tr -d ' ')" -eq 7
check "a real send makes new report_ids, not the dry run's" \
    test -z "$(sort "$WORK_DIR/dry-ids.txt" | comm -12 - <(sort "$WORK_DIR/ids.txt"))"
check "sent.jsonl is mode 0644" test "$(mode_of "$SENT")" = 644
check "sent.jsonl has 1 line for each request" \
    test "$(wc -l <"$SENT" | tr -d ' ')" -eq 7
check "sent.jsonl carries the posted report_ids" \
    test "$(jq -r '.report.report_id' "$SENT" | sort | tr '\n' ' ')" = "$(sort "$WORK_DIR/ids.txt" | tr '\n' ' ')"
check "every sent line records the intake's answer" \
    jq_ok 'all(.[]; .status == "accepted" and .http_status == 202 and (.sent_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")))' "$SENT"
check "every sent line names its problem, and the count has none" \
    test "$(jq -r '.problem_id // "count"' "$SENT" | paste -sd, -)" = \
    '1111111111111111,2222222222222222,3333333333333333,6666666666666666,7777777777777777,8888888888888888,count'
check "the run logs each sent report" \
    bash -c '[ "$(grep -cE "^snosi-health: sent [a-z_]+ [0-9a-f-]{36} \(202\)\$" <<<"$1")" = 7 ]' _ "$OUT"

reset_requests
send_now "$NOW_FIXED"
check "a second send on the same day posts nothing" test "$(requests)" -eq 0

# --- 7. the daily limit and the weekly count -------------------------------

reset_root
consent_on
write_problems_25 "$STATE/problems.json"
reset_requests
send_now "$NOW_FIXED"
check "the first day posts 20 problems and 1 count" test "$(requests)" -eq 21
check "the first day posts the count once" test "$(count_bodies)" -eq 1
reset_requests
send_now "$NOW_FIXED"
check "a second send the same day posts nothing" test "$(requests)" -eq 0
reset_requests
send_now $((NOW_FIXED + 86400))
check "the next day posts the 5 remaining problems" test "$(requests)" -eq 5
neg "the next day posts no count" requests_have '"kind":"count"'
reset_requests
send_now $((NOW_FIXED + 7 * 86400))
check "a week later posts only the count" test "$(requests)" -eq 1
check "the report of that week is the count" requests_have '"kind":"count"'

# --- 8. transient and permanent intake answers -----------------------------

reset_root
consent_on
write_problems "$STATE/problems.json"
reset_requests
printf '503\n' >"$SRV/status"
send_now "$NOW_FIXED"
check "a 503 stops the run after 1 request" test "$(requests)" -eq 1
check "a 503 exits 0" test "$SEND_RC" -eq 0
check "a 503 records nothing" test ! -e "$SENT"
check "a 503 warns about the next run" grep -qF 'stopping this run, the next daily run tries again' "$ERR_FILE"
printf '202\n' >"$SRV/status"
reset_requests
send_now "$NOW_FIXED"
check "after a 503 the next run posts all 7" test "$(requests)" -eq 7

reset_root
consent_on
write_problems "$STATE/problems.json"
reset_requests
printf '400\n' >"$SRV/status"
send_now "$NOW_FIXED"
check "a 400 records every document as rejected" \
    jq_ok 'all(.[]; .status == "rejected" and .http_status == 400)' "$SENT"
printf '202\n' >"$SRV/status"
reset_requests
send_now "$NOW_FIXED"
check "a rejected document is not sent again" test "$(requests)" -eq 0

# --- 8b. the 90-day pruning of sent.jsonl ----------------------------------

reset_root
consent_on
write_problems "$STATE/problems.json"
reset_requests
{
    printf '{"sent_at":"2026-01-01T00:00:00Z","status":"rejected","http_status":400,"problem_id":"9999999999999999","report":{"kind":"unit_failed","week":"2026-W01","report_id":"00000000-0000-4000-8000-000000000000"}}\n'
    printf 'this line is not JSON\n'
} >"$SENT"
chmod 0644 "$SENT"
send_now "$NOW_FIXED"
check "an entry older than 90 days is dropped" neg_has_sent '9999999999999999'
check "a line that is not JSON is dropped" neg_has_sent 'this line is not JSON'
check "the entries of this run stay" test "$(wc -l <"$SENT" | tr -d ' ')" -eq 7

# --- 9. install_age and channel -------------------------------------------

reset_root
consent_on
write_problems "$STATE/problems.json"
reset_requests
real_now=$(date -u +%s)
send_now "$real_now"
bodies >"$WORK_DIR/bodies.txt"
check "the count says this install is under a week old" \
    test "$(jq -r 'select(.kind == "count") | .detail.install_age' "$WORK_DIR/bodies.txt")" = '<1w'
check "a :latest image is channel latest" \
    test "$(jq -r 'select(.kind == "count") | .detail.channel' "$WORK_DIR/bodies.txt")" = latest

reset_root
consent_on
write_problems "$STATE/problems.json"
reset_requests
send_now $((real_now + 200 * 86400))
bodies >"$WORK_DIR/bodies.txt"
check "after 200 days the count says the install is 6 months old" \
    test "$(jq -r 'select(.kind == "count") | .detail.install_age' "$WORK_DIR/bodies.txt")" = '>=6m'

reset_root
consent_on
write_problems "$STATE/problems.json"
reset_requests
bootc_tag 20261101120000
send_now "$real_now"
bodies >"$WORK_DIR/bodies.txt"
check "a fixed tag is channel other" \
    test "$(jq -r 'select(.kind == "count") | .detail.channel' "$WORK_DIR/bodies.txt")" = other
bootc_tag latest

reset_root
consent_on
write_problems "$STATE/problems.json"
reset_requests
mv "$STUBS/bootc" "$STUBS/bootc.off"
send_now "$real_now"
bodies >"$WORK_DIR/bodies.txt"
check "an absent bootc is channel other" \
    test "$(jq -r 'select(.kind == "count") | .detail.channel' "$WORK_DIR/bodies.txt")" = other

# bootc status needs root, so a dry run by another user falls back to the
# image= key of the stager's world-readable update-check.
reset_root
consent_on
write_problems "$STATE/problems.json"
mkdir -p "$RROOT/run/snosi"
printf 'outcome=current\nimage=ghcr.io/frostyard/floe:latest\n' >"$RROOT/run/snosi/update-check"
reset_requests
send_now "$real_now"
bodies >"$WORK_DIR/bodies.txt"
check "without bootc status, update-check image= gives channel latest" \
    test "$(jq -r 'select(.kind == "count") | .detail.channel' "$WORK_DIR/bodies.txt")" = latest
mv "$STUBS/bootc.off" "$STUBS/bootc"

# --- 10. the motd hook -----------------------------------------------------

sed "s#/etc/snosi-health/reporting.conf#$CONF#" "$MOTD" >"$WORK_DIR/motd"
chmod +x "$WORK_DIR/motd"
reset_root
check "the motd hook prints the off line with no consent file" \
    grep -qF 'Problem reporting is off. See `snosi-health reporting --help`.' <(sh "$WORK_DIR/motd")
write_conf 0 frostyard.problem/1 "$ENDPOINT"
check "the motd hook prints nothing with enabled=0" \
    test -z "$(sh "$WORK_DIR/motd")"
write_conf 1 frostyard.problem/1 "$ENDPOINT"
check "the motd hook prints nothing with enabled=1" test -z "$(sh "$WORK_DIR/motd")"

# --- 11. the base collector dispatch and the 1 validator -------------------

reset_root
OUT=$(PATH="$STUBS:$PATH" SNOSI_HEALTH_TEST_HOOKS=1 SNOSI_HEALTH_TEST_ROOT="$RROOT" \
    "$RROOT/usr/bin/snosi-health" reporting status 2>&1)
check "the collector dispatches reporting to the Floe sender" \
    grep -qxF 'off (not chosen yet)' <<<"$OUT"

reset_root
rm -f "$RROOT/usr/libexec/snosi-health-report"
SEND_RC=0
OUT=$(PATH="$STUBS:$PATH" SNOSI_HEALTH_TEST_HOOKS=1 SNOSI_HEALTH_TEST_ROOT="$RROOT" \
    "$RROOT/usr/bin/snosi-health" send --dry-run 2>&1) || SEND_RC=$?
check "without the sender the collector exits 1" test "$SEND_RC" -eq 1
check "without the sender the collector names the other products" \
    grep -qF "problem reporting is not part of this image. On Snow, Snowfield and Sundog, ChairLift's Problems page sends reports." <<<"$OUT"

help=$("$COLLECTOR" --help)
check "--help documents --validate" grep -qF -- '--validate' <<<"$help"
check "--help documents the Floe reporting command" grep -qF 'reporting on|off|status (Floe)' <<<"$help"
check "--help documents the Floe send command" grep -qF 'send [--dry-run] (Floe)' <<<"$help"

cat "$EXAMPLES"/*.json | "$COLLECTOR" --validate >"$WORK_DIR/valid.txt" 2>"$ERR_FILE"
check "--validate accepts the 9 core examples" test "$(wc -l <"$WORK_DIR/valid.txt" | tr -d ' ')" -eq 9
check "--validate prints 1 compact document per line" schema_ok "$WORK_DIR/valid.txt"
check "--validate stays silent on valid input" test ! -s "$ERR_FILE"

jq '. + {hostname: "frosty-desk"}' "$EXAMPLES/unit_failed.json" |
    "$COLLECTOR" --validate >/dev/null 2>"$ERR_FILE" && rc=0 || rc=$?
check "--validate rejects an extra envelope field" test "$rc" -eq 1
check "--validate names the failing report" grep -qF 'snosi-health: report 1 fails frostyard.problem/1' "$ERR_FILE"

jq '.report_id = "not-a-uuid"' "$EXAMPLES/unit_failed.json" |
    "$COLLECTOR" --validate >/dev/null 2>"$ERR_FILE" && rc=0 || rc=$?
check "--validate rejects a bad report_id" test "$rc" -eq 1

printf 'not json\n' | "$COLLECTOR" --validate >/dev/null 2>"$ERR_FILE" && rc=0 || rc=$?
check "--validate rejects input that is not JSON" test "$rc" -eq 1

printf '# Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ $FAIL -eq 0 ]]
