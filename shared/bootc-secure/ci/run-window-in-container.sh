#!/usr/bin/bash
# Run the secure install/update window inside a container, from a self-hosted
# runner whose host cannot supply the toolchain.
#
#   STATE_ROOT=... PROFILE=... [DAKOTA_REF=main] [GHCR_TOKEN=... GHCR_USER=...] \
#       ./run-window-in-container.sh
#
# ---------------------------------------------------------------------------
# WHY THIS IS A SCRIPT AND NOT A WORKFLOW STEP
#
# It was a workflow step, in test-bootc-secure.yml. bootc-secure-nightly.yml has
# its own live-full-window job that did the same job a different, older way --
# `sudo tee /etc/udev/rules.d/...` on a runner account that has no sudo, then
# the harness directly on a host with no swtpm, sbverify or virt-fw-vars.
#
# That divergence is not a one-off. The same shape has now produced five
# separate defects in this subsystem: ssh_key vs ssh_private_key, the uki vs
# efi BLS key, findmnt / vs the composefs mapper, NvPCR masking on native but
# not bootc, and this. Every one was a fix applied to one of two sibling paths.
#
# So the invocation lives here once and both workflows call it. A future change
# cannot land in one and miss the other, because there is only one.
# ---------------------------------------------------------------------------
set -euo pipefail

: "${STATE_ROOT:?STATE_ROOT is required}"
: "${PROFILE:?PROFILE is required}"
: "${DAKOTA_REF:=main}"
: "${GHCR_TOKEN:=}"
: "${GHCR_USER:=}"
: "${WINDOW_LOG:=/var/tmp/bootc-secure-full-window.log}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# Assert KVM rather than granting it. The runner account must have NO sudo:
# this job runs on a self-hosted runner attached to a PUBLIC repository, and
# the old `sudo tee /etc/udev/rules.d/99-kvm4all.rules` plus `sudo udevadm
# control` required exactly the privilege a hostile workflow would want -- on
# every run, to set a rule that only ever needs setting once. That rule is now
# one-time host setup (setup-self-hosted-runner.sh), which also tightens it
# from the old world-writable MODE 0666 to 0660 root:kvm.
#
# Read AND write, not merely present: a missing group membership otherwise
# surfaces as a permission error deep inside QEMU minutes later.
[[ -c /dev/kvm ]] || { echo "/dev/kvm is missing; host not set up for this runner" >&2; exit 1; }
[[ -r /dev/kvm && -w /dev/kvm ]] || {
    echo "/dev/kvm is not read-write for $(id -un) (groups: $(id -Gn))." >&2
    echo "Add the runner account to the kvm group; do NOT grant it sudo." >&2
    exit 1
}
echo "/dev/kvm usable as $(id -un)"

# --group-add keep-groups is load-bearing, not defensive. /dev/kvm is 0660
# root:kvm with no ACL, so access depends entirely on the runner account's kvm
# supplementary group -- and rootless podman DROPS supplementary groups unless
# told otherwise. Without it the device is passed through but unopenable.
#
# --runtime crun because keep-groups is a crun feature and the host has both
# crun and runc; leaving the choice to podman's default would make this work or
# not depending on configuration elsewhere.
set -o pipefail
podman run --rm \
    --runtime crun \
    --group-add keep-groups \
    --device /dev/kvm \
    -v "$REPO_ROOT:/src/snosi" \
    -v "${STATE_ROOT}:${STATE_ROOT}" \
    -e STATE_ROOT -e PROFILE -e GHCR_TOKEN -e GHCR_USER -e DAKOTA_REF \
    -w /src/snosi \
    docker.io/library/debian:trixie-slim \
    bash -euo pipefail -c '
      export DEBIAN_FRONTEND=noninteractive
      # Assert the device is usable before spending minutes on apt. A dropped
      # supplementary group shows up here in seconds instead of as an opaque
      # QEMU failure later.
      [ -r /dev/kvm ] && [ -w /dev/kvm ] || {
        echo "/dev/kvm not usable in-container (uid $(id -u), groups $(id -G))" >&2
        echo "check --group-add keep-groups and the runner account kvm membership" >&2
        exit 1
      }
      apt-get update -qq
      # The set the Argo secure lane installs -- the only toolchain this
      # harness has ever run green against.
      apt-get install -y -qq --no-install-recommends \
        qemu-system-x86 qemu-utils ovmf swtpm swtpm-tools \
        cryptsetup-bin binutils sbsigntool openssh-client iproute2 \
        jq python3 python3-pip socat git skopeo curl ca-certificates \
        gcc python3-dev libc6-dev >/dev/null
      # Not packaged in trixie; provides virt-fw-vars. Needs the gcc and
      # headers above because pip resolves it onto crypt_r.
      pip install --quiet --break-system-packages virt-firmware

      # Dakota supplies the external runner adapters. Cloned HERE, not staged
      # on the host: the runner home is 0750 runner-owned, so a host-side clone
      # needs sudo and then leaves a root-owned checkout the runner account
      # cannot execute. Pinning the ref also makes a failure attributable.
      git clone -q --depth 1 --branch "$DAKOTA_REF" \
        https://github.com/frostyard/dakota-iso.git /tmp/dakota
      echo "dakota @ $(git -C /tmp/dakota rev-parse --short HEAD) (${DAKOTA_REF})"
      install -m 0700 /tmp/dakota/test/bootc-secure-installer-runner.sh "$STATE_ROOT/installer"
      install -m 0700 /tmp/dakota/test/bootc-secure-recovery-runner.sh  "$STATE_ROOT/recovery-runner"
      install -m 0700 /tmp/dakota/test/bootc-secure-update-publish.sh   "$STATE_ROOT/publisher"
      mkdir -p "$STATE_ROOT/lib"
      cp -a /tmp/dakota/test/lib/. "$STATE_ROOT/lib/"

      # The publisher writes a tracking tag. Log in INSIDE the container so the
      # credential never touches the host filesystem and dies with the
      # container. Absent token means the update leg cannot publish; say so
      # here rather than failing obscurely mid-window.
      if [ -n "${GHCR_TOKEN:-}" ]; then
        printf "%s" "$GHCR_TOKEN" | skopeo login ghcr.io \
          --username "$GHCR_USER" --password-stdin
      else
        echo "WARNING: no GHCR_TOKEN; the update publisher will fail to advance the tracking tag" >&2
      fi

      ./shared/bootc-secure/ci/run-full-window.sh "$STATE_ROOT" "$PROFILE"
    ' |& tee "$WINDOW_LOG"
