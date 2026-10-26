# 0023 — Skip bootloader reconcile without Secure Boot support

- **Status:** Proposed
- **Date:** 2026-10-26

## Context

The bootc bootloader reconciler (`snosi-bootc-bootloader-reconcile`) keeps the
shim second stage current. #928 made it skip when no second stage is installed
and the `SecureBoot` EFI variable reads 0. Any other state fails closed.

Firmware without Secure Boot support has no `SecureBoot` variable at all. Examples
are QEMU with the non-secboot `OVMF_CODE_4M.fd`, some hypervisors and older
boards. The reconciler reads this as unknown, so every install on such firmware
ends `degraded` (Sundog `20261026191618`, Firn 0.10.0). See #1160.

## Decision

When efivarfs is mounted and readable and the `SecureBoot` variable is absent, the
reconciler treats the firmware as not supporting Secure Boot. If no shim second
stage is installed, it then prints one skip line and exits 0.

"Mounted and readable" means: the efivars directory is readable and searchable,
`stat -f` reports `efivarfs`, and the directory lists at least one entry. A
missing, unmounted, unreadable or empty efivarfs, and a `SecureBoot` entry
that is a dangling symlink, not a regular file, unreadable, truncated or
non-boolean, still fail closed. An installed second stage is reconciled in
every state.

## Consequences

- One more skip path in the reconciler.
- It relies on the UEFI rule that `SecureBoot` exists only on firmware that
  supports Secure Boot.
- A firmware that enforces Secure Boot but hides the variable from a working
  efivarfs would skip. No such case is known. The skip changes only what the
  unit reports: the reconciler never creates a missing second stage, so in
  that case it writes nothing to the ESP either way, and the boot chain is not
  weakened. The cost is one lost failure signal on such firmware.
- This changes the fail-closed policy that #928 set: an absent `SecureBoot`
  variable is no longer "unknown" when efivarfs is readable.
- Unknown states still fail closed.
- The reconciler test pins each case.

## Alternatives considered

- **`ConditionSecurity=uefi-secureboot` on the unit (option 2):** it skips when
  enforcement is on but unreadable, which #928 rejected.
- **Keep the behaviour and document it (option 3):** every install on such
  firmware stays `degraded`.

## References

- Shapes: [bootc secure install contract](../bootc-secure-install-contract.md)
- Code: `shared/bootc-secure/tree/usr/libexec/snosi-bootc-bootloader-reconcile`,
  `test/bootc-bootloader-reconcile-test.sh`
- Builds on: #928, #1160
