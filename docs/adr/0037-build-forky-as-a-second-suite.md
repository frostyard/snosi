# 0037 — Build forky as a second suite beside trixie

- **Status:** Accepted
- **Date:** 2026-11-13

## Context

The repository builds four bootc OCI products and a set of sysexts from Debian
Trixie, and Trixie is what every published image ships. Debian's next release,
Forky, is in testing now. Its systemd family already supplies the secure bootc
images, from one isolated, low-priority APT source, but the images themselves
are Trixie packages.

A single-suite move was planned once ([frostyard/snosi#924](https://github.com/frostyard/snosi/pull/924),
an ADR draft by bketelsen): repoint the whole repository at Forky at once. That
design has one property this repository cannot accept while Forky is testing:
it makes every trixie image build depend on the suite under test. A Forky
regression would then stop shipping Trixie, and a Trixie-only package would
have to be deleted rather than moved aside.

Trixie stays the default and does not change. Forky is built beside it, so that
the pipeline already builds, installs and updates Forky on the day Debian
releases it, on a tree whose wiring has been exercised all along. Forky images
are not published by this decision.

## Decision

The Debian release is a build input. `mkosi --release forky --profile floe ...`
overrides `Release=` (`[Distribution]`, currently `trixie`) for every image of
the invocation; without the flag, every build resolves exactly as before.

Suite-specific content lives in files whose `[Match]` section names one release,
because mkosi cannot remove a list item that a shared file added. Each matched
file starts with `[Match]` and holds exactly one match, `Release=trixie` or
`Release=forky`; the other file of the pair contributes nothing.

- `shared/suite/forky/mkosi.conf`, included from the root `mkosi.conf`, adds
  `SandboxTrees=%D/shared/suite/forky/sandbox`. mkosi puts `mkosi.sandbox`
  first, and a later sandbox tree overwrites the files of an earlier one, so the
  forky sandbox replaces the trixie APT source, backports source and backports
  pin. Docker's source stays on trixie: `download.docker.com` has no forky
  suite.
- `mkosi.images/base/mkosi.conf.d/trixie.conf` holds
  `Packages=low-memory-monitor`, which Debian forky does not ship.
  `mkosi.images/base/mkosi.conf.d/forky.conf` adds the forky backports pin as an
  `ExtraTrees=` after `mkosi.images/base/mkosi.extra`, and runs
  `shared/suite/forky/version-id.postinst.chroot`.
- `shared/kernel/backports/` splits into `trixie.conf` (the
  `trixie-backports` pins and trixie's forky kernel) and `forky.conf` (the same
  packages from forky itself, without a suite suffix), with the suite-neutral
  firmware left in `mkosi.conf`.
- `shared/suite/forky/floe.conf`, included last by
  `shared/composition/floe/mkosi.conf`, overrides Floe's own backports source
  and pin.
- `shared/suite/forky/base-tree` and `floe-tree` also carry forky copies of
  `usr/lib/dracut/dracut.conf.d/20-tpm-luks.conf`. dracut 112 on forky renamed
  the module `systemd-pcrphase` to `systemd-pcrextend`, and an unknown module
  name fails the kernel postinst; dracut 106 on trixie knows only the old name.
  `test/tss-user-initrd-static-test.sh` requires each forky copy to equal its
  trixie copy with that one name changed.
- `shared/packages/bootc/` splits the same way. `trixie.conf` holds the trixie
  bootc/libostree pair and `libgpgme11t64`. `forky.conf` holds the forky pair
  (`bootc=1.17.4-frostyard202611132023~deb14`,
  `libostree-1-1=2026.6-frostyard202611132023~deb14`) and `libgpgme45`, the
  forky name of that library.
- `shared/bootc-secure/` splits too. `trixie.conf` holds the isolation pin
  `SandboxTrees=%D/shared/bootc-secure/package-manager` (a low-priority forky
  source and an `n=forky` pin at 50). A forky build does not read it: the forky
  sandbox already gives the forky source. `forky.conf` adds
  `shared/bootc-secure/suite/forky/tree` after `shared/bootc-secure/tree`. Its
  `bootc-secure.json` is the trixie contract with the forky bootc version in
  `assembly.bootc_version`, `assembly.compatibility` and
  `installer.minimum_versions.bootc`, so `bootc-pair.chroot` checks the forky
  pair against it. Host-side secure assembly still reads the trixie contract;
  forky secure assembly is a later change.

Debian testing's `base-files` ships no `VERSION_ID`. The forky post-installation
script writes `VERSION_ID="14"` and `VERSION="14 (forky)"` when the codename is
`forky`, fails on any other codename, and does nothing once the Debian release
provides the value. Three consumers key off it: the sysext output filename
(`_14_`), the `%w` specifier of a sysupdate `MatchPattern`, and each sysext's
`extension-release` `VERSION_ID`. Without the script, the shared post-install
fallback `VERSION_ID="1.0"` would apply.

Two guards keep the pair honest. `test/suite-isolation-test.sh` requires the
resolved trixie summary of every profile and of the default build to be
identical to a copy of the tree in which every forky-matched fragment is cut
down to its `[Match]` section, and requires the forky Floe summary to carry the
forky sandbox and extra trees in last position. It also checks the `[Match]`
shape of every matched fragment.

`.github/workflows/forky-mechanics.yml` builds the forky Floe composition with
no publication, no registry login and `contents: read` only: on a pull request
that changes any image input (it ignores only what `build-images.yml` ignores,
`test/workflow-path-filter-test.sh`), on dispatch, and nightly. A forky build may stop at
a gap that Debian testing has not closed yet. The build step is
`continue-on-error`, and `shared/suite/forky/classify-build.sh` reads the
`known-gaps.tsv` rows (exactly 3 nonempty tab-separated fields: id, fixed
string, https tracking URL; a malformed row fails every run): a failed build passes
only when it has at least one apt error line and a row explains every one of
them, so a known gap cannot hide a new one; a failure without an apt error is
never a gap. A passing build fails while any row is still listed, so the file
cannot go stale.

## Consequences

- A suite-specific package or tree moves out of the shared list and into the
  matched file of its suite. A shared file may hold only suite-neutral content.
- The trixie resolution gains one entry in mkosi's list of read configuration
  files per matched fragment, and no setting changes.
- `shared/scripts/common-postinst.sh` keeps its `VERSION_ID="1.0"` fallback; on
  forky it no longer applies because the forky script runs first.
- The isolation pin `shared/bootc-secure/package-manager` applies to trixie
  builds only. Forky builds do not read it, so its `n=forky` pin at priority 50
  does not apply to the forky archive.
- Each suite pins its own bootc/libostree pair and has its own copy of the
  secure assembly contract. `test/bootc-secure-static-test.sh` requires the
  forky contract to equal the trixie contract except the three bootc version
  fields, and each pin to agree with the contract of its suite.
- Not in this decision, and each needs its own: per-suite sysexts, publication
  of forky images, and a user-visible way to choose the suite.
- A known gap in `known-gaps.tsv` is a temporary record with a tracking URL; it
  is a build-availability note, never a support claim.

## Alternatives considered

- **Repoint the repository at Forky (the #924 single-suite move):** ties every
  published image to the suite under test, and a Trixie-only package then has to
  be deleted instead of moved aside.
- **Keep forks of the tree per suite:** two copies of every fragment drift
  apart, and a fix must be made twice.
- **A `--release` value per profile directory:** profile fragments already
  compose packages; the release is an input of the invocation, not a product.
- **Build forky only after Debian releases it:** the wiring, the package
  differences and the version handling would all be written against an
  unreleased tree with no build signal.

## References

- Replaces: the single-suite move drafted in
  [frostyard/snosi#924](https://github.com/frostyard/snosi/pull/924) (bketelsen).
- Builds on: [core plan 0009 — Debian publication through apt-publisher, phase 6](https://github.com/frostyard/core/blob/main/docs/plans/0009-debian-publication-through-apt-publisher.md),
  [ADR-0020](0020-scope-third-party-apt-sources.md) for a scoped sandbox tree,
  [sysexts](../design/sysexts.md) for the consumers of `VERSION_ID`.
- Enforced by: `test/suite-isolation-test.sh`,
  `test/forky-known-gaps-test.sh`, `test/third-party-apt-source-scope-test.sh`,
  `test/frostyard-apt-image-component-test.sh`, `check-duplicate-packages.sh`.
- Shapes: [CI/CD](../design/ci-cd.md), [testing](../design/testing.md),
  [sysexts](../design/sysexts.md).
