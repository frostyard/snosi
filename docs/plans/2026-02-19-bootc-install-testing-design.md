# Bootc Installation Testing Design

## Problem

snosi images are built with mkosi and deployed via bootc, but there is no automated testing of the installation path. The current installer (`nbc`) is being phased out in favor of upstream `bootc install to-disk`. We need a way to validate that snosi images install and boot correctly, both locally and in CI.

## Approach

Use `bootc install to-disk --via-loopback` to install a snosi OCI image onto a raw disk image file, then boot it in QEMU with KVM acceleration. Run tests via SSH against the booted VM.

### Why This Approach

- Tests the real bootc installation path (not a simulation)
- Uses only standard tools: podman, bootc (already in the image), QEMU, SSH
- Works identically on local dev machines and GitHub Actions runners
- No dependency on Fedora-specific tooling (bcvk, tmt, bootc-image-builder)

### Alternatives Considered

- **bcvk (bootc virtualization kit):** Purpose-built but Fedora/CentOS-oriented, Debian support uncertain.
- **Incus VM testing:** Simpler VM lifecycle via `incus exec`, but adds Incus as a CI dependency and OCI-to-Incus image conversion is non-trivial.

## Image Under Test

The **snow** profile (Debian Trixie, GNOME desktop, backports kernel). This is the lightest full desktop profile and produces a bootable OCI image with `containers.bootc=1` label. The base image alone is not bootable (`Format=directory`, `Bootable=no`).

## Installation Pipeline

```
1. BUILD/LOAD   → Load OCI archive into podman
2. INSTALL      → podman run --privileged <image> bootc install to-disk
                   --via-loopback --generic-image
                   --root-ssh-authorized-keys /key.pub /output/disk.raw
3. BOOT         → qemu-system-x86_64 -enable-kvm -m 4096 -smp 2
                   -bios OVMF_CODE.fd -drive file=disk.raw,format=raw
                   -net user,hostfwd=tcp::2222-:22 -nographic
4. TEST         → SSH to localhost:2222, run test scripts
5. TEARDOWN     → Kill QEMU, remove disk.raw and temp files
```

Key flags:
- `--via-loopback`: Install to a file instead of a block device
- `--generic-image`: Portable image without machine-specific config
- `--root-ssh-authorized-keys`: Inject test SSH key for access
- QEMU `-nographic`: Headless operation with serial console

## Test Suite

Tests run via SSH, structured in 4 tiers:

### Tier 1: Installation Validation (must pass)

- `bootc install to-disk` exits 0
- VM boots to `multi-user.target` (`systemctl is-system-running --wait`)
- Root filesystem is read-only
- Composefs is active
- `/usr` is read-only
- `bootc status` returns valid output

### Tier 2: Service Health

- `systemd-resolved` is active
- `NetworkManager` is active
- `openssh-server` is active
- `nbc-update-download.timer` is loaded
- `frostyard-updex` service is available
- No failed systemd units (or within acceptable threshold)

### Tier 3: Sysext Validation

- `systemd-sysext list` shows expected extensions
- Sysext overlay paths under `/usr` are accessible
- Key binaries from sysexts exist (docker, incus, etc.)

### Tier 4: Smoke Tests

- Network connectivity (`curl -s https://example.com`)
- DNS resolution works
- Package metadata intact (`dpkg -l` returns reasonable count)
- System time is reasonable (not epoch)

## File Structure

```
test/
├── bootc-install-test.sh      # Main orchestrator
├── tests/
│   ├── 01-installation.sh     # Tier 1 checks
│   ├── 02-services.sh         # Tier 2 checks
│   ├── 03-sysexts.sh          # Tier 3 checks
│   └── 04-smoke.sh            # Tier 4 checks
└── lib/
    ├── vm.sh                  # QEMU lifecycle helpers
    └── ssh.sh                 # SSH wrapper with retry/timeout
```

### Orchestrator (`bootc-install-test.sh`)

Usage: `./test/bootc-install-test.sh <oci-image-path-or-ref>`

Steps:
1. Generate temporary SSH keypair
2. Create sparse disk image (`truncate -s 10G`)
3. Load OCI image into podman (if file path) or pull (if registry ref)
4. Run `bootc install to-disk --via-loopback`
5. Start QEMU in background
6. Wait for SSH (polling with timeout)
7. Run test scripts in order via SSH
8. Collect exit codes, print summary
9. Kill QEMU, clean up temp files (via trap)
10. Exit 0 if all pass, 1 otherwise

### Justfile Integration

```
just test-install     # builds snow, runs full test suite
```

## CI Integration

New workflow: `.github/workflows/test-install.yml`

- **Trigger:** `workflow_dispatch` (manual) initially
- **Image source:** Pull pre-built image from `ghcr.io/frostyard/snow` (already published by `build-images.yml`)
- **KVM setup:** Enable `/dev/kvm` via udev rule (available on `ubuntu-latest` since April 2024)
- **Dependencies:** `qemu-system-x86`, `qemu-utils`, `ovmf`, `podman`
- **Artifacts:** Upload test results on success or failure

### Disk Space

GitHub Actions runners have ~14GB free. Sparse disk image (10GB allocated, ~2-3GB actual) + OCI image (~2-3GB) should fit. Clean up intermediate artifacts aggressively.

## Shell Conventions

- All scripts use `set -euo pipefail`
- Test output uses TAP-like format (`ok`/`not ok`) for readability
- Cleanup in trap handlers for reliable teardown on failure
- Configurable timeouts via environment variables (`BOOT_TIMEOUT`, `SSH_TIMEOUT`)
