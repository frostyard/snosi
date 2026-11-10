# 0033 — Seal the Plymouth splash into the secure UKI command line

- **Status:** Proposed
- **Date:** 2026-11-09

## Context

Snow and Snowfield ship the Snow Plymouth theme
(`shared/snow/tree/usr/share/plymouth/themes/snow/`, `Theme=snow`), and
Sundog ships Plymouth with the Breeze theme (`Theme=breeze`). Floe ships no
Plymouth. No product boots with the splash
([#1242](https://github.com/frostyard/snosi/issues/1242)).

- `shared/composition/snow/mkosi.conf` set
  `KernelCommandLine=splash plymouth.ignore-serial-consoles quiet`. That value
  reached only the native A/B UKIs, which
  [ADR-0018](0018-remove-native-ab-and-nbc-lanes.md) removed. mkosi
  `KernelCommandLine=` reaches no bootc product, and bootc kargs.d does not
  reach a Type #2 UKI. The Sundog composition said that bootc supplies the
  splash arguments at install; it does not.
- [ADR-0027](0027-seal-lockdown-into-the-secure-uki-command-line.md) seals
  one command line into the UKI of all four products:
  `rw composefs=?<digest> lockdown=integrity`. The bootc Type #2 entry passes
  no loader command line, so this sealed line is the whole command line,
  plus any `snosi-kargs` addon.
- The initramfs already carries Plymouth on the products that ship it.
  `shared/kernel/scripts/postinst/mkosi.postinst.chroot` runs
  `dracut --no-hostonly`, which includes dracut's `plymouth` module when the
  rootfs has `plymouthd`. In main run 42691198531 (2026-11-09) the Snow and
  Sundog initramfs builds log `Including module: plymouth`, the configured
  theme (`themes/snow` with `two-step.so`; `themes/breeze` with `script.so`)
  and `renderers/drm.so`; the Floe build includes no Plymouth.
- `plymouth-start.service` runs without `splash` (its only conditions are
  `!plymouth.enable=0`, `!nosplash` and no container). Without `splash` on
  the command line, plymouthd uses its text `details` plugin. So the products
  run Plymouth on every boot today, in text mode, and the only missing piece
  for the branded splash is the `splash` token.

## Decision

`shared/bootc-secure/assemble-uki.sh` seals one of two command lines. The
choice depends on the rootfs, not on a product name:

```
rw composefs=?<digest> lockdown=integrity               # no plymouthd
rw composefs=?<digest> lockdown=integrity splash quiet  # rootfs ships plymouthd
```

- `rootfs_ships_plymouth` reads `usr/sbin/plymouthd` in the rootfs. A
  regular executable file selects the splash shape. An absent path selects
  the first shape. Any other state (a symlink, a directory, a file that is not
  executable) fails the assembly.
- `sealed_cmdline` stays the one definition of both shapes. Assembly passes
  the selected shape to `ukify --cmdline`, and `validate_uki` requires exact
  equality with the shape for that rootfs. Both shapes carry exactly one
  lockdown token, `lockdown=integrity`, in the same place.
- `test/bootc-secure-artifact-test.sh` checks the signed UKI independently,
  per product (`ID=` in `usr/lib/os-release`): Snow, Snowfield and Sundog
  carry `splash` and `quiet` once each and ship `plymouthd`; Floe carries
  neither token and ships no `plymouthd`; no product carries `nosplash` or a
  `plymouth.*` token; an unknown product fails.
- The dead `KernelCommandLine=` line and its native A/B comment leave the
  Snow composition. `test/bootc-secure-static-test.sh` now rejects
  `KernelCommandLine=` in every tracked `.conf` file except the Firn
  installer's, not only in the secure fragment.
- The sealed line carries no `plymouth.ignore-serial-consoles`. It carries no
  `console=` argument, so the kernel console is the local display. A serial
  console comes only from an operator addon or from firmware. Plymouth then
  falls back to text mode on all consoles (seen with `plymouth.debug` in QEMU
  on the native lane, 2026-07-17), and the LUKS passphrase prompt stays on
  the serial console. A serial operator types it there, and so does the
  passphrase-unlock cell of frostyard/lab
  ([`run-firn-install-tests.yaml`](https://github.com/frostyard/lab/blob/main/argo/workflow-templates/run-firn-install-tests.yaml)).
  `plymouth.ignore-serial-consoles` would take that prompt off the serial
  console.

### Why this branch differs from the one ADR-0027 rejected

ADR-0027 rejected a per-product lockdown shape: lockdown is a security
property, a branch gains nothing at runtime on Debian kernels, and it leaves
products at different lockdown levels. The splash is a presentation property
of a payload that only three products ship. On Floe, `splash` would find no
Plymouth, and `quiet` would hide kernel messages on a server console that
stays in text mode. The branch keys on the payload, so the assembler carries
no product table, and lockdown stays identical in both shapes.

## Consequences

- Snow and Snowfield show the Snow splash, and Sundog the Breeze splash,
  from the initramfs on. When TPM2 unlock fails, the LUKS passphrase prompt
  is Plymouth's graphical prompt on the local display.
- `quiet` sets the kernel console log level to 4: only errors and worse print
  on the console. systemd prints status only for failed or slow jobs. The
  journal and `snosi-health` still record everything.
- The PCR 11 values change on Snow, Snowfield and Sundog. Unlock does not
  depend on fixed PCR 11 values (the signed PCR policy of ADR-0027 applies),
  and every update changes PCR 11 already.
- A rollback to a UKI from before this change boots in text mode again.
- An operator can turn the splash off with a `snosi-kargs` addon:
  `nosplash` or `plymouth.enable=0` stops `plymouth-start.service`, and a
  later `loglevel=7` or `systemd.show_status=1` brings the text back. An
  addon cannot remove `lockdown=integrity`; see ADR-0027.
- Plymouth's DRM renderer now runs in the initramfs of these products on
  every graphical boot. plymouthd 24.004.60 has known crashes (a VT
  handoff race, [#850](https://github.com/frostyard/snosi/issues/850), and
  two DRM cards in one VM, `test/lib/vm.sh`). The bounded DRM and fbcon
  barrier
  `shared/snow/tree/usr/lib/systemd/system/plymouth-start.service.d/10-wait-drm.conf`
  applies to the Snow and Snowfield real root only: the initramfs does not
  carry it, and Sundog does not include `shared/snow/tree`, so Sundog, on the
  same backports kernel that the barrier's comment ties to #850, has no
  barrier at all. A crash
  does not stop the boot, but it can degrade the system state. A visible
  splash on real or VM graphics, and a clean boot state, on Snow and on
  Sundog, are post-merge lab checks; no PR job builds or boots the image.
- A new product that ships `plymouthd` gets the splash shape without an
  assembler change, but `test/bootc-secure-artifact-test.sh` fails until its
  product list names it.

## Alternatives considered

- **Delete the dead line only:** the shipped themes stay unused, and the
  products keep the text boot that the Snow composition was built to avoid.
- **A product table in the assembler (Snow, Snowfield, Sundog):** it repeats
  what the package lists already say, and a product that gains or loses
  Plymouth gets a shape that does not match its payload. The independent
  artifact test keeps a product list, so a payload change still fails a build.
- **Keep `plymouth.ignore-serial-consoles`:** the native line needed it
  because it carried `console=ttyS0`. The sealed line has no serial console,
  and the flag would move the passphrase prompt away from an operator's
  serial console.
- **`splash` without `quiet`:** kernel text would paint the display before
  plymouthd takes it, which the Snow design set out to hide.
- **A kargs.d entry:** it does not reach a Type #2 UKI.

## References

- Shapes: [design/build-pipeline.md](../design/build-pipeline.md),
  [design/overview.md](../design/overview.md), [snosi-kargs](../snosi-kargs.md)
- Amends: [ADR-0027](0027-seal-lockdown-into-the-secure-uki-command-line.md)
  (the sealed shape is no longer one line for all four products)
- Builds on: [ADR-0018](0018-remove-native-ab-and-nbc-lanes.md) (the native
  UKIs that carried the old splash arguments are gone)
