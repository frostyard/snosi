# Bootc Installation Testing Implementation Plan

**Status:** Shipped — `test/bootc-install-test.sh` and `.github/workflows/test-install.yml` exist; see the design doc for the shape that landed.  
**Last verified:** 2026-08-29

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a test harness that validates snosi snow image installation via `bootc install to-disk` by booting the result in QEMU and running checks over SSH.

**Architecture:** Shell scripts orchestrate a pipeline: load OCI image into podman, install to raw disk via `bootc install to-disk --via-loopback`, boot in QEMU with KVM, run 4 tiers of tests via SSH, teardown. Same scripts run locally and in GitHub Actions.

**Tech Stack:** Bash, podman, bootc, QEMU/KVM, OVMF (UEFI), SSH, GitHub Actions

**Design doc:** `docs/plans/2026-02-19-bootc-install-testing-design.md`

---

### Task 1: SSH Helper Library

**Files:**
- Create: `test/lib/ssh.sh`

**Step 1: Create the SSH helper library**

This library provides two functions: `ssh_keygen` to create a temporary keypair, and `vm_ssh` to execute commands on the VM with retry logic.

```bash
#!/bin/bash
# SSH helper functions for bootc install testing
set -euo pipefail

SSH_TIMEOUT="${SSH_TIMEOUT:-300}"
SSH_KEY=""
SSH_PORT="${SSH_PORT:-2222}"

# Generate a temporary SSH keypair. Sets SSH_KEY to the private key path.
ssh_keygen() {
    SSH_KEY="$(mktemp -d)/test_key"
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -q
    echo "Generated SSH keypair: $SSH_KEY"
}

# Wait for SSH to become available, then execute a command.
# Usage: vm_ssh "command to run"
# Returns the exit code of the remote command.
vm_ssh() {
    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 \
        -o LogLevel=ERROR \
        -i "$SSH_KEY" \
        -p "$SSH_PORT" \
        root@localhost "$@"
}

# Poll until SSH is reachable or timeout expires.
wait_for_ssh() {
    local elapsed=0
    local interval=5
    echo "Waiting for SSH on port $SSH_PORT (timeout: ${SSH_TIMEOUT}s)..."
    while [ "$elapsed" -lt "$SSH_TIMEOUT" ]; do
        if vm_ssh "true" 2>/dev/null; then
            echo "SSH is available after ${elapsed}s"
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    echo "ERROR: SSH not available after ${SSH_TIMEOUT}s"
    return 1
}
```

**Step 2: Verify the script is valid bash**

Run: `bash -n test/lib/ssh.sh`
Expected: No output (valid syntax)

**Step 3: Commit**

```bash
git add test/lib/ssh.sh
git commit -m "feat: add SSH helper library for bootc install testing"
```

---

### Task 2: VM Lifecycle Library

**Files:**
- Create: `test/lib/vm.sh`

**Step 1: Create the QEMU VM lifecycle library**

This library handles starting/stopping QEMU and creating disk images.

```bash
#!/bin/bash
# QEMU VM lifecycle helpers for bootc install testing
set -euo pipefail

DISK_SIZE="${DISK_SIZE:-10G}"
VM_MEMORY="${VM_MEMORY:-4096}"
VM_CPUS="${VM_CPUS:-2}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
QEMU_PID=""
DISK_IMAGE=""

# Create a sparse raw disk image.
# Usage: create_disk /path/to/disk.raw
create_disk() {
    DISK_IMAGE="$1"
    truncate -s "$DISK_SIZE" "$DISK_IMAGE"
    echo "Created sparse disk image: $DISK_IMAGE ($DISK_SIZE)"
}

# Find OVMF firmware path (differs between distros).
find_ovmf() {
    local paths=(
        "/usr/share/OVMF/OVMF_CODE.fd"
        "/usr/share/edk2/ovmf/OVMF_CODE.fd"
        "/usr/share/qemu/OVMF_CODE.fd"
        "/usr/share/edk2-ovmf/x64/OVMF_CODE.fd"
    )
    for p in "${paths[@]}"; do
        if [ -f "$p" ]; then
            echo "$p"
            return 0
        fi
    done
    echo "ERROR: OVMF firmware not found" >&2
    return 1
}

# Start a QEMU VM from a raw disk image.
# Usage: vm_start /path/to/disk.raw
vm_start() {
    local disk="$1"
    local ovmf
    ovmf="$(find_ovmf)"
    local ssh_port="${SSH_PORT:-2222}"

    qemu-system-x86_64 \
        -enable-kvm \
        -cpu host \
        -m "$VM_MEMORY" \
        -smp "$VM_CPUS" \
        -bios "$ovmf" \
        -drive file="$disk",format=raw,if=virtio \
        -netdev user,id=net0,hostfwd=tcp::"$ssh_port"-:22 \
        -device virtio-net-pci,netdev=net0 \
        -nographic \
        -serial mon:stdio \
        -daemonize \
        -pidfile /tmp/qemu-test.pid

    QEMU_PID="$(cat /tmp/qemu-test.pid)"
    echo "QEMU started with PID $QEMU_PID"
}

# Stop the QEMU VM.
vm_stop() {
    if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "Stopping QEMU (PID $QEMU_PID)..."
        kill "$QEMU_PID" || true
        wait "$QEMU_PID" 2>/dev/null || true
        QEMU_PID=""
    fi
}

# Clean up disk image and temp files.
vm_cleanup() {
    vm_stop
    if [ -n "$DISK_IMAGE" ] && [ -f "$DISK_IMAGE" ]; then
        rm -f "$DISK_IMAGE"
        echo "Removed disk image: $DISK_IMAGE"
    fi
}
```

**Step 2: Verify the script is valid bash**

Run: `bash -n test/lib/vm.sh`
Expected: No output (valid syntax)

**Step 3: Commit**

```bash
git add test/lib/vm.sh
git commit -m "feat: add QEMU VM lifecycle library for bootc install testing"
```

---

### Task 3: Tier 1 Test Script (Installation Validation)

**Files:**
- Create: `test/tests/01-installation.sh`

**Step 1: Create Tier 1 test script**

These tests run inside the VM via SSH. They validate the bootc installation was successful.

```bash
#!/bin/bash
# Tier 1: Installation validation tests
# Run inside the booted VM via SSH
set -euo pipefail

PASS=0
FAIL=0

check() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "ok - $description"
        PASS=$((PASS + 1))
    else
        echo "not ok - $description"
        FAIL=$((FAIL + 1))
    fi
}

echo "# Tier 1: Installation Validation"

# System reached running state
check "system is running" systemctl is-system-running --wait --timeout=120

# Root filesystem is read-only
check "root filesystem is read-only" test "$(findmnt -n -o OPTIONS / | grep -c 'ro')" -gt 0

# Composefs is active
check "composefs is active" findmnt -n -t composefs /

# /usr is read-only
check "usr is read-only" test ! -w /usr/bin

# bootc status returns valid output
check "bootc status succeeds" bootc status

# bootc reports a valid image
check "bootc has image reference" bash -c "bootc status --json | jq -e '.status.booted.image'"

echo "# Tier 1 Results: $PASS passed, $FAIL failed"
exit "$FAIL"
```

**Step 2: Verify syntax**

Run: `bash -n test/tests/01-installation.sh`
Expected: No output

**Step 3: Commit**

```bash
git add test/tests/01-installation.sh
git commit -m "feat: add tier 1 installation validation tests"
```

---

### Task 4: Tier 2 Test Script (Service Health)

**Files:**
- Create: `test/tests/02-services.sh`

**Step 1: Create Tier 2 test script**

```bash
#!/bin/bash
# Tier 2: Service health tests
# Run inside the booted VM via SSH
set -euo pipefail

PASS=0
FAIL=0

check() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "ok - $description"
        PASS=$((PASS + 1))
    else
        echo "not ok - $description"
        FAIL=$((FAIL + 1))
    fi
}

echo "# Tier 2: Service Health"

check "systemd-resolved is active" systemctl is-active systemd-resolved
check "NetworkManager is active" systemctl is-active NetworkManager
check "ssh is active" systemctl is-active ssh
check "nbc-update-download.timer is loaded" systemctl list-timers --all --no-legend nbc-update-download.timer
check "frostyard-updex service exists" systemctl cat frostyard-updex

# Check for failed units (allow zero)
FAILED_COUNT="$(systemctl --failed --no-legend | wc -l)"
check "no failed systemd units ($FAILED_COUNT found)" test "$FAILED_COUNT" -eq 0

echo "# Tier 2 Results: $PASS passed, $FAIL failed"
exit "$FAIL"
```

**Step 2: Verify syntax**

Run: `bash -n test/tests/02-services.sh`
Expected: No output

**Step 3: Commit**

```bash
git add test/tests/02-services.sh
git commit -m "feat: add tier 2 service health tests"
```

---

### Task 5: Tier 3 Test Script (Sysext Validation)

**Files:**
- Create: `test/tests/03-sysexts.sh`

**Step 1: Create Tier 3 test script**

Note: sysexts may not be installed in a fresh `bootc install to-disk` without additional setup. This tier validates sysext machinery is present and functional, checking what's available rather than asserting specific extensions.

```bash
#!/bin/bash
# Tier 3: Sysext validation tests
# Run inside the booted VM via SSH
set -euo pipefail

PASS=0
FAIL=0

check() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "ok - $description"
        PASS=$((PASS + 1))
    else
        echo "not ok - $description"
        FAIL=$((FAIL + 1))
    fi
}

echo "# Tier 3: Sysext Validation"

# systemd-sysext is available
check "systemd-sysext binary exists" command -v systemd-sysext

# sysext list command works
check "systemd-sysext list succeeds" systemd-sysext list

# sysupdate configuration exists
check "sysupdate transfer configs exist" test -d /usr/lib/sysupdate.d

# List available transfer configs
echo "# Available sysupdate transfers:"
ls -1 /usr/lib/sysupdate.d/ 2>/dev/null || echo "# (none found)"

# List any active extensions
echo "# Active extensions:"
systemd-sysext list 2>/dev/null || echo "# (none active)"

echo "# Tier 3 Results: $PASS passed, $FAIL failed"
exit "$FAIL"
```

**Step 2: Verify syntax**

Run: `bash -n test/tests/03-sysexts.sh`
Expected: No output

**Step 3: Commit**

```bash
git add test/tests/03-sysexts.sh
git commit -m "feat: add tier 3 sysext validation tests"
```

---

### Task 6: Tier 4 Test Script (Smoke Tests)

**Files:**
- Create: `test/tests/04-smoke.sh`

**Step 1: Create Tier 4 test script**

```bash
#!/bin/bash
# Tier 4: Smoke tests
# Run inside the booted VM via SSH
set -euo pipefail

PASS=0
FAIL=0

check() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "ok - $description"
        PASS=$((PASS + 1))
    else
        echo "not ok - $description"
        FAIL=$((FAIL + 1))
    fi
}

echo "# Tier 4: Smoke Tests"

# Network connectivity
check "network connectivity (example.com)" curl -sf --max-time 10 https://example.com

# DNS resolution
check "DNS resolution works" getent hosts example.com

# Package metadata
PKG_COUNT="$(dpkg -l 2>/dev/null | grep -c '^ii' || echo 0)"
check "package metadata intact ($PKG_COUNT packages)" test "$PKG_COUNT" -gt 100

# System time is reasonable (not epoch - year should be >= 2025)
YEAR="$(date +%Y)"
check "system time is reasonable (year=$YEAR)" test "$YEAR" -ge 2025

# Hostname was set
check "hostname is set" test -n "$(hostname)"

# Locale is configured
check "locale is configured" locale

echo "# Tier 4 Results: $PASS passed, $FAIL failed"
exit "$FAIL"
```

**Step 2: Verify syntax**

Run: `bash -n test/tests/04-smoke.sh`
Expected: No output

**Step 3: Commit**

```bash
git add test/tests/04-smoke.sh
git commit -m "feat: add tier 4 smoke tests"
```

---

### Task 7: Main Orchestrator Script

**Files:**
- Create: `test/bootc-install-test.sh`
- Reference: `test/lib/ssh.sh`, `test/lib/vm.sh`, `test/tests/*.sh`

**Step 1: Create the main orchestrator**

This is the entry point. It ties together the libraries and test scripts.

```bash
#!/bin/bash
# bootc-install-test.sh - Test bootc installation of snosi images
#
# Usage:
#   ./test/bootc-install-test.sh <oci-image-path-or-registry-ref>
#
# Examples:
#   ./test/bootc-install-test.sh output/snow.oci
#   ./test/bootc-install-test.sh ghcr.io/frostyard/snow:latest
#
# Environment variables:
#   DISK_SIZE     - Raw disk image size (default: 10G)
#   VM_MEMORY     - VM memory in MB (default: 4096)
#   VM_CPUS       - VM CPU count (default: 2)
#   SSH_PORT      - Host port for SSH forwarding (default: 2222)
#   SSH_TIMEOUT   - Seconds to wait for SSH (default: 300)
#   BOOT_TIMEOUT  - Seconds to wait for boot (default: 300)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=test/lib/ssh.sh
source "$SCRIPT_DIR/lib/ssh.sh"
# shellcheck source=test/lib/vm.sh
source "$SCRIPT_DIR/lib/vm.sh"

TMPDIR="$(mktemp -d)"
DISK_IMAGE="$TMPDIR/disk.raw"
IMAGE_REF=""
LOADED_IMAGE=""

# --- Cleanup ---
cleanup() {
    echo ""
    echo "=== Cleanup ==="
    vm_cleanup
    if [ -n "$LOADED_IMAGE" ]; then
        podman rmi "$LOADED_IMAGE" 2>/dev/null || true
    fi
    if [ -d "$TMPDIR" ]; then
        rm -rf "$TMPDIR"
    fi
    echo "Cleanup complete."
}
trap cleanup EXIT

# --- Argument parsing ---
if [ $# -lt 1 ]; then
    echo "Usage: $0 <oci-image-path-or-registry-ref>"
    exit 1
fi
IMAGE_INPUT="$1"

# --- Step 1: Load or pull the image ---
echo ""
echo "=== Step 1: Load image ==="
if [ -f "$IMAGE_INPUT" ] || [ -d "$IMAGE_INPUT" ]; then
    # Local OCI archive or directory
    IMAGE_REF="localhost/snosi-test:latest"
    echo "Loading OCI image from $IMAGE_INPUT..."
    # skopeo can handle both oci: directory and oci-archive: tar
    if [ -d "$IMAGE_INPUT" ]; then
        skopeo copy "oci:$IMAGE_INPUT" "containers-storage:$IMAGE_REF"
    else
        skopeo copy "oci-archive:$IMAGE_INPUT" "containers-storage:$IMAGE_REF"
    fi
    LOADED_IMAGE="$IMAGE_REF"
else
    # Registry reference
    IMAGE_REF="$IMAGE_INPUT"
    echo "Will pull image from registry: $IMAGE_REF"
    podman pull "$IMAGE_REF"
    LOADED_IMAGE="$IMAGE_REF"
fi
echo "Image ready: $IMAGE_REF"

# --- Step 2: Generate SSH keys ---
echo ""
echo "=== Step 2: Generate SSH keypair ==="
ssh_keygen

# --- Step 3: Create disk image ---
echo ""
echo "=== Step 3: Create disk image ==="
create_disk "$DISK_IMAGE"

# --- Step 4: Install via bootc ---
echo ""
echo "=== Step 4: bootc install to-disk ==="
podman run --rm --privileged \
    --pid=host \
    -v /var/lib/containers:/var/lib/containers \
    -v /dev:/dev \
    -v "$TMPDIR:$TMPDIR" \
    -v "${SSH_KEY}.pub:${SSH_KEY}.pub:ro" \
    --security-opt label=type:unconfined_t \
    "$IMAGE_REF" \
    bootc install to-disk \
        --generic-image \
        --via-loopback \
        --skip-fetch-check \
        --root-ssh-authorized-keys "${SSH_KEY}.pub" \
        "$DISK_IMAGE"

echo "bootc install to-disk completed successfully"

# --- Step 5: Boot VM ---
echo ""
echo "=== Step 5: Boot VM ==="
vm_start "$DISK_IMAGE"

# --- Step 6: Wait for SSH ---
echo ""
echo "=== Step 6: Wait for SSH ==="
wait_for_ssh

# --- Step 7: Run tests ---
echo ""
echo "=== Step 7: Run tests ==="

TOTAL_PASS=0
TOTAL_FAIL=0
TIER_RESULTS=()

for test_script in "$SCRIPT_DIR"/tests/*.sh; do
    test_name="$(basename "$test_script")"
    echo ""
    echo "--- Running: $test_name ---"

    # Copy test script to VM and execute
    scp -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -i "$SSH_KEY" \
        -P "$SSH_PORT" \
        "$test_script" root@localhost:/tmp/"$test_name"

    set +e
    vm_ssh "bash /tmp/$test_name"
    tier_exit=$?
    set -e

    if [ "$tier_exit" -eq 0 ]; then
        TIER_RESULTS+=("PASS: $test_name")
    else
        TIER_RESULTS+=("FAIL: $test_name ($tier_exit failures)")
        TOTAL_FAIL=$((TOTAL_FAIL + tier_exit))
    fi
done

# --- Step 8: Summary ---
echo ""
echo "==============================="
echo "  Test Summary"
echo "==============================="
for result in "${TIER_RESULTS[@]}"; do
    echo "  $result"
done
echo "==============================="

if [ "$TOTAL_FAIL" -gt 0 ]; then
    echo "FAILED: $TOTAL_FAIL test(s) failed"
    exit 1
else
    echo "PASSED: All tests passed"
    exit 0
fi
```

**Step 2: Make the script executable**

Run: `chmod +x test/bootc-install-test.sh test/tests/*.sh test/lib/*.sh`

**Step 3: Verify syntax**

Run: `bash -n test/bootc-install-test.sh`
Expected: No output

**Step 4: Commit**

```bash
git add test/
git commit -m "feat: add bootc install test orchestrator"
```

---

### Task 8: Justfile Integration

**Files:**
- Modify: `Justfile`

**Step 1: Add test-install target to Justfile**

Add after the existing build targets:

```just
test-install image="output/snow":
    ./test/bootc-install-test.sh {{image}}
```

This allows:
- `just test-install` (defaults to `output/snow` OCI directory)
- `just test-install ghcr.io/frostyard/snow:latest` (from registry)
- `just test-install output/snow.oci` (from OCI archive)

**Step 2: Verify just parses the file**

Run: `just --list`
Expected: `test-install` appears in the target list

**Step 3: Commit**

```bash
git add Justfile
git commit -m "feat: add test-install target to Justfile"
```

---

### Task 9: GitHub Actions Workflow

**Files:**
- Create: `.github/workflows/test-install.yml`

**Step 1: Create the CI workflow**

```yaml
name: Test bootc installation

on:
  workflow_dispatch:
    inputs:
      image_tag:
        description: 'Image tag to test (default: latest)'
        required: false
        default: 'latest'

env:
  IMAGE: ghcr.io/frostyard/snow

jobs:
  test-install:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    permissions:
      contents: read
      packages: read

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Free disk space
        run: |
          sudo rm -rf /usr/lib/jvm /usr/share/dotnet /usr/share/swift \
            /usr/local/.ghcup /usr/local/lib/android /opt/microsoft \
            /opt/google /opt/az /opt/hostedtoolcache
          docker system prune -af || true
          df -h

      - name: Enable KVM
        run: |
          echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' | \
            sudo tee /etc/udev/rules.d/99-kvm4all.rules
          sudo udevadm control --reload-rules
          sudo udevadm trigger --name-match=kvm

      - name: Install dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y qemu-system-x86 qemu-utils ovmf podman skopeo

      - name: Pull image
        run: |
          podman pull ${{ env.IMAGE }}:${{ inputs.image_tag || 'latest' }}

      - name: Run installation tests
        run: |
          ./test/bootc-install-test.sh ${{ env.IMAGE }}:${{ inputs.image_tag || 'latest' }}
```

**Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/test-install.yml'))"`
Expected: No output (valid YAML)

**Step 3: Commit**

```bash
git add .github/workflows/test-install.yml
git commit -m "feat: add GitHub Actions workflow for bootc install testing"
```

---

### Task 10: Local Smoke Test (Manual Verification)

This is a manual verification step to run locally after building a snow image.

**Step 1: Verify all scripts pass syntax checks**

Run: `for f in test/lib/*.sh test/tests/*.sh test/bootc-install-test.sh; do echo "Checking $f..."; bash -n "$f" || exit 1; done && echo "All scripts valid"`
Expected: "All scripts valid"

**Step 2: Verify Justfile target exists**

Run: `just --list | grep test-install`
Expected: `test-install` appears

**Step 3: Run shellcheck on all scripts (if available)**

Run: `shellcheck test/lib/*.sh test/tests/*.sh test/bootc-install-test.sh || echo "shellcheck not installed, skipping"`
Expected: No errors (or shellcheck not installed)

**Step 4: Commit any fixes from shellcheck**

If shellcheck found issues, fix them and commit:
```bash
git add test/
git commit -m "fix: address shellcheck warnings in test scripts"
```

---

### Task 11: End-to-end Local Test Run

**Prerequisites:** A built snow OCI image at `output/snow` (run `just snow` first).

**Step 1: Run the full test suite**

Run: `sudo ./test/bootc-install-test.sh output/snow`

Note: `sudo` is required because `bootc install to-disk` needs `--privileged` podman and QEMU with KVM.

**Step 2: Evaluate results**

- If all tiers pass: done
- If specific tests fail: investigate and adjust test expectations
- Common issues to watch for:
  - SSH timeout: increase `SSH_TIMEOUT` or `BOOT_TIMEOUT`
  - Composefs check: the `findmnt` command may need adjustment for Debian's composefs mount
  - Failed units: some units may legitimately fail in a VM (e.g., hardware-dependent services). Add known-acceptable failures to the service check.

**Step 3: Final commit with any adjustments**

```bash
git add test/
git commit -m "fix: adjust tests based on local verification"
```
