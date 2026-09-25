# Spec: Manual Secure Snow Bootc Lab Handoff

This contract governs one disposable, manual, non-release-gating Snow **bootc**
install → signed update → rollback run. Snosi owns the input manifest and its
offline shape validator (`test/bootc-secure-lab-manifest.py`); the downstream lab
owns artifact authentication, Firn installation, guest execution, and retained
results. This is the **first increment planned**, not evidence of a completed
secure lifecycle run. Without retained live proof, the result is BLOCKED and
update/rollback remain unproven.

## Interface

One UTF-8 JSON object per run, passed **unchanged** to the validator before
creating a VM: `python3 test/bootc-secure-lab-manifest.py <manifest.json>`.
The validator checks shape only, not signature, hash, registry state, or boot.
The lab MUST retain the SHA-256 of the exact manifest bytes alongside its
sanitized run record. No producer of real N/N+1 refs is supplied by this
contract. The exact, closed schema (no additional keys) is:

| Field | Type | Required | Constraints |
| --- | --- | --- | --- |
| `schema` | integer | yes | Exactly `1` (not a JSON boolean) |
| `family` | string | yes | Exactly `bootc` |
| `product` | string | yes | Exactly `snow` |
| `installer_iso_url` | string | yes | HTTPS host and versioned `snosi-installer_YYYYMMDDHHMMSS_x86-64.iso` path; no query/fragment, whitespace or credentials |
| `installer_iso_sha256` | string | yes | 64 lowercase hex characters |
| `image_n` | string | yes | Immutable `ghcr.io/frostyard/snow@sha256:<64 lowercase hex>` |
| `image_n_plus_1` | string | yes | Same immutable Snow digest grammar, distinct from `image_n` |
| `version_n` | string | yes | Valid 14-digit UTC `YYYYMMDDHHMMSS` timestamp |
| `version_n_plus_1` | string | yes | Valid 14-digit UTC timestamp strictly later than `version_n` |
| `target_ref` | string | yes | Tagged `ghcr.io/frostyard/snow:<tag>` (tag begins alphanumeric/underscore, then at most 127 alphanumeric/underscore/dot/hyphen characters) |
| `cosign_key_sha256` | string | yes | 64 lowercase hex characters; hash of committed `cosign.pub` |

The parser caps input at 65536 bytes and refuses duplicate, missing, extra,
wrong-type or malformed fields. These constraints describe preflight, not proof
that any ref is signed, reachable, or actually booted. Synthetic examples in
`test/bootc-secure-lab-manifest-test.py` are **not** authorized lab identities.

## Rules

1. **Preflight and custody:** the lab MUST run the offline validator on the
   unchanged manifest before VM creation; a failure stops the run. It MUST
   compute and retain the manifest's SHA-256 with the sanitized run record. No
   private key, recovery passphrase, MOK password, TPM state, or writable
   firmware variables may enter the manifest or retained logs. Missing verified
   N, N+1, or channel identity means BLOCKED, not a fixture PASS.
2. **Authenticate inputs independently:** download the exact versioned ISO
   at `installer_iso_url` and verify its bytes against `installer_iso_sha256`
   (and apply Firn's normal ISO trust checks). Hash the committed `cosign.pub`
   and require `cosign_key_sha256` equality; verify **both** immutable OCI refs
   `image_n` and `image_n_plus_1` with Cosign using that committed key, and
   confirm their signed repository/digest identities, secure-capable labels,
   and declared versions match the manifest. Never accept `:mechanics`, a
   mutable tag as either image identity, or a foreign repository. An unsigned
   or wrong-key image fails closed. Retain public verification evidence.
3. **Installer handoff:** the lab-owned Firn recipe MUST use
   `image.ref=image_n`, explicitly `image.target_ref=target_ref`, the pinned
   committed Cosign public key, `tpm2-luks` encryption and MOK mode under
   enforced Secure Boot. The manifest is Snosi-owned input, **not** a Dakota
   handoff or a substitute for Firn's image schema-1 installer contract. Use
   disposable VM disk, firmware and vTPM state; do not mutate a workstation.
   Guest command transport may require a secure SMBIOS/serial probe; SSH or an
   agent is not assumed to be available.
4. **Channel stability:** resolve `target_ref` in the registry to its current
   manifest digest and require exact equality with `image_n_plus_1` **before
   and after** the stage. If the tracking tag drifts or cannot be verified,
   fail closed; the lab MUST NOT rewrite or move the tag. The shipped updater
   pulls `.spec.image.image` with Podman under the shipped repository-scoped
   signature policy; it first switches to `containers-storage` and compares
   the staged registry manifest digest to its pulled digest. The lab MUST
   independently record the signed-image check and `bootc status --format json`
   at each boundary rather than treating a stager exit code as boot proof.
5. **Live sequence:** install and boot N with Firn, record unique
   `/proc/sys/kernel/random/boot_id`, then run production
   `/usr/libexec/bootc-update-stage` in the guest. Require
   `.status.staged.image.imageDigest` in `bootc status --format json` to equal
   N+1's `image_n_plus_1` registry digest. Reboot to N+1 with a **new** boot
   ID and require fresh-boot `.status.booted.image.imageDigest` equality to
   N+1. Run `bootc rollback`, reboot to N with a third distinct boot ID and
   require `.status.booted.image.imageDigest` equality to `image_n`. Check the
   initial booted digest against N too. Never infer a boot from a staged
   record or a still-running guest process.
6. **Every boot:** require enforced Secure Boot, measured UKI, unattended TPM
   LUKS2 root unlock after enrollment, and the same lab-written markers in
   persistent `/var` and `/etc` (set on N, checked on N+1 and rollback N).
   Retain sanitized console/runtime checks, boot IDs, public trust fingerprints,
   version/digest observations, and independent signed-image verification.
   If any evidence is absent or a check fails, report BLOCKED/unproven; a
   passing parser or Firn fresh-install E2E alone does not prove update or
   rollback. No recovery, key rotation, ESP/bootloader repair, Snowfield
   hardware, or production support claim follows from this first proof.

## Derived artifacts

| Artifact | Derivation |
| --- | --- |
| Sanitized manual run record | Exact manifest SHA-256 plus redacted public artifact, registry, stage, boot, rollback and persistence observations (no credentials or firmware/TPM state) |
| CI fixture | `python3 test/bootc-secure-lab-manifest-test.py` checks parser shape and this spec's key lab obligations only; it does not run a VM |

## References

- Rationale: [ADR-0008](../adr/0008-digest-first-release-latest-is-promotion.md)
  (immutable digest and tag boundary), [ADR-0010](../adr/0010-credential-handoff-paths-not-bytes.md)
  (no secret bytes in handoffs), and [core ADR-0031](https://github.com/frostyard/core/blob/main/docs/adr/0031-retire-dakota-secure-bootc-installer.md)
  (Firn installer ownership).
- Context: [design/testing.md](../design/testing.md) (fixture vs live proof),
  [bootc-secure-operations.md](../bootc-secure-operations.md) (support and evidence status).
