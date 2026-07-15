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

## cayo (validated, 2026-07-14)

Measured on `cayo-ab-secure` — the only build with BOTH the full production
module set (no `KernelModules=` filter anywhere in its Include chain) AND
the frozen channel structure from this task (rebuilt after the channel
`ExtraTrees=` wiring fix, so the measured image ships the sysupdate.d
transfers; `native-ab-secure-artifact-test.sh` passed against this exact
build).

| Artifact | Measured | Budget | Headroom (spare/total-slot) |
|---|---|---|---|
| Root (EROFS, erofs blocks) | 999267 blocks * 4096 = 4092997632 B (~3.81 GiB) | 5 GiB (5368709120 B) | (5368709120 - 4092997632) / 5368709120 = 1275711488 / 5368709120 = ~23.8% |
| Verity | 1/32 of 5 GiB slot = 160 MiB, rounded up to next power-of-two MiB | 256 MiB | n/a (not independently re-measured; sized by the ratio rule) |
| UKI (`cayo-ab-secure.efi`) | 120397648 B (~114.8 MiB) | ESP 1 GiB | UKI is ~11.2% of ESP (well under the 40% dracut-constraint threshold) |
| ESP (ESP partition itself) | 1073741824 B (1 GiB, exact) | 1 GiB | n/a (fixed) |

**Fixed by this task (phase 3, follow-up):** cayo's root slot was frozen in
`docs/native-ab-contracts.md` §12 as "4 GiB (validated)" from a measurement
made against the OLD virtio-only `KernelModules=` filter (~2.77 GiB used,
comfortable headroom). With Phase 3's module-policy change (no filter in
production channels), the SAME cayo payload measures ~3.81 GiB against that
4 GiB slot — `(4294967296 - 4092997632) / 4294967296 = ~4.7%` headroom under
the spare/total-slot definition (§12), below the required 20%. Root-caused
via a mounted-erofs comparison: `/usr/lib/firmware` grew from 21 MiB
(virtio-filtered) to 1019 MiB (full set); `/usr/lib/modules` grew from
106 MiB to 264 MiB. That ~1.1 GiB delta is the entire gap. This measurement
comes from `cayo-ab-secure` (Forky systemd 261 spike, not the eventual
production `cayo-ab`), so it is not a clean production number, but the
growth is attributable to firmware/modules, not the Forky package set (the
delta matches the mounted-filesystem `du` breakdown almost exactly).
**Resolution:** the root slot is bumped to 5 GiB (`shared/native-ab/channels/
cayo/mkosi.repart/11-root.conf` and its paired `_empty` slot,
`21-root-empty.conf`), giving ~23.8% headroom against the SAME 4092997632 B
measured content — see the table above. The verity slot is bumped in step
with the ratio rule (see Method) from 128 MiB to 256 MiB
(`10-root-verity.conf` / `20-root-verity-empty.conf`). `docs/native-ab-
contracts.md` §12's cayo row is updated to "5 GiB (measured 2026-07-14, full
module/firmware policy; see docs/native-ab-capacities.md)" — no longer
carrying the stale "validated" 4 GiB figure. This remains a
`cayo-ab-secure` (Forky) measurement, not a clean production `cayo-ab`
number; re-measure when the real production profile exists.

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

- Root slot: under the spare/total-slot headroom definition (§12,
  `docs/native-ab-contracts.md`), a 7 GiB slot gives
  `(7516192768 - 6047731712) / 7516192768 = 1468461056 / 7516192768 =
  ~19.5%` headroom — BELOW the required 20%. (The old spare/used
  arithmetic, `1468461056 / 6047731712 = ~24.3%`, made 7 GiB look
  sufficient; it was not, under the authoritative definition.) Bumped to
  **8 GiB**: `(8589934592 - 6047731712) / 8589934592 = 2542202880 /
  8589934592 = ~29.6%` headroom.
- Verity slot: ratio rule (1/32 of slot, rounded up to next power-of-two
  MiB) against 8 GiB = 8192 MiB: `8192/32 = 256 MiB`, already a power of
  two — unchanged from the prior 7 GiB-derived value.
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
headroom fix above), not in the dracut-generated initrd/UKI. This
should be re-checked if snow/snowfield's kernels (backports, Surface) pull
in meaningfully different driver sets once a real native profile builds
their UKI.
