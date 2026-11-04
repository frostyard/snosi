# 0027 — Seal lockdown into the secure UKI command line

- **Status:** Accepted
- **Date:** 2026-11-04

## Context

Snowfield boots with Secure Boot on and kernel lockdown `none`
([#1213](https://github.com/frostyard/snosi/issues/1213)). Lab run
`dev-snow-bootc-lifecycle-pnljz` reported `SNOW_QA_ERR lockdown`.

- The linux-surface kernel is built with
  `CONFIG_LOCK_DOWN_KERNEL_FORCE_NONE=y`. It does not raise lockdown when
  Secure Boot is on. Debian kernels raise lockdown to `integrity` under
  Secure Boot.
- `shared/bootc-secure/tree/usr/lib/bootc/kargs.d/10-lockdown.toml` declares
  `lockdown=integrity`, but bootc kargs.d does not reach a Type #2 UKI. The
  signed UKI command line was `rw composefs=?<digest>` only.
- [#615](https://github.com/frostyard/snosi/issues/615) reported the gap and
  closed without a fix.

## Decision

`shared/bootc-secure/assemble-uki.sh` seals this exact command line into the
UKI of all four secure products (Snow, Floe, Sundog and Snowfield):

```
rw composefs=?<digest> lockdown=integrity
```

One function, `sealed_cmdline`, defines the shape. Assembly passes it to
`ukify --cmdline`, and `validate_uki` requires exact equality with it.
`test/bootc-secure-artifact-test.sh` checks independently that the signed UKI
carries exactly one lockdown token, `lockdown=integrity`.

The kargs.d file stays unchanged. bootc reads it with a strict schema, and it
keeps the kargs that bootc declares consistent. It is not the enforcement
point.

## Consequences

- Snowfield boots at lockdown `integrity` under Secure Boot. For Debian
  kernels under Secure Boot the change is a no-op at runtime.
- With Secure Boot off, or on firmware without Secure Boot support (ADR-0023),
  all four products now boot at lockdown `integrity` too, where they booted at
  `none` before: the bootc Type #2 entry passes no loader command line, so the
  embedded one applies. Integrity lockdown refuses unsigned kernel modules,
  hibernation, `/dev/mem` and raw I/O port or MSR writes, and unsigned kexec.
  No shipped image or sysext loads an out-of-tree module. This is intended:
  the products are secure products whatever the firmware state.
- The PCR 11 values change. TPM2 unlock does not depend on fixed PCR 11
  values: the LUKS token is a signed policy (`--tpm2-pcrs=` empty,
  `--tpm2-public-key-pcrs=11`, pcrlock off; see
  [bootc secure install contract](../bootc-secure-install-contract.md) and
  firn `internal/enroll/tpm.go`). Every update already changes PCR 11, because
  `composefs=?<digest>` changes with every image. Each UKI carries its own
  `.pcrsig` from the same PCR key, so updates and rollbacks keep unlock.
- A rollback to a UKI from before this change boots Snowfield at lockdown
  `none` again, until the system updates.
- `snosi-kargs` addons append on PCR 12. They cannot lower lockdown, because
  the kernel only raises the lockdown level.
- `lockdown=integrity` must never leave the sealed shape. The linux-surface
  kernel has no other path to lockdown under Secure Boot.

## Alternatives considered

- **Rely on kargs.d:** it does not reach a Type #2 UKI, so Snowfield keeps
  lockdown `none`.
- **Seal lockdown for Snowfield only:** a per-product shape adds a branch to
  the assembler and to its validation, for no runtime gain on Debian kernels under Secure Boot, and it leaves
  Secure-Boot-off installs at different lockdown levels per product.
- **Remove the kargs.d file:** bootc reads it; removing it changes bootc's
  declared kargs and gains nothing.

## References

- Shapes: [design/build-pipeline.md](../design/build-pipeline.md),
  [bootc secure assembly compatibility](../bootc-secure-assembly-compatibility.md),
  [snosi-kargs](../snosi-kargs.md)
- Builds on: [ADR-0012](0012-chunked-layers-cadence-xattrs-chunk-before-seal.md)
  (the composefs digest bound into the UKI)
