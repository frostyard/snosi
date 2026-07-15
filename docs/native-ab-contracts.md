# Native A/B Contracts (Frozen, Phase 0)

**Status:** Frozen. This document is the normative source of truth for native
A/B naming, paths, and policy. It defines values; it does not discuss
rationale — see `docs/plans/2026-07-14-bootc-native-ab-coexistence-plan.md`
for the design narrative and phased rollout that this freeze unblocks.

Every value below is validated statically by `test/native-ab-contracts-test.sh`.
That test is the executable form of this document. If the two disagree, the
test is currently wrong (fix it) unless a value here was deliberately changed
(update both in the same commit).

Known deviations between the current prototype and this contract are tracked,
not silently tolerated, via `test/native-ab-contracts-allow.txt`. Every
allowlist entry names the phase that removes it.

## 1. Products, profiles, channels

| Kind | Names |
|---|---|
| bootc profiles (unchanged) | `cayo`, `snow`, `snowfield` |
| Production native profiles | `cayo-ab`, `snow-ab`, `snowfield-ab` (secure posture only) |
| Development fixtures | `cayo-ab-raw` (Phase 1 rename of today's `cayo-ab`; never published) |
| Shared secure posture fragment | `shared/native-ab-secure/mkosi.conf` (Phase 3 generalization of the retired `cayo-ab-secure` spike profile; `Include=`d by all three production native profiles) |

A profile literally named `cayo-ab`, `snow-ab`, or `snowfield-ab` is
production-facing and MUST satisfy the publication guard (§15). It must never
mean "raw prototype" at any point after Phase 1. Today's `cayo-ab` is the raw
prototype and fails the guard; it is allowlisted with tag `pending-rename`
until Phase 1 renames it to `cayo-ab-raw`.

Channel name = `<ImageId>-ab`. `ImageId` stays `cayo`/`snow`/`snowfield` in
native profiles (branding, `os-release`, sysext compatibility all key off
`ImageId`, not the channel name).

## 2. Version grammar

Exactly 14 ASCII digits, UTC `YYYYMMDDHHMMSS`.

```text
^[0-9]{14}$
```

Maximum version length is frozen at 14 code units. No suffixes of any kind
(no `+rN`, no `-dirty`, no build metadata) in the OS version. This is
distinct from sysext versions, which retain their existing package-derived
`+rN` suffix convention.

## 3. GPT partition labels

Dynamic slots (rewritten per publish):

```text
<ImageId>_<version>_r     # root
<ImageId>_<version>_v     # verity
```

Static labels (fixed forever): `_empty` (inactive slot at build time), `esp`,
`var`.

Worst case is `snowfield_<14 digits>_v` = 26 code units. The frozen ceiling is
**30 code units** for every product/suffix combination, leaving at least 6
code units of headroom against the GPT partition-name limit of 36 UTF-16 code
units. A label MUST NOT be chosen that leaves less headroom, even if it still
fits under 36.

Today's repart labels (`cayo_%A_root`, `cayo_%A_root_verity`) predate this
format. `cayo_%A_root_verity` computes to 31 code units with a 14-digit
version — already over the 30-unit ceiling — and is allowlisted with tag
`pending-label-shortening` until Phase 1/3 renames the split to `_r`/`_v`.

## 4. Public artifact names

Per product directory:

```text
<channel>_<version>_<partuuid>.root.raw.xz
<channel>_<version>_<partuuid>.root-verity.raw.xz
<channel>_<version>.efi
<channel>_<version>.disk.raw.xz
<channel>_<version>.manifest.json
<channel>_<version>.sbom.spdx.json
```

`<channel>` = `<ImageId>-ab` (§1). `<partuuid>` is the lowercase-hex partition
UUID assigned at repart time.

Index files, one pair per product directory:

- `SHA256SUMS` — machine-consumed channel pointer; normally lists only the
  currently promoted version.
- `SHA256SUMS.gpg` — detached OpenPGP signature over the exact bytes of
  `SHA256SUMS`.

Both index files: `Cache-Control: no-store`, a Cloudflare cache-bypass rule
for their exact names, and an explicit purge on every promotion. Publication
order is signature first, manifest last (§ Atomic Publication Procedure in
the plan) — this document freezes the *names*; the plan freezes the
*procedure*.

Naming implemented by `shared/native-ab/publish/prepare-native-publication.sh`
(Phase 3): given an mkosi output directory and a built profile's `Output=`
name (validated to equal `<ImageId>-ab`, refusing e.g. the never-published
`cayo-ab-raw` fixture), it derives product/channel/version from the built
artifacts themselves and produces the `.root.raw[.xz]`, `.root-verity.raw[.xz]`,
`.efi`, `.disk.raw[.xz]`, and `.manifest.json` names above plus an unsigned
`SHA256SUMS` (signing is the Phase 7 promotion step, §7) and a
`publication-info.json` pipeline record. `.sbom.spdx.json` generation is not
yet wired into this script. Exercised statically (no root, no image build) by
`test/native-publish-test.sh`.

## 5. R2 namespaces

```text
https://repository.frostyard.org/os/native/v1/<product>/x86-64/     # product = cayo | snow | snowfield
https://repository.frostyard.org/isos/native/v1/
https://repository.frostyard.org/ext/<name>/                        # sysexts, unchanged
```

The current prototype transfers bake `https://repository.frostyard.org/os/cayo/%a/`
into their `[Source] Path=`. That is a tracked deviation from the frozen URL
above, allowlisted with tag `legacy-url` in the three OS transfer files
(`10-root-verity.transfer`, `20-root.transfer`, `90-uki.transfer`) until
Phase 3 replaces every shipped transfer and validates the baked client path
against the publisher path as one contract.

## 6. Sysupdate target and component topology

The default target directory contains ONLY the OS transfers:

```text
/usr/lib/sysupdate.d/
  10-root-verity.transfer
  20-root.transfer
  90-uki.transfer
```

Every independently versioned sysext lives in its own named component:

```text
/usr/lib/sysupdate.<name>.d/
  <name>.transfer
  <name>.feature
```

Component name = sysext name. Admin overrides live at
`/etc/sysupdate.<name>.d/<name>.feature.d/*.conf`.

Today all 17 sysext transfer/feature pairs ship in the default
`/usr/lib/sysupdate.d/` (in
`mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/`), one shared target with
the OS transfers once native profiles exist. Each is allowlisted with tag
`component-migration` until Phase 1 adds `frostyard-updex` component
discovery and migrates each pair to its own `sysupdate.<name>.d/`.

## 7. Key ownership, custody, and rotation

| Key | Purpose | Production custody | Dev/local custody |
|---|---|---|---|
| Secure Boot / MOK key | Signs systemd-boot, UKIs, and only modules proven to need re-signing | Protected signer (HSM/PKCS#11 or locked self-hosted signer); never a general-runner secret, never an Actions artifact | `mkosi.key` / `mkosi.crt` (gitignored, DEV ONLY) |
| PCR signing key | Signed PCR 11 policy authorizing per-machine LUKS `/var` | Protected signer | `.snosi-private/pcr-signing.key` |
| OpenPGP update key | Signs `SHA256SUMS` | Private key only in the protected promotion environment | N/A — dev builds are unsigned/unpublished |
| R2 credentials | Upload authorization only | Scoped to write immutable candidate/promoted objects; compromise MUST NOT authenticate updates (that is the OpenPGP key's job) | N/A |

Rotation:

- **MOK key** — see `MOK Rotation` below.
- **PCR signing key** — dual-signed transition UKIs, already validated (see
  CLAUDE.md "Native A/B Prototype" rotation rules): archive the old private
  key under `.snosi-private/history/`, make the new key active, set
  `PCR_SIGNING_KEY_PREVIOUS` to the old key's filename for transition builds,
  keep the old TPM token until every supported rollback UKI carries the new
  signature.
- **OpenPGP update key** — overlap window: both old and new public keys ship
  in the shipped pubring simultaneously until every supported client has
  fetched an index signed by the new key.

The public update key is committed in-repo at
`shared/native-ab/keys/import-pubring.gpg` and shipped at
`/usr/lib/systemd/import-pubring.gpg`. (This path was created in Phase 3 as a
DEV-only key — see `shared/native-ab/keys/README.md` — to unblock the
publication guard ahead of schedule; the protected signing pipeline that
replaces it with the real production key lands in Phase 7.)

### Protected signing architecture

1. An unprivileged build job creates the root, verity tree, kernel, initrd,
   unsigned UKI inputs, manifests, and provenance without long-lived keys.
2. A protected signer accepts artifacts only from a trusted main-branch build
   with verified provenance and expected hashes.
3. The signer creates expected-PCR signatures, constructs or updates the UKI,
   applies the Secure Boot signature, signs systemd-boot, and assembles the
   final ESP/full disk from those signed artifacts.
4. Private-key operations use a restricted HSM, PKCS#11 provider, or locked
   self-hosted signer where possible; plaintext key files are never Actions
   artifacts and are never mounted while repository build scripts execute.
5. Publication verifies that signed output still binds the exact root,
   verity, kernel, initrd, command line, and source revision from the
   candidate build.

Interim fallback (only until mkosi can split final assembly from signing): a
dedicated protected builder that runs only trusted main commits, has no pull
request or fork trigger, receives secrets ephemerally, and is destroyed or
scrubbed after each build. This is an accepted interim risk, not the final
custody model, and must not be treated as good enough to skip step 1-5 above
when mkosi gains native split-signing support.

### MOK rotation

- Publish the new certificate while all binaries remain signed by the old
  key.
- Stage `mokutil --import` through a guarded migration service or installer
  and require the user to complete MokManager enrollment.
- During overlap, new installation media requests both certificates; old
  installations retain the old certificate for rollback binaries.
- Switch new UKIs, systemd-boot, and any Snosi-signed modules to the new key
  only after the supported fleet has enrolled it.
- Keep old-signed rollback UKIs supported until their rollback window
  expires.
- Treat emergency revocation as a separate recovery procedure; an image
  update MUST NOT silently change firmware/MOK trust on an unattended
  machine.
- Provide a command that reports whether each required certificate is
  present before promotion to new-key-only binaries.

`Verify=yes` is required in every native OS transfer (§ Key table, R2 row).
Sysext transfers are `Verify=false` today; that is an explicit accepted risk
until component migration ships signed per-component `SHA256SUMS`, and
unsigned sysexts must not be enabled by default on production native
installs until then.

## 8. Installer ISO boot chain

```text
Microsoft firmware db
  -> Debian-signed shim
  -> Debian-signed GRUB
  -> Debian-signed stock kernel
  -> installer initrd/userspace (coherent Forky systemd 261 cryptsetup/TPM family)
```

Never Snosi-MOK-only for the ISO: the ISO boots before any Snosi MOK exists
on the target machine's firmware and must validate on hardware that has never
enrolled a Snosi certificate, with Secure Boot enforced.

## 9. Kernel module/firmware policy

Release native profiles ship the complete packaged module and firmware set.
No final-root `KernelModules=` pruning. Initrd content is controlled via
dracut configuration only, with the custom dracut archive kept authoritative
through `Initrds=` and `KernelModulesInitrd=no`.

The virtio-only filter, now in `mkosi.profiles/cayo-ab-raw/mkosi.conf`
(Phase 3 moved it out of the shared `shared/outformat/ab-root/mkosi.conf`
fragment, which no longer carries any `KernelModules=` line), is permitted
**only** in the `cayo-ab-raw` dev fixture; it must never ship in `cayo-ab`,
`snow-ab`, or `snowfield-ab`.

## 10. `/var` mount contracts

| Posture | Unlock | fstab |
|---|---|---|
| Secure (production) | initrd unlocks `/dev/disk/by-partlabel/var` as `/dev/mapper/var` | `/dev/mapper/var` |
| Raw (dev fixture only, never published) | none | `PARTLABEL=var` directly |

A raw fstab entry is never assumed harmless merely because the initrd
happened to mount an encrypted mapper device first — the two contracts are
mutually exclusive per image.

## 11. Mkosi pin

The pinned commit comes from the `systemd/mkosi@<sha>` reference in
`.github/workflows/build.yml`. That is the single source of truth; the
Justfile's `.mkosi/` bootstrap and CI both read it at build/run time, so
local and CI mkosi cannot drift. Pin changes follow the plan's "Mkosi Pin
Governance" checklist (man-page/implementation diff, static summaries for
every profile, clean builds of all three products, artifact/format
comparison against the previous pin, full validation-gate rerun) and merge
in a commit separate from any payload change.

## 12. Capacity policy

| Product | ESP | Root slot |
|---|---|---|
| cayo | 1 GiB | 5 GiB (measured 2026-07-14, full module/firmware policy; see docs/native-ab-capacities.md) |
| snow | 1 GiB | 8 GiB (measured 2026-07-14 against the real `snow-ab` production build; runtime-confirmed 2026-07-15 across the full N..N+3 secure update window, Phase 5 exit — see docs/native-ab-capacities.md) |
| snowfield | 1 GiB | 8 GiB (measured 2026-07-14 against the real `snowfield-ab` production build; see docs/native-ab-capacities.md) |

1 GiB ESP applies to all three products from the first installable layout —
this is deliberately conservative because an undersized ESP cannot be
repaired in place after installation.

**Headroom definition (authoritative):** root-slot headroom is
`(slot size - measured content size) / slot size` — spare capacity as a
fraction of the TOTAL slot, not of the measured content. Do not compute it
as spare/used; that formula overstates the safety margin (a slot that is
80% full by this definition looks like "25% headroom" under spare/used,
when only 20% of the slot is actually free). Publication requires at least
20% root-slot headroom by this spare/total-slot definition, and every
artifact within its fixed partition/ESP budget. Capacity numbers live in
per-product channel fragments (`shared/native-ab/channels/<product>/`), not
in the generic outformat. See docs/native-ab-capacities.md's Method section
for the full sizing procedure, including the verity:root ratio rule.

## 13. Retention

- Keep current + previous 2 stable versions per product.
- Withdrawn versions: retained 90 days.
- Full installer disk images: retained for **less** time than root update
  objects.
- Lifecycle deletion only after rollback and offline-install windows have
  passed.

## 14. bootc support overlap

bootc publication continues unchanged. No retirement decision before the
plan's Phase 11 review, and never less than 12 months after the first stable
native promotion.

## 15. Static publication guard

A native profile literally named `cayo-ab`, `snow-ab`, or `snowfield-ab` is
publishable only if its `mkosi.conf` (or an `[Include]`d fragment it always
pulls in) satisfies, at minimum:

- `ShimBootloader=signed`
- `SecureBoot=yes`
- `SignExpectedPcr=yes`
- The update pubring is in-tree (§7).
- NvPCR disable finalize is wired (`shared/native-ab-secure/finalize/disable-nvpcr.chroot`).
- Native updater isolation: bootc and nbc timers masked (§ Native Runtime
  Isolation in the plan).
- The secure `/var` mount contract (§10, secure row).
- No final-root `KernelModules=` filter (§9).

`test/native-ab-contracts-test.sh` checks the config markers subset of this
list statically (`SecureBoot=yes`, `ShimBootloader=signed`,
`SignExpectedPcr=yes` present directly in the profile's own `mkosi.conf`).
The remaining criteria are validated by the other `test/native-ab-secure-*`
harnesses and by boot tests; this document freezes them as gate criteria so
later phases can add the missing static checks without re-litigating what
"publishable" means.
