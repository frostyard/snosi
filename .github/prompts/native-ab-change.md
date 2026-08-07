# Prompt: change the native A/B path

Goal: `<the native A/B behavior to add or fix>`

Read first: `docs/native-ab-contracts.md` (the frozen source of truth for
naming, paths, and policy), `docs/native-ab-capacities.md`,
`docs/native-ab-publication.md`, and the "Native A/B" sections of `CLAUDE.md`.

Rules that are easy to break here:

- Product-neutral disk/boot mechanics live in `shared/outformat/ab-root/`.
  Per-product repart definitions, sysupdate transfers, and channel settings
  live in `shared/native-ab/channels/<product>/`. Never move one into the other.
- `mkosi` accumulates list settings (`Packages=`, `FinalizeScripts=`, …) in
  `Include=` encounter order across the whole resolved config. The arbiter for
  any composition refactor is a byte-level diff of `mkosi --profile <p> summary`
  before and after, normalizing `Seed:`, `Prepare Scripts:` tmpdirs, and
  `Image Version:`. Delete `.mkosi-private/history/latest.json` first, or the
  cached profile silently overrides `--profile`.
- `cayo-ab-raw` is a permanent, never-published dev fixture. The published
  products are `cayo-ab`, `snow-ab`, and `snowfield-ab`, and they must keep
  passing `check-native-publication-guard.sh`.
- Enablement belongs in presets or static `/usr` wants links, never in shipped
  `/etc` symlinks or runtime `systemctl enable`/`disable`.
- The PCR signing key must be RSA-2048; the MOK key stays RSA-4096.

Validate, cheapest first:

```bash
test/native-ab-static-test.sh
test/native-ab-contracts-test.sh
check-native-publication-guard.sh
```

then, only if the change warrants it and the machine has root plus KVM, the
matching QEMU harness (`test/native-ab-update-test.sh`,
`test/native-ab-components-test.sh`, `test/native-ab-secure-boot-test.sh`,
`test/native-installer-e2e-test.sh`).

Finish by recording contract or capacity changes in `docs/native-ab-contracts.md`
/ `docs/native-ab-capacities.md` and summarizing them in `CLAUDE.md`.
