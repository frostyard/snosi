# Testing Framework

## Overview

The `test/` directory contains bootc lifecycle test frameworks. The install path validates OCI load → bootc install → QEMU boot → SSH-based test suite. The update path validates `bootc switch` hops, deployment slot continuity, persistence across updates, and optional rollback.

## Architecture

```
test/
├── bootc-install-test.sh      # Orchestrator script (headless, for CI)
├── bootc-update-test.sh       # Update/rollback orchestrator (headless)
├── run-qemu.sh                # Interactive QEMU runner (GTK display)
├── lib/
│   ├── helpers.sh             # Shared test helpers: check(), counters, summary
│   ├── ssh.sh                 # SSH key generation, command execution with retry
│   └── vm.sh                  # QEMU lifecycle, image loading, bootc installation
├── update-tests/
│   ├── persistence-write.sh   # Writes /var, /etc, identity, and container markers before update hops
│   └── persistence-verify.sh  # Verifies the marker matrix after each hop/rollback
└── tests/
    ├── 01-installation.sh     # Tier 1: Installation validation
    ├── 02-services.sh         # Tier 2: Service health
    ├── 03-sysexts.sh          # Tier 3: Sysext validation
    └── 04-smoke.sh            # Tier 4: Smoke tests
```

## Interactive QEMU Runner (run-qemu.sh)

**Usage:**
```bash
just run-qemu [image="output/snow"]
# or directly:
./test/run-qemu.sh <rootfs-directory-or-registry-ref>
```

Boots an image in a QEMU graphical window (GTK display). Loads the image, installs to a virtual disk via bootc, and launches QEMU. The disk image is preserved between runs — subsequent invocations skip the install step.

**Defaults:** 50G disk (via Justfile), 4G RAM, 2 CPUs. Configurable via `DISK_SIZE`, `VM_MEMORY`, `VM_CPUS` env vars.

## Orchestrator (bootc-install-test.sh)

**Usage:**
```bash
sudo ./test/bootc-install-test.sh [image-ref]
```

Must run as root: `bootc install` requires the root user namespace (it aborts under rootless podman with "/proc/1 is owned by 65534"), and the script also uses losetup/mount. When passing a registry ref, the image is pulled into root's podman storage.

**Flow:**
1. Loads OCI image (from local directory or registry reference via skopeo/podman)
2. Generates ephemeral SSH keypair
3. Creates sparse raw disk image
4. Runs `bootc install to-disk --via-loopback` to install the image
5. Injects the generated SSH key into the installed composefs state directory
6. Boots installed disk in QEMU with KVM acceleration
7. Waits for SSH availability (retry loop)
8. Runs all test tiers in order via SSH
9. Reports results, cleans up

The explicit post-install SSH-key injection is intentional: `bootc install --root-ssh-authorized-keys` does not currently place the key where the composefs backend exposes `/root` at runtime. The test mounts partition 3 and writes `state/os/default/var/roothome/.ssh/authorized_keys` directly before booting the VM.

**Configuration:** Supports custom disk size, VM memory, CPU count, and timeouts.

**Justfile target:** `just test-install [image="output/snow"]`

## Update Orchestrator (bootc-update-test.sh)

**Usage:**
```bash
sudo ./test/bootc-update-test.sh <install-ref> <hop-ref> [<hop-ref>...]
```

Installs the starting registry reference to a virtual disk, boots it in QEMU, writes persistence markers, then switches to each hop reference with `bootc switch`. After every hop it reboots, verifies that the staged deployment became booted, verifies that the previous booted deployment moved to the rollback slot, and runs the persistence verifier inside the guest.

**Important defaults and knobs:**
- Must run as root for the same root namespace, loopback, and mount reasons as `bootc-install-test.sh`.
- `DISK_SIZE` defaults to `20G` because update hops pull whole images into the guest's `/var`.
- `HOP_TRANSPORT=containers-storage` pulls hop images with guest `podman` and switches from local storage. Use it as a workaround when bootc's registry transport fails while pulling composefs images.
- `ROLLBACK=1` adds a rollback phase after the final hop and verifies that slots swap correctly while `/var` and `/etc` persistence still holds.
- `INJECT_HOSTKEYS=1` pre-generates host keys on the installed disk for testing images published before the sshd-keygen fix.
- `KEEP_VM=1` leaves the VM and working directory in place for inspection.

The baseline install uses local containers-storage, so its booted digest can differ from the registry manifest digest. The update test therefore asserts continuity across the guest-reported staged, booted, and rollback digests for each hop rather than requiring the installed baseline digest to equal the registry digest.

The production base image uses the same containers-storage staging strategy in `/usr/libexec/bootc-update-stage`: it pulls the followed image with `podman`, stages with `bootc switch --transport containers-storage`, and waits for the next normal reboot instead of forcing one.

### Persistence Matrix

`update-tests/persistence-write.sh` writes markers before the first update:
- `/var` file marker, user home marker under `/var/home`, imported local podman image, and `/opt` bind mount marker under `/var/opt`
- `/etc` new file, local modification to `/etc/motd`, deletion marker for `/etc/issue.net`, hostname change, and NetworkManager connection profile
- Identity baselines for SSH host keys, machine-id, and journal boot count

`update-tests/persistence-verify.sh` runs after each hop and optional rollback. It checks that `/var` data persists, `/etc` local changes carry into new deployments, deleted shipped files remain deleted, hostname and NetworkManager profile persist, SSH host keys and machine-id are stable, and the journal contains prior boots.

## Test Tiers

### Tier 1 — Installation Validation (01-installation.sh)

Validates the fundamental bootc/immutable OS installation:

- System reached `running` or `degraded` state (systemd boot complete)
- Root filesystem is read-only
- composefs is active
- `/usr` is read-only
- `bootc status` reports correct image reference

### Tier 2 — Service Health (02-services.sh)

Validates critical system services:

- systemd-resolved is active (DNS)
- NetworkManager is active (networking)
- SSH is active (remote access)
- `nbc-update-download.timer` is loaded
- `frostyard-updex` is installed
- No failed systemd units are present

### Tier 3 — Sysext Validation (03-sysexts.sh)

Validates the sysext infrastructure:

- `systemd-sysext` binary is available
- `systemd-sysext list` command succeeds
- sysupdate config directory (`/usr/lib/sysupdate.d/`) exists and has entries
- Lists currently active extensions

### Tier 4 — Smoke Tests (04-smoke.sh)

End-to-end functional validation:

- Network connectivity (curl to example.com)
- DNS resolution works
- Package metadata integrity (`dpkg -l` reports > 100 packages)
- System time is plausible (year ≥ 2025)
- Hostname and locale are configured

## Helper Libraries

### helpers.sh

Shared test harness sourced by all four test scripts. Provides:

- `PASS` / `FAIL` counters — initialized to 0
- `check(description, command...)` — Run a command, print TAP-like output, increment counters
- `print_summary()` — Print results line and `exit $FAIL`

### ssh.sh

- `generate_ssh_key()` — Creates ephemeral ED25519 keypair
- `ssh_exec(host, command)` — Execute command on VM via SSH with retry and timeout
- Handles connection retry for VM boot wait

### vm.sh

- `load_image(ref)` — Loads OCI image from local dir or registry (uses buildah mount + cp -a + commit pattern for local dirs)
- `install_to_disk(disk)` — Runs `bootc install to-disk` with loopback inside a privileged podman container
- `vm_start(disk)` — Launches QEMU with KVM, OVMF firmware, port forwarding for SSH
- `vm_stop()` / `vm_cleanup()` — Graceful shutdown and disk cleanup
- `find_ovmf()` searches common OVMF locations, including Incus' bundled firmware path (`/usr/incus/share/qemu/`)

`bootc-update-test.sh` sources `vm.sh` after setting `DISK_SIZE=20G`; keep that ordering if refactoring because `vm.sh` snapshots the disk size at source time.

## CI Integration

The `test-install.yml` workflow runs these tests on manual dispatch:
1. Sets up KVM-enabled runner
2. Installs QEMU + OVMF + podman + skopeo
3. Resolves the selected `ghcr.io/frostyard/snow:<tag>` to a digest and verifies that immutable ref with `cosign.pub`
4. Pulls the verified image ref
5. Runs the full test suite

Not run automatically on every PR due to infrastructure requirements (KVM, large disk, long runtime).
