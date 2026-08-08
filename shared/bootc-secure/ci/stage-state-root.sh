#!/usr/bin/bash
# Stage a STATE_ROOT for the secure install/update window on a self-hosted
# runner host.
#
#   sudo ./stage-state-root.sh <profile> <dakota-iso> [state-root]
#
#   profile      cayo | snow | snowfield
#   dakota-iso   path to the secure Dakota ISO to install from
#   state-root   default /var/lib/ghrunner/state-root
#
# Idempotent. Re-running refreshes refs.env and re-copies the runner adapters;
# it never destroys an existing target.raw (that disk is the install under test
# and re-creating it silently would throw away a completed install).
#
# ---------------------------------------------------------------------------
# WHY THE OWNERSHIP AND MODE ARE NOT NEGOTIABLE
#
# run-full-window.sh validates:
#
#     state_root is absolute, mode 0700, owned by $(id -u)
#     refs.env   is a regular file, mode 0600, owned by $(id -u)
#
# and refuses otherwise. "Owned by the runner" means the account the JOB runs
# as -- ghrunner -- not root. The lab's existing /var/lib/snosi-lab/secure is
# root-owned and world-writable, so pointing the hardened runner at it fails
# validation immediately. That is the check working: a world-writable state
# directory would let any local account swap the ISO or the recovery key out
# from under a run.
# ---------------------------------------------------------------------------
set -euo pipefail

RUNNER_USER=${RUNNER_USER:-ghrunner}
PROFILE=${1:-}
DAKOTA_ISO=${2:-}
STATE_ROOT=${3:-/var/lib/ghrunner/state-root}

usage() { echo "usage: $0 <cayo|snow|snowfield> <dakota-iso> [state-root]" >&2; exit 1; }
[[ -n "$PROFILE" && -n "$DAKOTA_ISO" ]] || usage
case "$PROFILE" in cayo|snow|snowfield) ;; *) usage;; esac
(( EUID == 0 )) || { echo "must run as root" >&2; exit 1; }
[[ -r "$DAKOTA_ISO" ]] || { echo "unreadable ISO: $DAKOTA_ISO" >&2; exit 1; }
id -u "$RUNNER_USER" >/dev/null 2>&1 || { echo "no such user: $RUNNER_USER" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
step() { printf '\n== %s ==\n' "$*"; }

# Resolve the toolchain the same way the workflow does: the host's /usr/bin is
# not the whole story on an immutable image.
export PATH="/usr/incus/bin:/home/linuxbrew/.linuxbrew/bin:$PATH"
command -v skopeo >/dev/null || { echo "skopeo not found on PATH" >&2; exit 1; }

step "resolve three distinct secure digests for $PROFILE"
# Resolved live, never hardcoded: these move, and a stale digest would silently
# test the wrong images. Each is checked for the secure-boot capability label --
# a mechanics image would fail deep inside the install with a far worse message.
repo="ghcr.io/frostyard/$PROFILE"
mapfile -t TAGS < <(
    skopeo list-tags "docker://$repo" | python3 -c '
import json, sys
tags = sorted(t for t in json.load(sys.stdin)["Tags"] if t.isdigit() and len(t) == 14)
print("\n".join(tags[-3:]))
'
)
(( ${#TAGS[@]} == 3 )) || { echo "need at least 3 versioned tags for $repo" >&2; exit 1; }

declare -A DIGEST VERSION
for t in "${TAGS[@]}"; do
    meta=$(skopeo inspect "docker://$repo:$t")
    cap=$(printf '%s' "$meta" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("Labels") or {}).get("io.snosi.bootc.secureboot-capable","false"))')
    [[ $cap == true ]] || { echo "refusing $repo:$t -- secureboot-capable=$cap" >&2; exit 1; }
    DIGEST[$t]=$(printf '%s' "$meta" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Digest"])')
    VERSION[$t]=$(printf '%s' "$meta" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("Labels") or {}).get("org.opencontainers.image.version",""))')
    echo "  $t -> ${DIGEST[$t]:0:20} (secure)"
done
N="${TAGS[0]}"; N1="${TAGS[1]}"; N2="${TAGS[2]}"

step "create $STATE_ROOT owned by $RUNNER_USER, mode 0700"
install -d -m 0700 -o "$RUNNER_USER" -g "$RUNNER_USER" "$STATE_ROOT"

step "stage inputs"
install -m 0644 -o "$RUNNER_USER" -g "$RUNNER_USER" "$DAKOTA_ISO"                       "$STATE_ROOT/dakota.iso"
install -m 0644 -o "$RUNNER_USER" -g "$RUNNER_USER" "$REPO_ROOT/shared/native-ab/keys/mok-2026.crt"      "$STATE_ROOT/mok.crt"
install -m 0644 -o "$RUNNER_USER" -g "$RUNNER_USER" "$REPO_ROOT/shared/native-ab/keys/pcr-signing-2026.pub" "$STATE_ROOT/pcr.pub"

# The recovery credential is generated here and never leaves this directory.
# printf '%s', not echo: a trailing newline in the key file is the exact defect
# Task 3 spent a cycle on -- cryptsetup's --key-file path includes the newline
# while the interactive path strips it.
if [[ ! -f "$STATE_ROOT/recovery.key" ]]; then
    printf '%s' "$(head -c 32 /dev/urandom | base64 | tr -d '\n=+/' | head -c 32)" \
        >"$STATE_ROOT/recovery.key"
fi
chmod 0600 "$STATE_ROOT/recovery.key"
chown "$RUNNER_USER:$RUNNER_USER" "$STATE_ROOT/recovery.key"

# Dakota's runner adapters are NOT staged here. The workflow clones them into
# STATE_ROOT inside its container at run time, at a named ref.
#
# Staging them on the host meant cloning into the runner's 0750 home, which
# needs sudo and then leaves a root-owned checkout the runner account cannot
# execute. Cloning in-container also pins the adapters to a ref instead of
# whatever happens to be sitting on the box -- the same reason the Argo lane
# clones both repos per run rather than trusting a checkout.

step "target disk"
if [[ -f "$STATE_ROOT/target.raw" ]]; then
    echo "  keeping the existing target.raw (delete it yourself to start clean)"
else
    qemu-img create -f raw "$STATE_ROOT/target.raw" 40G >/dev/null
    chown "$RUNNER_USER:$RUNNER_USER" "$STATE_ROOT/target.raw"
    echo "  created 40G sparse target.raw"
fi

step "refs.env"
# ROTATION_* are deliberately empty: no dual-signed transition image exists for
# the bootc secure path. run-full-window skips that leg and says so rather than
# failing a completed install and update.
install -m 0600 -o "$RUNNER_USER" -g "$RUNNER_USER" /dev/stdin "$STATE_ROOT/refs.env" <<ENV
OCI_REF=$repo@${DIGEST[$N]}
TRACKING_REF=$repo:secure-test
UPDATE_N1_REF=$repo@${DIGEST[$N1]}
UPDATE_N2_REF=$repo@${DIGEST[$N2]}
UPDATE_N1_VERSION=${VERSION[$N1]}
UPDATE_N2_VERSION=${VERSION[$N2]}
ROTATION_OLD_REF=
ROTATION_TRANSITION_REF=
ROTATION_NEW_REF=
ENV

step "verify what the harness will verify"
sudo -u "$RUNNER_USER" bash -s -- "$STATE_ROOT" <<'CHECK'
set -euo pipefail
sr=$1
[[ $sr == /* && -d $sr ]]                                  || { echo "  state_root not an absolute dir" >&2; exit 1; }
[[ $(stat -c '%a' "$sr") == 700 ]]                         || { echo "  state_root is not mode 0700" >&2; exit 1; }
[[ $(stat -c '%u' "$sr") == $(id -u) ]]                    || { echo "  state_root not owned by $(id -un)" >&2; exit 1; }
[[ $(stat -c '%a' "$sr/refs.env") == 600 ]]                || { echo "  refs.env is not mode 0600" >&2; exit 1; }
[[ $(stat -c '%u' "$sr/refs.env") == $(id -u) ]]           || { echo "  refs.env not owned by $(id -un)" >&2; exit 1; }
[[ $(stat -c '%a' "$sr/recovery.key") == 600 ]]            || { echo "  recovery.key is not mode 0600" >&2; exit 1; }
echo "  ok: readable and correctly owned as $(id -un)"
CHECK

cat <<EOF

Staged $STATE_ROOT for $PROFILE.

  accepted N : $repo:$N
  N+1        : $repo:$N1  (${VERSION[$N1]})
  N+2        : $repo:$N2  (${VERSION[$N2]})
  tracking   : $repo:secure-test
  rotation   : not staged (no dual-signed transition image exists)

Dispatch:
  gh workflow run test-bootc-secure.yml -R frostyard/snosi \\
    -f run_live=true -f profile=$PROFILE -f state_root=$STATE_ROOT
EOF
