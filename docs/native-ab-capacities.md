# Native A/B Capacity Measurements (Phase 3)

This document records the measurements behind the per-product channel
partition sizes in `shared/native-ab/channels/<product>/mkosi.repart/`. It
is the AI-facing companion to `docs/native-ab-contracts.md` §12 (which
freezes the *policy*: 1 GiB ESP for every product, >=20% root-slot headroom
at publication, capacity numbers live in channel fragments not the generic
outformat). Phases 5/6 extend this document as snow/snowfield gain real
native-profile builds and cayo gets re-measured under the full production
module set; do not treat any number here as final except where marked
"validated".

## Method

- **Root/verity slot sizing:** `mkfs.erofs` (no compression flag, matching
  systemd-repart's default `Format=erofs` behavior — confirmed via
  `dump.erofs` on a real repart-built partition: no `compr_cfgs` feature
  flag, block count matches uncompressed content size) against the
  product's build output directory, `--exclude-regex` stripping `/var`
  (which ships as its own partition, `ExcludeFilesTarget=/var/` in
  `11-root.conf`). Root slot = measured size * 1.2, rounded up to a whole
  GiB (>=20% headroom, §12). Verity slot scaled from cayo's measured
  verity:root ratio (128M:4G = 1/32) against the new root slot size, rounded
  up.
- **UKI/ESP sizing:** `ls -la` on the built `.efi` split artifact compared
  against the channel's 1 GiB ESP budget. Phase 3's module-policy change
  (docs/native-ab-contracts.md §9: no final-root `KernelModules=` filter in
  release channels) was checked against a 40% ESP threshold — the point at
  which the generic tree's dracut config would need `omit_drivers=`/
  `drivers=` constraints.

## cayo (validated, 2026-07-14)

Measured on `cayo-ab-secure` — the only build with BOTH the full production
module set (no `KernelModules=` filter anywhere in its Include chain) AND
the frozen channel structure from this task (rebuilt after the channel
`ExtraTrees=` wiring fix, so the measured image ships the sysupdate.d
transfers; `native-ab-secure-artifact-test.sh` passed against this exact
build).

| Artifact | Measured | Budget | Headroom |
|---|---|---|---|
| Root (EROFS, erofs blocks) | 999267 blocks * 4096 = 4092997632 B (~3.81 GiB) | 4 GiB (4294967296 B) | ~4.9% |
| Verity | (unchanged, 128 MiB budget; not independently re-measured) | 128 MiB | n/a |
| UKI (`cayo-ab-secure.efi`) | 120397648 B (~114.8 MiB) | ESP 1 GiB | UKI is ~11.2% of ESP (well under the 40% dracut-constraint threshold) |
| ESP (ESP partition itself) | 1073741824 B (1 GiB, exact) | 1 GiB | n/a (fixed) |

**Concern, not fixed by this task:** cayo's 4 GiB root slot is frozen in
`docs/native-ab-contracts.md` §12 as "4 GiB (validated)" from a measurement
made against the OLD virtio-only `KernelModules=` filter (~2.77 GiB used,
comfortable headroom). With Phase 3's module-policy change (no filter in
production channels), the SAME cayo payload now measures ~3.81 GiB —
**under 5% headroom, below the §12-required 20%.** Root-caused via a
mounted-erofs comparison: `/usr/lib/firmware` grew from 21 MiB
(virtio-filtered) to 1019 MiB (full set); `/usr/lib/modules` grew from
106 MiB to 264 MiB. That ~1.1 GiB delta is the entire gap. This measurement
comes from `cayo-ab-secure` (Forky systemd 261 spike, not the eventual
production `cayo-ab`), so it is not a clean production number, but the
growth is attributable to firmware/modules, not the Forky package set (the
delta matches the mounted-filesystem `du` breakdown almost exactly). cayo's
root slot needs re-validation, likely a bump to 5 GiB, before any real
`cayo-ab` production profile ships. Out of scope for this task (§12 marks
cayo's slot "validated", not provisional; only snow/snowfield were opened
for revision here) — flagged for the phase that creates the real
production `cayo-ab` profile.

## snow / snowfield (PROVISIONAL, 2026-07-14)

No native profile consumes the `snow`/`snowfield` channels yet (that lands
in Task 3.2), so there is no real native build to measure. Per the Phase 3
brief, sized from `mkfs.erofs` of the existing **bootc** `snow` directory
build (`output/snow`, built via `mkosi --profile snow build`,
IMAGE_VERSION 20260714205112), `/var` excluded:

```
Filesystem total blocks: 1476497 (of 4096-byte blocks)
= 6047731712 bytes (~5.63 GiB)
```

- Root slot: 6047731712 B * 1.2 = ~6.76 GiB, rounded up to **7 GiB**
  (headroom against 7 GiB = ~24.3%).
- Verity slot: cayo's ratio (1/32) * 7168 MiB = 224 MiB, rounded up to
  **256 MiB**.
- Reused verbatim for `snowfield` (no Surface-kernel-specific measurement
  taken; the brief explicitly allows reusing the snow measurement for
  both channels at this phase).

This measurement is a conservative OVER-estimate for the eventual
`snow-ab`/`snowfield-ab` native payload: the bootc `snow` build includes
`bootc`, `libostree`, GRUB tooling, and other transport-specific packages
that native profiles never install (`shared/packages/bootc/mkosi.conf` is
never `Include=`d by a native profile). It has NOT been checked against a
real snow/snowfield UKI or ESP budget, since no native profile builds a
snow/snowfield UKI yet. Finalized in Phase 5 (snow) / Phase 6 (snowfield)
from measurements of the actual native profile once it exists.

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
headroom concern above), not in the dracut-generated initrd/UKI. This
should be re-checked if snow/snowfield's kernels (backports, Surface) pull
in meaningfully different driver sets once a real native profile builds
their UKI.
