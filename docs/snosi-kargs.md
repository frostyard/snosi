# Persistent Custom Kernel Arguments

`snosi-kargs` manages machine-specific kernel arguments on secure Snosi
installations without rebuilding an image or disabling Secure Boot. It builds a
systemd-stub UKI command-line addon and installs it globally at:

```text
<ESP>/loader/addons/50-snosi-cmdline-local.addon.efi
```

The global location applies to every installed UKI, so it follows native A/B
slot changes and bootc deployment changes rather than being tied to one
versioned UKI filename. State and optional local signing material live under
`/var/lib/snosi/kargs/`.

This interface is supported by the secure bootc (`cayo`, `snow`, `snowfield`,
`flurry`, `sundog`) and production native A/B (`cayo-ab`, `snow-ab`,
`snowfield-ab`) profiles. Base and non-secure development profiles do not carry
the addon stub and signing toolchain.

## Quick Start

Run the CLI as root:

```bash
snosi-kargs key generate
snosi-kargs key enroll
reboot
# Complete the one-time enrollment in MokManager.

snosi-kargs add mitigations=off
reboot
snosi-kargs show
```

`key enroll` uses `mokutil --generate-hash`. For that one call, mokutil exposes
the one-time plaintext password through `/proc/<pid>/cmdline`; the generated
hash file is mode 0600 and removed immediately.

Prefer an offline key when machine-local signing authority is not acceptable:

```bash
snosi-kargs set --no-apply driver.option=1
snosi-kargs apply --key /secure/offline.key --cert /secure/offline.crt
```

The certificate must already be enrolled in MOK when Secure Boot is enabled.
The private key must not be group- or world-readable. `--unsigned` is accepted
only when `mokutil` reports Secure Boot disabled.

## Commands

| Command | Behavior |
| --- | --- |
| `status` | Show transport, ESP, Secure Boot, local key, addon, arguments, and pending state |
| `list` | Print persisted managed arguments, one per line |
| `show` | Split the current effective line into managed and base/other arguments |
| `add`, `remove`, `set`, `clear` | Mutate state and apply immediately; `--no-apply` defers installation |
| `apply` | Build, verify, sync, and atomically replace the global addon |
| `revert` | Disable and remove the installed addon while retaining persisted arguments |
| `key status`, `generate`, `enroll` | Inspect or manage optional machine-local signing material |

`apply --dry-run` prints the exact ukify invocation and destination without
writing the ESP. The generated invocation deliberately omits `--linux`; this is
what selects systemd's `addonx64.efi.stub` rather than creating a bootable UKI.

## Append-Only Semantics

Addons append to the image's embedded command line. They never remove embedded
arguments. An option such as `console=` can usually be overridden because the
kernel uses its last occurrence; a flag with no negation, such as `quiet`,
cannot be removed. `show` reports the effective command line and the arguments
managed by the addon, but other global or per-UKI addons may also contribute.

The CLI refuses arguments that can replace the verified root, redirect early
userspace, or create a persistent root-shell path:

- `root=`, `rootfstype=`, `rootflags=`, `roothash=`, `usrhash=`, `composefs=`
- `systemd.verity*`, `rd.luks.*`, `systemd.gpt_auto=`
- `init=`, `rd.break`, `rd.shell`, `emergency`
- `systemd.unit=` or `rd.systemd.unit=` selecting `emergency.target` or
  `rescue.target`
- tokens containing whitespace or quotes

`--force` is an interactive override requiring an exact typed confirmation.
There is no automatic recovery from a forced argument that prevents boot.

## Trust And Measurement

Under Secure Boot, systemd-stub loads the addon only when UEFI db, shim db, or
MOK verifies its PE signature. A failed signature is skipped rather than
failing the boot. Addon sections are measured into PCR 12; Snosi's LUKS policy
uses a signed PCR 11 policy with no raw-PCR or PCR 7 binding, so changing the
addon does not invalidate TPM auto-unlock.

Enrolling a local certificate widens machine trust to a private key stored on
the same disk. Anyone with root access to that key can sign EFI binaries that
shim accepts. Linux's routing of MOK certificates between platform, secondary,
and machine keyrings depends on the kernel and shim's `MokListTrustedRT`
policy, so Snosi does **not** promise that this authority is isolated from
kernel-module trust. Treat it as boot and potentially module-signing authority.
Use an offline key when that boundary matters.

Installation is same-filesystem atomic. The old addon is retained until the
replacement and its directory are synced, and restored if replacement
durability fails. `revert` first renames the addon to a dotfile, which
systemd-stub skips, before deleting it.

## Validation Status

The non-root fixture suite covers the refusal matrix, Secure Boot decision
matrix, absence of `--linux`, MOK argument shape, dry-run behavior, and
restore-on-sync-failure.

The native secure-boot QEMU harness now applies a signed addon after TPM
enrollment and requires the argument to appear with Secure Boot still enforced
and `/var` auto-unlocked. It also requires PCR 11 to stay unchanged while PCR
12 changes, corrupts one addon byte and requires the machine to boot without
the argument, then requires the global addon to survive a real
`systemd-sysupdate` hop. The fixture suite is the validation run for this
change; the extended QEMU leg will run in the existing native nightly.

**BLOCKED:** bootc live persistence across a deployment update requires the
external Dakota/bootc-installer runner and authorized secure OCI artifacts that
Snosi does not own. Until that evidence exists, do not promise that an external
bootc ESP writer preserves `/loader/addons`; `snosi-kargs status` reports a
missing artifact as pending so an operator can re-apply it.
