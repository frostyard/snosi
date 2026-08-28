# Installing published Snosi images

Firn is the supported installer for every published Snosi image family. One
x86-64 ISO installs both bootc/composefs images and native A/B images. Legacy
per-family installer paths are not supported alternatives.

Installation erases the selected target disk. Back up anything you need and
verify that the backup is readable from another machine before booting the
installer.

## Choose an image

The same Firn image picker offers all current products:

| Family | Products | Update model | Target disk guidance |
| --- | --- | --- | --- |
| bootc | `snow`, `snowfield`, `flurry`, `sundog`, `cayo` | Atomic bootc/composefs deployments | Use at least 30 GiB |
| Native A/B | `snow-ab`, `snowfield-ab`, `cayo-ab` | Signed systemd-sysupdate A/B slots | Current minimum is 15.5 GiB for Cayo and 21.5 GiB for Snow or Snowfield |

Use a larger disk when possible. Applications, containers, Flatpaks, home
directories, and update state all consume mutable disk space. Firn derives the
native A/B minimum from the selected release artifact and refuses an
undersized target rather than relying only on the figures above.

- **Snow** is the general-purpose GNOME desktop.
- **Snowfield** is the GNOME desktop for Microsoft Surface devices.
- **Flurry** is the bootc-only Hyprland desktop.
- **Sundog** is the bootc-only KDE Plasma desktop.
- **Cayo** is the headless server image.

Firn requires UEFI. It supports machines with or without Secure Boot, TPM 2.0,
or disk encryption, but makes each security choice explicit. A TPM can provide
automatic unlock; without one, choose a passphrase or recovery-key mode that
fits the selected image family.

Firn being the supported installer does not by itself establish production
bootc Secure Boot support. The secure bootc fresh-install, update, and hardware
evidence gates remain governed by
[Bootc Secure Operations](bootc-secure-operations.md); do not treat an ordinary
Firn bootc install as that evidence.

## Download and verify Firn

Download the single installer ISO:

```bash
curl -fL \
  https://repository.frostyard.org/isos/native/v1/snosi-installer-latest-x86-64.iso \
  -o snosi-installer.iso
```

The stable URL redirects without caching to the immutable, versioned ISO named
by the signed checksum index. Verify both the signing-key fingerprint and the
ISO before writing installation media:

```bash
base=https://repository.frostyard.org/isos/native/v1

curl -fL "$base/SHA256SUMS" -o SHA256SUMS
curl -fL "$base/SHA256SUMS.gpg" -o SHA256SUMS.gpg
curl -fL \
  https://raw.githubusercontent.com/frostyard/snosi/main/shared/native-ab/keys/import-pubring.gpg \
  -o snosi-native-update-pubring.gpg

fingerprint="$(
  gpg --batch --show-keys --with-colons snosi-native-update-pubring.gpg |
    awk -F: '$1 == "fpr" { print $10; exit }'
)"
test "$fingerprint" = F37282A35CB6BDFEBFC8FE775A2EAC5C8216FD68

gpgv --keyring ./snosi-native-update-pubring.gpg \
  SHA256SUMS.gpg SHA256SUMS
expected="$(
  awk '$2 ~ /^snosi-installer_[0-9]{14}_x86-64\.iso$/ {
    print $1
    exit
  }' SHA256SUMS
)"
test -n "$expected"
printf '%s  %s\n' "$expected" snosi-installer.iso |
  sha256sum -c -
```

Stop if the fingerprint, OpenPGP signature, or SHA-256 check fails. Firn also
verifies the selected payload before writing it: bootc images use the committed
Cosign key and exact repository identity; native A/B artifacts use the signed
index and artifact checksum.

## Write and boot the installer

Use a graphical disk-imaging tool's **Restore Disk Image** operation, or write
the ISO from a Linux terminal. The destination must be the whole USB device,
such as `/dev/sdb`, not a partition such as `/dev/sdb1`.

1. Insert a USB drive and identify it by size, model, and serial:

   ```bash
   lsblk -o NAME,PATH,SIZE,MODEL,SERIAL,TRAN,MOUNTPOINTS
   ```

2. Unmount every mounted partition on that USB drive.
3. Set `ISO` and `DISK`, inspect the device again, and write the image:

   ```bash
   ISO=snosi-installer.iso
   DISK=/dev/sdX  # replace with the whole disposable USB device

   test -f "$ISO"
   test -b "$DISK"
   lsblk -o NAME,PATH,SIZE,MODEL,SERIAL,TRAN,MOUNTPOINTS "$DISK"
   sudo dd if="$ISO" of="$DISK" bs=4M status=progress conv=fsync
   sync
   ```

   `dd` permanently overwrites the selected device. Continue only when the
   `lsblk` identity is the disposable USB drive.

4. Reboot, open the firmware's one-time boot menu, and select the UEFI entry
   for the USB drive. Do not select the disk you intend to install onto.

## Install with Firn

Firn starts automatically as a terminal wizard on the local display and the
serial console. It uses the same flow for both image families while applying
the correct storage and trust pipeline for the selected product.

1. Select the bootc or native A/B family, then select the product.
2. Ensure networking is available if the selected payload or optional
   applications must be downloaded. The medium provides NetworkManager and
   `nmcli` for console network configuration.
3. Select the target disk by its path, model, serial, size, and transport.
   Firn refuses the installer medium, mounted or ambiguous disks, and targets
   that cannot hold the selected native A/B release.
4. Choose the filesystem and explicitly choose encryption, TPM unlock, and MOK
   enrollment settings offered for the detected hardware and image family.
5. Configure hostname, locale, timezone, keyboard, optional SSH keys, the first
   user and groups, and optional system Flatpaks.
6. Review the generated recipe. Confirm erasure by typing the exact target-disk
   path; a mismatch aborts before destructive work.
7. Wait for payload verification and installation to finish. If Firn displays
   a generated recovery key, copy it to a password manager, separate removable
   media, or paper before acknowledging the screen. Losing both TPM access and
   the external recovery credential can make encrypted data unrecoverable.
8. Reboot and remove the USB drive.

### Complete MOK enrollment

If Secure Boot was enabled and MOK enrollment was selected, MokManager displays
a blue screen during the first boot:

1. Press a key before the countdown expires.
2. Select **Enroll MOK**.
3. Select **Continue**, then **Yes**.
4. Enter the one-time MOK password chosen in Firn.

The machine reboots again and starts Snosi. Missing or rejecting enrollment
leaves the MOK-signed stage untrusted while Secure Boot is enforced.

## After installation

For a bootc image, confirm the deployment and update timer:

```bash
systemctl is-system-running
sudo bootc status
sudo snosi-update-status --check
systemctl list-timers bootc-update-stage.timer
```

Published bootc images check for updates hourly, stage an available deployment,
and apply it at the next natural reboot. They do not force a reboot. To return
to the previous deployment:

```bash
sudo bootc rollback
sudo systemctl reboot
```

For a native A/B image, confirm the system and sysupdate timer:

```bash
systemctl is-system-running
sudo snosi-update-status --check
systemctl list-timers snosi-sysupdate-stage.timer
```

Published native images write a signed update to the inactive root and verity
slots and apply it at the next natural reboot. `snosi-update-status` reports the
running, staged, and rollback versions. Use the systemd-boot menu to select the
previous version when an explicit rollback is needed; boot counting falls back
automatically after repeated failed boots.

For bootc migration-specific backup and failure guidance, see the
[nbc to bootc migration runbook](nbc-to-bootc-migration.md). The native image,
partition, update, and boot contracts are documented in
[Native A/B Contracts](native-ab-contracts.md).
