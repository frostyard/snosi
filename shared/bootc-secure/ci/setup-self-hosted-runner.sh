#!/usr/bin/bash
# One-time host setup for the `bootc-secure` self-hosted runner.
#
# Run this ONCE, as root, on the machine that will host the runner. It is
# idempotent; re-running it is safe.
#
#   sudo ./setup-self-hosted-runner.sh <registration-token>
#
# Get the token from:
#   Settings -> Actions -> Runners -> New self-hosted runner
# or:
#   gh api -X POST repos/frostyard/snosi/actions/runners/registration-token --jq .token
#
# The token is single-use and expires in one hour.
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT IS SHAPED THE WAY IT IS
#
# frostyard/snosi is a PUBLIC repository. GitHub's own guidance is that
# self-hosted runners should be used with private repositories, because a fork
# can propose a workflow that executes on the runner. That risk is mitigated
# here in four independent layers, and every one of them matters:
#
#   1. The two self-hosted jobs are gated on
#        github.event_name == 'workflow_dispatch'
#      so they never run from a pull_request at all.
#
#   2. The repository requires approval for ALL external contributors, not
#      just first-time ones. Without this, one merged typo fix earns a
#      contributor unapproved workflow runs forever. Layer 1 lives in a file a
#      fork PR can rewrite; this layer does not.
#
#   3. The runner runs as a dedicated account with NO sudo and NO login shell.
#      Compromise costs that account's files and /dev/kvm -- not root, not the
#      k3s state, not the operator's home directory.
#
#   4. The workspace is wiped after every job, so one job cannot stage files
#      for the next.
#
# Layer 4 was originally `--ephemeral`, which is strictly stronger. It is not
# usable with a systemd-managed runner: an ephemeral runner de-registers and
# deletes its own .runner/.credentials after one job, and svc.sh's unit cannot
# recreate them. That was observed live -- the runner took exactly one job (run
# 31227792302), disappeared from the API, and never came back. --ephemeral is
# designed for orchestrators that mint a fresh JIT config per job.
#
# The cleanup hook recovers the file-isolation half of that property. It does
# NOT defend against a job that tampers with the runner installation itself.
# Restoring that would mean storing a PAT on this host to re-register after
# every job, which trades a bounded risk for a standing credential; layers 1-3
# already require an attacker to hold repository write access before any of
# this is reachable.
#
# Do not weaken any layer on the assumption that the others hold. They cover
# different failure modes: 1 is a workflow property, 2 is a repository setting,
# 3 bounds blast radius, 4 bounds persistence.
# ---------------------------------------------------------------------------
set -euo pipefail

RUNNER_USER=ghrunner
RUNNER_HOME=/var/lib/ghrunner
REPO_URL=https://github.com/frostyard/snosi
LABELS=self-hosted,linux,x64,bootc-secure
# Checksum is upstream's published value for this exact tarball, confirmed
# against an independent download (226035903 bytes). When bumping the version,
# re-derive BOTH -- do not carry the old hash forward.
RUNNER_VERSION=2.336.0
RUNNER_SHA256=04cf0be1aff4c3ec3554466c39124ca250e3effd8873bb7e8d68535aa9505d5d

TOKEN=${1:-}
[[ -n "$TOKEN" ]] || { echo "usage: $0 <registration-token>" >&2; exit 1; }
(( EUID == 0 )) || { echo "must run as root" >&2; exit 1; }

step() { printf '\n== %s ==\n' "$*"; }

step "KVM udev rule (host setup, so the job never needs sudo)"
# The workflow used to write this itself with sudo on every run. It only ever
# needs writing once, and requiring sudo in the job is exactly the privilege a
# hostile workflow would want.
install -m 0644 /dev/stdin /etc/udev/rules.d/99-kvm4all.rules <<'RULE'
KERNEL=="kvm", GROUP="kvm", MODE="0660", OPTIONS+="static_node=kvm"
RULE
# MODE 0660 + kvm group, NOT the 0666 the old workflow set: world-writable
# /dev/kvm hands every local account the ability to start VMs.
udevadm control --reload-rules
udevadm trigger --name-match=kvm

step "runner account (no sudo, no login shell)"
if ! id -u "$RUNNER_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "$RUNNER_HOME" \
            --shell /usr/sbin/nologin "$RUNNER_USER"
fi
usermod -aG kvm "$RUNNER_USER"
# Deliberately NOT added to: sudo, wheel, docker, incus, k3s. Membership in any
# of those would make layer 3 above meaningless -- docker and incus group
# membership are each equivalent to root on this host.
install -d -m 0750 -o "$RUNNER_USER" -g "$RUNNER_USER" "$RUNNER_HOME"

step "verify the account really is unprivileged"
fail=0
if sudo -l -U "$RUNNER_USER" 2>/dev/null | grep -qv "not allowed"; then
    echo "  REFUSING: $RUNNER_USER has sudo rules" >&2; fail=1
fi
for g in sudo wheel docker incus root; do
    if id -nG "$RUNNER_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$g"; then
        echo "  REFUSING: $RUNNER_USER is in group '$g'" >&2; fail=1
    fi
done
(( fail == 0 )) || exit 1
echo "  ok: $RUNNER_USER groups = $(id -nG "$RUNNER_USER")"

step "download and verify the runner"
cd "$RUNNER_HOME"
TARBALL="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
if [[ ! -x ./run.sh ]]; then
    curl -fsSL -o "$TARBALL" \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${TARBALL}"
    # Verify before extracting. This is the same reasoning as the checksum on
    # the lab's kubectl fetch: an unverified download that is then executed is
    # a supply-chain hole regardless of how convenient the fetch was.
    echo "${RUNNER_SHA256}  ${TARBALL}" | sha256sum -c - \
      || { echo "runner tarball failed checksum verification" >&2; exit 1; }
    tar xzf "$TARBALL"
    rm -f "$TARBALL"
    chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOME"
fi

step "job-completed hook: wipe the workspace between jobs"
# This is what recovers most of --ephemeral's value without it. See the note on
# layer 4 at the top of this file for why --ephemeral itself is not usable here.
install -m 0755 /dev/stdin "$RUNNER_HOME/wipe-work.sh" <<'HOOK'
#!/usr/bin/bash
# Runs after every job (ACTIONS_RUNNER_HOOK_JOB_COMPLETED), as the runner user.
# Leaves _work itself in place -- the runner expects its work dir to exist --
# and removes only its contents, so one job cannot leave files for the next.
set -uo pipefail
work="$(dirname "$0")/_work"
[[ -d "$work" ]] || exit 0
find "$work" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
echo "runner workspace wiped"
exit 0
HOOK
chown "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOME/wipe-work.sh"

# .env is read by the runner service at start; this is the supported way to set
# the hook without editing the generated unit.
touch "$RUNNER_HOME/.env"
sed -i '/^ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/d' "$RUNNER_HOME/.env"
echo "ACTIONS_RUNNER_HOOK_JOB_COMPLETED=${RUNNER_HOME}/wipe-work.sh" >>"$RUNNER_HOME/.env"
chown "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOME/.env"

step "configure (persistent registration; workspace wiped per job)"
# NOT --ephemeral. An ephemeral runner de-registers after one job and deletes
# its own .runner/.credentials, which svc.sh's unit cannot recreate -- the
# result is a runner that works exactly once and then silently disappears.
# Observed live: run 31227792302 completed, after which the runner vanished
# from the API and never returned. --ephemeral is for orchestrators that mint
# a fresh JIT config per job, not for a systemd service.
sudo -u "$RUNNER_USER" ./config.sh \
    --url "$REPO_URL" \
    --token "$TOKEN" \
    --name "selfie-bootc-secure" \
    --labels "$LABELS" \
    --work _work \
    --unattended \
    --replace

step "install as a systemd service"
# Derived, not hardcoded: svc.sh builds the unit name from the repo path and
# runner name. Verified against the name actually installed on selfie.
UNIT="actions.runner.$(printf '%s' "${REPO_URL#https://github.com/}" | tr '/' '-').selfie-bootc-secure.service"

# svc.sh install EXITS 1 if the unit already exists ("Service ... already
# exists"), which under `set -e` aborts everything after it: no drop-in, no
# start, and a runner left registered-but-offline. `--replace` on config.sh
# makes the REGISTRATION idempotent; it does nothing for the service. Tear the
# old unit down first so re-running this script is genuinely idempotent.
#
# Observed live: a re-run left the 23:36 unit in place beside a 00:20
# registration, and the runner sat offline until this was fixed.
if [[ -f "/etc/systemd/system/${UNIT}" ]]; then
    echo "  existing service found; removing it before reinstalling"
    ./svc.sh stop      || true
    ./svc.sh uninstall || true
    rm -f "/etc/systemd/system/${UNIT}"
    systemctl daemon-reload
fi
./svc.sh install "$RUNNER_USER"

# svc.sh generates the unit, so configure restart behaviour in a drop-in rather
# than editing it -- a later `svc.sh install` would overwrite the unit and
# silently take the setting with it.
install -d -m 0755 "/etc/systemd/system/${UNIT}.d"
install -m 0644 /dev/stdin "/etc/systemd/system/${UNIT}.d/10-restart.conf" <<'DROPIN'
[Service]
Restart=always
RestartSec=5
DROPIN
systemctl daemon-reload
./svc.sh start

step "confirm the runner survives a restart"
# The whole point of the change away from --ephemeral. Restart it and require
# it to come back, rather than assuming.
systemctl restart "$UNIT"
for _ in $(seq 1 30); do
    systemctl is-active --quiet "$UNIT" && break
    sleep 2
done
systemctl is-active --quiet "$UNIT" \
    || { echo "runner service did not come back after restart" >&2; exit 1; }
echo "  ok: $UNIT active after restart"

cat <<EOF

Done.

  account : $RUNNER_USER  (groups: $(id -nG "$RUNNER_USER"))
  home    : $RUNNER_HOME
  labels  : $LABELS
  mode    : persistent registration, workspace wiped after each job

The runner stays registered between jobs. Confirm it is still listed AFTER a
job completes -- an earlier version of this script used --ephemeral, which made
the runner take exactly one job and then vanish.

Verify from a machine with gh:
  gh api repos/frostyard/snosi/actions/runners \\
    --jq '.runners[] | "\(.name) \(.status) \([.labels[].name]|join(","))"'

Then dispatch a live run:
  gh workflow run test-bootc-secure.yml -R frostyard/snosi \\
    -f run_live=true -f profile=cayo -f state_root=<STATE_ROOT>
EOF
