# Installing published Snosi images

This guide covers the two published x86-64 installation paths linked from the
project README:

- the **bootc live ISO**, which installs the ordinary bootc/composefs images;
- the **native A/B network installer**, which installs the signed native A/B
  images with Secure Boot enrollment and encrypted `/var`.

Both installers erase the selected target disk. Back up anything you need and
verify that the backup is readable from another machine before booting either
installer.

## Choose an installation path

| Path | Choose it when | Products | Target disk |
| --- | --- | --- | --- |
| Bootc live ISO | You want the established bootc/composefs layout and graphical installer | `snow`, `snowfield`, `flurry`, `sundog`, `cayo` | At least 30 GiB |
| Native A/B installer | You want signed A/B systemd-sysupdate images, Secure Boot through MOK, and encrypted `/var` | `snow-ab`, `snowfield-ab`, `cayo-ab` | 15.5 GiB for Cayo; 21.5 GiB for Snow or Snowfield |

Use a larger disk than the minimum when possible. The native minimum leaves
only 4 GiB for `/var`; applications, containers, Flatpaks, home directories,
and update state all consume `/var`.

Available products depend on the installation path:

- **Snow** is the general-purpose GNOME desktop.
- **Snowfield** is the GNOME desktop for Microsoft Surface devices.
- **Flurry** is the Hyprland desktop and is available only through bootc.
- **Sundog** is the KDE Plasma desktop and is available only through bootc.
- **Cayo** is the headless server image.

The native installer supports UEFI x86-64 systems. Leave Secure Boot enabled;
the installer boots through Debian's trusted chain and stages the Snosi MOK
enrollment required by the installed image. TPM 2.0 is recommended for
automatic `/var` unlock. Without a TPM, the external recovery passphrase is
required at boot.

The bootc live ISO installs the established ordinary bootc path. It is not the
separately gated secure bootc DPS/LUKS/MOK/TPM path, which remains unsupported
pending live and hardware evidence. See
[Bootc Secure Operations](bootc-secure-operations.md) for that boundary. Use
native A/B when you need the currently published Snosi Secure Boot and TPM
installation flow.

## Download installation media

Download one ISO:

```bash
# Ordinary bootc/composefs installer
curl -fL https://repository.frostyard.org/isos/snow-live-latest.iso \
  -o snow-live.iso

# Native A/B installer
curl -fL \
  https://repository.frostyard.org/isos/native/v1/snosi-installer-latest-x86-64.iso \
  -o snosi-installer.iso
```

The native installer's `latest` URL redirects without caching to the immutable,
versioned ISO named by its signed checksum index. Verify both the signing-key
fingerprint and the ISO before writing media:

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

Stop if the fingerprint, OpenPGP signature, or SHA-256 check fails.

The signed native checksum index applies only to the native installer. The
bootc live ISO currently has no companion checksum in the published `/isos`
namespace. Download it only from the HTTPS URL above. During installation, the
bootc installer Cosign-verifies the selected OCI image and pins the install to
the verified digest before writing the target disk.

## Write and boot the installation media

You can use a graphical disk-imaging tool's **Restore Disk Image** operation,
or write the ISO from a Linux terminal. The destination must be the whole USB
device, such as `/dev/sdb`, not a partition such as `/dev/sdb1`.

1. Insert a USB drive and identify it by size, model, and serial:

   ```bash
   lsblk -o NAME,PATH,SIZE,MODEL,SERIAL,TRAN,MOUNTPOINTS
   ```

2. Unmount every mounted partition on that USB drive.
3. Set `ISO` and `DISK`, inspect them again, and write the image:

   ```bash
   ISO=snosi-installer.iso  # or snow-live.iso
   DISK=/dev/sdX                   # replace with the whole USB device

   test -f "$ISO"
   test -b "$DISK"
   lsblk -o NAME,PATH,SIZE,MODEL,SERIAL,TRAN,MOUNTPOINTS "$DISK"
   sudo dd if="$ISO" of="$DISK" bs=4M status=progress conv=fsync
   sync
   ```

   `dd` permanently overwrites the selected device. Do not continue unless
   the `lsblk` identity is the disposable USB drive.

4. Reboot, open the firmware's one-time boot menu, and select the UEFI entry
   for the USB drive. Do not select the disk you intend to install onto.

## Install with the bootc live ISO

The live ISO starts a Snow GNOME session and automatically opens **Install Snow
Linux**. If it was closed, launch **Install Snow Linux** (also shown as
**Dakota Installer**) from the application grid.

1. Connect to the network. Snow may be available from the media, but another
   selected product or a newer image can require a registry download.
2. On the image page, choose Snow, Snowfield, or Cayo.
3. Select the target disk. Confirm it by model, size, and serial before
   continuing; the entire disk will be erased.
4. Configure disk encryption and record its unlock credential outside the
   target machine.
5. Create the first user and store its password safely.
6. Start the installation and wait for the completion page. The installer
   resolves the selected image to an immutable digest and verifies its Cosign
   signature before installation.
7. Reboot, remove the USB drive, and boot the installed disk. Log in with the
   account created by the installer.

After the first boot, confirm system and update state:

```bash
systemctl is-system-running
sudo bootc status
sudo snosi-update-status --check
systemctl list-timers bootc-update-stage.timer
```

Published bootc images check for updates hourly, stage an available update,
and apply it at the next natural reboot. They do not force a reboot. To return
to the previous bootc deployment:

```bash
sudo bootc rollback
sudo systemctl reboot
```

For migration-specific backup, restore, and failure guidance, see the
[nbc to bootc migration runbook](nbc-to-bootc-migration.md).

## Install with the native A/B ISO

The native installer downloads a signed image from
`repository.frostyard.org`, verifies its signed index and compressed-image
checksum, writes it to the selected disk, and then creates the machine-specific
encrypted `/var`.

On a machine with a display, the **Install Snosi Linux** kiosk starts
automatically. It walks through product, network, locale, keyboard, timezone,
hostname, first user, optional extensions, applications, disk, recovery key,
and Secure Boot enrollment.

If the graphical installer cannot start, boot with the
`snosi.textmode=1` kernel option. At the local console, log in as `root` with
no password and run:

```bash
/usr/libexec/snosi-install
```

The text installer asks for the same security-relevant choices and refuses to
choose a disk or credential silently.

During either flow:

1. Select `snow-ab`, `snowfield-ab`, or `cayo-ab`.
2. Select the target disk by path, model, serial, size, and transport. Mounted,
   undersized, ambiguous, RAID-member, and installer-media disks are refused.
3. Type the exact disk path or serial to confirm erasure.
4. Create the first user. Skipping this leaves no normal login account; do so
   only when you have another tested access path, such as an installed root SSH
   key.
5. Choose optional sysext features. Snow and Snowfield also offer the core
   Flatpak set for first-boot provisioning.
6. Supply a one-time MOK enrollment password.
7. Finish the install. On the final screen, copy the generated `/var` recovery
   passphrase to a password manager, another removable device, or paper. The
   copy stored in the live environment disappears at reboot. Do not reboot
   until an off-machine copy is safe and readable.

### Complete MOK enrollment

Remove the USB drive and boot the installed disk. MokManager displays a blue
screen with a short countdown:

1. Press any key before the countdown expires.
2. Select **Enroll MOK**.
3. Select **Continue**, then **Yes**.
4. Enter the one-time MOK password from the installer.

The machine reboots again and then starts Snosi. Missing the prompt, entering
the wrong password, or allowing it to time out leaves the installed
MOK-signed boot chain untrusted and prevents it from booting.

On the first successful boot, Snosi provisions the sysext features and core
Flatpaks selected in the installer. This can take time on a slow connection
and retries on later boots until complete:

```bash
systemctl status snosi-firstboot.service
sudo snosi-update-status --check
systemctl list-timers snosi-sysupdate-stage.timer
```

Published native images check for signed updates hourly. An update is written
to the inactive root and verity slots and applies at the next natural reboot;
the system never forces that reboot. `snosi-update-status` reports the running,
staged, and rollback versions. Use the systemd-boot menu to select the previous
version when an explicit rollback is needed; boot counting automatically falls
back after repeated failed boots.

### Native recovery

- **TPM unavailable or replaced:** unlock `/var` with the externally stored
  recovery passphrase. Loss of both TPM authorization and that passphrase is
  unrecoverable.
- **MOK enrollment was missed or failed:** boot the native installer ISO,
  enter text mode, and run:

  ```bash
  /usr/libexec/snosi-install --restage-mok
  ```

  The command auto-detects the installed disk when exactly one native A/B
  installation is present. Otherwise add `--disk /dev/<device>`. It stages a
  new one-time password without repartitioning or reinstalling.
- **Installer failed after disk writing began:** treat the target disk as
  incomplete and rerun the installer. The native installer wipes the target's
  partition table after a failed or checksum-mismatched streamed download so a
  partial image is not left looking bootable.

The frozen native image, partition, update, and boot contracts are documented
in [Native A/B Contracts](native-ab-contracts.md).
