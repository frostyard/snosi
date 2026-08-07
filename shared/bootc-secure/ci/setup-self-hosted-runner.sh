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
#   4. The runner is EPHEMERAL: it accepts exactly one job, then de-registers.
#      Nothing persists between jobs, so one job cannot stage anything for the
#      next.
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

step "configure (ephemeral: one job per registration)"
sudo -u "$RUNNER_USER" ./config.sh \
    --url "$REPO_URL" \
    --token "$TOKEN" \
    --name "selfie-bootc-secure" \
    --labels "$LABELS" \
    --work _work \
    --ephemeral \
    --unattended \
    --replace

step "install as a systemd service"
./svc.sh install "$RUNNER_USER"
./svc.sh start

cat <<EOF

Done.

  account : $RUNNER_USER  (groups: $(id -nG "$RUNNER_USER"))
  home    : $RUNNER_HOME
  labels  : $LABELS
  mode    : ephemeral (de-registers after each job)

Because the runner is ephemeral it de-registers after every job. The systemd
unit restarts it, which re-registers it -- that is the intended loop, not a
fault.

Verify from a machine with gh:
  gh api repos/frostyard/snosi/actions/runners \\
    --jq '.runners[] | "\(.name) \(.status) \([.labels[].name]|join(","))"'

Then dispatch a live run:
  gh workflow run test-bootc-secure.yml -R frostyard/snosi \\
    -f run_live=true -f profile=cayo -f state_root=<STATE_ROOT>
EOF
