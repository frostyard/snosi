# Native A/B Capacity Measurements (Phase 3 / Task 3.2)

This document records the measurements behind the per-product channel
partition sizes in `shared/native-ab/channels/<product>/mkosi.repart/`. It
is the AI-facing companion to `docs/native-ab-contracts.md` §12 (which
freezes the *policy*: 1 GiB ESP for every product, >=20% root-slot headroom
at publication, capacity numbers live in channel fragments not the generic
outformat). As of Task 3.2, all three products (cayo, snow, snowfield) are
measured against real production native builds (`cayo-ab`, `snow-ab`,
`snowfield-ab`) and marked "validated" below — none remain provisional.
Re-measure if a future package-set or module-policy change materially
changes any product's payload size.

## Method

- **Headroom definition (authoritative, docs/native-ab-contracts.md §12):**
  `headroom = (slot size - measured content size) / slot size` — spare
  capacity as a fraction of the TOTAL slot size, always divided by the SLOT
  size, never by the measured content size. `spare / used` (measured
  content) is NOT the definition and overstates the margin: e.g. cayo's old
  4 GiB slot against 4092997632 B measured content is `spare/used =
  201969664/4092997632 = ~4.9%` either way at that gap size, but at larger
  fill fractions the two formulas diverge sharply (a slot at 80% of capacity
  by the spare/total definition reads as "25% headroom" under spare/used,
  while only 20% of the slot is actually free). Every headroom percentage in
  this document, and in the channel repart comments, is spare/total-slot.
- **Root/verity slot sizing:** `mkfs.erofs` (no compression flag, matching
  systemd-repart's default `Format=erofs` behavior — confirmed via
  `dump.erofs` on a real repart-built partition: no `compr_cfgs` feature
  flag, block count matches uncompressed content size) against the
  product's build output directory, `--exclude-regex` stripping `/var`
  (which ships as its own partition, `ExcludeFilesTarget=/var/` in
  `11-root.conf`). Root slot is chosen as the smallest whole-GiB size for
  which `(slot - measured) / slot >= 0.20` (>=20% headroom by the
  spare/total-slot definition, §12).
- **Verity:root ratio rule:** the verity slot is sized at 1/32 of the root
  slot (in MiB), rounded UP to the next power-of-two MiB value. This
  reproduces every validated/provisional value in this document exactly:
  cayo's original 4 GiB root gives `4096/32 = 128 MiB`, already a power of
  two, hence its historical 128 MiB verity slot; snow/snowfield's 7 GiB root
  gave `7168/32 = 224 MiB`, rounded up to 256 MiB, matching their historical
  verity slot. Applied to the Phase 3 bumped sizes: cayo's new 5 GiB root
  gives `5120/32 = 160 MiB`, rounded up to **256 MiB** (a real bump, since
  160 sits strictly between the 128 and 256 powers of two); snow/snowfield's
  new 8 GiB root gives `8192/32 = 256 MiB`, already a power of two, so their
  verity slot is unchanged at 256 MiB.
- **UKI/ESP sizing:** `ls -la` on the built `.efi` split artifact compared
  against the channel's 1 GiB ESP budget. Phase 3's module-policy change
  (docs/native-ab-contracts.md §9: no final-root `KernelModules=` filter in
  release channels) was checked against a 40% ESP threshold — the point at
  which the generic tree's dracut config would need `omit_drivers=`/
  `drivers=` constraints.

## cayo (validated, 2026-07-14, real `cayo-ab` production build)

Measured on a real `mkosi --profile cayo-ab build` (Task 3.2) — the actual
production profile (`mkosi.profiles/cayo-ab/mkosi.conf`), not the retired
`cayo-ab-secure` spike it replaces. Full production module set (no
`KernelModules=` filter anywhere in its Include chain), the frozen channel
structure, and the committed update pubring
(`/usr/lib/systemd/import-pubring.gpg`, confirmed present via
`dump.erofs --cat`, sha256 matches the committed
`shared/native-ab/keys/import-pubring.gpg` byte-for-byte).
`test/native-ab-secure-artifact-test.sh` passed against this exact build
(systemd 261.1-2).

| Artifact | Measured | Budget | Headroom (spare/total-slot) |
|---|---|---|---|
| Root (EROFS, erofs blocks, `dump.erofs -s`) | 999364 blocks * 4096 = 4093394944 B (~3.81 GiB) | 5 GiB (5368709120 B) | (5368709120 - 4093394944) / 5368709120 = 1275314176 / 5368709120 = ~23.8% |
| Verity | 268435456 B (256 MiB, exact partition size) | 256 MiB | n/a (fixed by the ratio rule; partition ships at its full budget) |
| UKI (`cayo-ab.efi`) | 120397648 B (~114.8 MiB) | ESP 1 GiB | UKI is ~11.2% of ESP (well under the 40% dracut-constraint threshold) |
| ESP (ESP partition itself) | 1073741824 B (1 GiB, exact) | 1 GiB | n/a (fixed) |

**Validated, no change needed:** this real production measurement
(999364 blocks, from the final build including the `SkeletonTrees=` fix
below) is essentially identical to the prior `cayo-ab-secure` spike
measurement that drove the Phase 3 slot bump (999267 blocks) and an
intermediate `cayo-ab` build without the fix (999302 blocks) — the
few-hundred-block deltas are profile-identity/manifest metadata, not
payload — confirming the 5 GiB root / 256 MiB verity sizing already in
`shared/native-ab/channels/cayo/mkosi.repart/{11-root,21-root-empty,
10-root-verity,20-root-verity-empty}.conf` and `docs/native-ab-contracts.md`
§12 remains correct for the real `cayo-ab` production profile. No repart
changes were needed this task; this section replaces the prior
`cayo-ab-secure`-sourced numbers with the real `cayo-ab` ones for the
record.

**Real artifact problem found and fixed (Task 3.2):** the first `snowfield-ab`
build failed outright — `dracut[E]: Module 'bootc' cannot be found`,
triggered synchronously by the linux-surface kernel package's own postinst
hook (`run-parts: /etc/kernel/postinst.d/dracut exited with return code 1`)
during package installation, before `ExtraTrees=` composition has run.
Debian's own `linux-image-amd64` (used by `cayo-ab`/`snow-ab`) defers its
equivalent hook via a dpkg trigger and never hit this in either cayo-ab
build; the surface kernel's postinst runs the hook immediately instead. At
that point the base image's `usr/lib/dracut/dracut.conf.d/
30-bootc-standard.conf` (which requests the `bootc` dracut module) is still
in effect for every native profile — its `ExtraTrees=`-based shadow, which
requests `lvm crypt etc-overlay` instead, only lands after packages are
installed. Fixed generally (not surface-specific) in
`shared/outformat/ab-root/mkosi.conf`: the SAME canonical shadow file is now
also pulled in via `SkeletonTrees=` (copied into the OS tree BEFORE the
package manager runs, per mkosi's `install_skeleton_trees()` ->
`install_distribution()` -> `install_extra_trees()` build order), so the
`bootc` module request is neutralized from the very start of the buildroot
regardless of which kernel package's postinst happens to run synchronously.
Reconfirmed harmless for `cayo-ab`: rebuilding it with the fix in place
produced the 999364-block measurement above (vs. 999302 without the fix) —
a negligible, metadata-level difference, not a functional regression.

## snow (validated, 2026-07-14, real `snow-ab` production build)

Measured on a real `mkosi --profile snow-ab build` (Task 3.2). Full
production module set, frozen channel structure, committed update pubring
confirmed present (sha256 match). `test/native-ab-secure-artifact-test.sh`
passed (`OUTPUT_NAME=snow-ab`, systemd 261.1-2).

| Artifact | Measured | Budget | Headroom (spare/total-slot) |
|---|---|---|---|
| Root (EROFS, erofs blocks) | 1387959 blocks * 4096 = 5685080064 B (~5.29 GiB) | 8 GiB (8589934592 B) | (8589934592 - 5685080064) / 8589934592 = 2904854528 / 8589934592 = ~33.8% |
| Verity | 268435456 B (256 MiB, exact partition size) | 256 MiB | n/a (fixed by the ratio rule) |
| UKI (`snow-ab.efi`) | 270077776 B (~257.6 MiB) | ESP 1 GiB | UKI is ~25.2% of ESP (under the 40% dracut-constraint threshold) |
| ESP | 1073741824 B (1 GiB, exact) | 1 GiB | n/a (fixed) |

**Validated, no change needed:** the prior PROVISIONAL estimate (sized from
a bootc `snow` directory build, ~5.63 GiB, ~29.6% headroom against 8 GiB)
was a conservative OVER-estimate as predicted — it included `bootc`,
`libostree`, and GRUB tooling that native profiles never install. The real
native `snow-ab` measurement (~5.29 GiB) is smaller still, giving MORE
headroom (~33.8%) than the provisional estimate implied. The 8 GiB root /
256 MiB verity sizing already in `shared/native-ab/channels/snow/mkosi.repart/`
is confirmed correct; no repart change was needed.

**Runtime-confirmed, 2026-07-15 (Phase 5, `test/native-ab-secure-boot-test.sh`):**
the 8 GiB root / 256 MiB verity slots were re-confirmed against real N/N+1
`snow-ab` production builds under an actual install + boot cycle (not just a
build-time measurement) — Secure Boot enforced, swtpm-backed TPM enrollment,
a full GNOME desktop session (`graphical.target`, `gdm.service`), and a real
signed N→N+1 update hop all completed successfully within the current slot
sizes, 56/56 assertions passed. No capacity change needed.

## snowfield (validated, 2026-07-14, real `snowfield-ab` production build)

Measured on a real `mkosi --profile snowfield-ab build` (Task 3.2), the
Surface-kernel channel — the first build to actually exercise
`linux-image-surface` under this fragment structure, and the build that
surfaced the real `dracut[E]: Module 'bootc' cannot be found` artifact
problem described above (now fixed). Full production module set, frozen
channel structure, committed update pubring confirmed present (sha256
match). `test/native-ab-secure-artifact-test.sh` passed
(`OUTPUT_NAME=snowfield-ab`, systemd 261.1-2).

| Artifact | Measured | Budget | Headroom (spare/total-slot) |
|---|---|---|---|
| Root (EROFS, erofs blocks) | 1479257 blocks * 4096 = 6059036672 B (~5.64 GiB) | 8 GiB (8589934592 B) | (8589934592 - 6059036672) / 8589934592 = 2530897920 / 8589934592 = ~29.5% |
| Verity | 268435456 B (256 MiB, exact partition size) | 256 MiB | n/a (fixed by the ratio rule) |
| UKI (`snowfield-ab.efi`) | 254607696 B (~242.8 MiB) | ESP 1 GiB | UKI is ~23.7% of ESP (under the 40% dracut-constraint threshold) |
| ESP | 1073741824 B (1 GiB, exact) | 1 GiB | n/a (fixed) |

**Validated, no change needed:** the Surface kernel's larger driver/firmware
set (`linux-image-surface`, `linux-headers-surface`, `libwacom-surface`,
`iptsd`) makes snowfield's root content ~374 MiB larger than snow's, but the
8 GiB slot still clears the 20% headroom requirement comfortably (~29.5%).
No repart change was needed. This measurement independently confirms the
Phase 3 module-policy sizing decision below (UKI far under the 40% ESP
threshold) held for the Surface kernel too, as flagged as a re-check item
at the time.

## Module-policy / dracut sizing decision (Phase 3)

The brief required checking whether removing the `KernelModules=` filter
(docs/native-ab-contracts.md §9) would bloat the dracut `--no-hostonly`
initrd enough to need `omit_drivers=`/`drivers=` constraints in the generic
tree's dracut configuration, targeting <=40% of the 1 GiB ESP for the UKI.

Measured result: cayo-ab-secure's UKI (full module set, no filter) is
~114.8 MiB, only marginally larger than cayo-ab-raw's UKI (virtio-only
filter) at ~114.06 MiB (the `esp.raw` split diff of the two full ESPs was
negligible). Both are far under the 40% (~410 MiB) threshold. **No dracut
driver-list constraint was added** — dracut's own non-hostonly module
selection logic already keeps the initrd bounded regardless of how many
kernel modules exist on disk under `/usr/lib/modules`; the size growth from
removing the mkosi-level `KernelModules=` filter lands almost entirely in
the final-root `/usr/lib/modules`+`/usr/lib/firmware` tree (see the cayo
headroom fix above), not in the dracut-generated initrd/UKI.

**Re-checked with real snow-ab/snowfield-ab builds (Task 3.2):** confirmed
for both the backports kernel (`snow-ab.efi`, ~257.6 MiB, ~25.2% of ESP) and
the Surface kernel (`snowfield-ab.efi`, ~242.8 MiB, ~23.7% of ESP) — both
comfortably under the 40% threshold despite snow/snowfield's much larger
package set (desktop + Surface-specific drivers) than cayo's headless
server payload. No dracut driver-list constraint is needed for any of the
three production profiles.
