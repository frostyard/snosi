# Native A/B Production Deployment Checklist

**Purpose:** the exact, ordered steps required to take the native A/B deployment
path from "code-complete on `feat/mkosi-ab-root`" to "safe for real users."
Nothing here is optional hand-waving — every box is a concrete action with the
command, file, or approval it requires.

**Source of truth for detail:** this checklist is the index. The full procedures
live in [`docs/native-ab-publication.md`](../native-ab-publication.md) (publication
runbook, key ceremony, secret inventory, Cloudflare rules) and
[`docs/native-ab-contracts.md`](../native-ab-contracts.md) (frozen names/paths).
Where a step says "see runbook §X," that document has the copy-paste commands.

**Status legend:** `[ ]` not started · `[~]` in progress · `[x]` done.
Do the sections **in order** — later sections assume earlier gates passed.

---

## 0. Preconditions (already complete — verify, don't redo)

- [x] All eight phases implemented, reviewed, and committed on
      `feat/mkosi-ab-root` (40 commits; HEAD at the branch tip). Whole-branch
      review returned ready-to-merge, no Critical findings.
- [x] Full static suite green on a fresh checkout (no `.snosi-private`, no
      `mkosi.key`): `native-ab-contracts-test.sh`, `native-ab-static-test.sh`,
      `native-publish-test.sh`, `native-publication-pipeline-test.sh`,
      `snosi-install-test.sh`, `snosi-etc-diff-test.sh`,
      `check-native-publication-guard.sh`, `check-runtime-etc-guard.sh`.
- [x] QEMU proofs green: `snow-ab --full-window` 125/125 (Phase 5 exit);
      installer e2e 75/75 for `cayo-ab`+`snow-ab` (Phase 8 exit).

**Verify before proceeding:**

```bash
cd /path/to/snosi
git worktree add /tmp/snosi-fresh HEAD && cd /tmp/snosi-fresh   # no local secrets
for t in native-ab-contracts native-ab-static native-publish \
         native-publication-pipeline snosi-install snosi-etc-diff; do
  bash "test/$t-test.sh" || echo "FAIL $t"
done
bash check-native-publication-guard.sh && bash check-runtime-etc-guard.sh
cd - && git worktree remove /tmp/snosi-fresh
```

---

## 1. Merge gate — external dependency (BLOCKING)

The base image ships every sysext's sysupdate definition under a per-component
directory (`/usr/lib/sysupdate.<name>.d/`). An older `frostyard-updex` cannot
discover component-scoped sysexts, so merging before updex ships **silently
stops sysext updates on every installed machine**.

- [x] Release `frostyard-updex` **with component discovery** to the Frostyard APT
      repository. Done: `frostyard-updex` **1.3.0** (commit `5ddb2ce`, 2026-07-15)
      is published and installed on the latest cayo.
- [x] Confirm the released `frostyard-updex` includes component support:
      `updex components` runs (subcommand present) and `updex features list` still
      enumerates the current sysexts from the legacy layout (backward compatible).
      Note: `updex components` reports **0** until the per-component migration ships
      in a built image — a post-merge cayo rebuild is where it first lists the
      components; do **not** expect it to enumerate 17 pre-merge. Validated on
      selfie (10.0.1.200) 2026-07-16: subcommand works, discovers a per-component
      dir when present, `features list` reads the legacy 17.
- [ ] Only then merge `feat/mkosi-ab-root`. (See CLAUDE.md "Sysupdate Target And
      Component Topology" and the allowlist comment for the rationale.)

---

## 2. Merge gate — bootc-parity sign-off (BLOCKING)

The prime directive is that bootc builds are unchanged. Two deliberate build-time
deltas need explicit human acknowledgement, and two low-risk items need a real CI
build to confirm.

- [x] **Acknowledge `var-audit.finalize` on bootc.** `shared/composition/{cayo,snow}`
      add a `/var` inventory audit to the bootc profiles. Effect: bootc images now
      ship an inert `/usr/share/snosi/var-inventory.txt`, and a bootc build now
      **fails** on any unclassified `/var` path or stale outcome-map glob. Runtime
      behavior is unchanged. Sign off that this guardrail is acceptable.
- [x] **Acknowledge bootc package relocation.** The bootc/ostree package block
      moved from `mkosi.images/base/mkosi.conf` to `shared/packages/bootc/mkosi.conf`
      (byte-identical set, included only by the three bootc profiles). Confirm the
      resolved bootc config is unchanged: `just cayo` / `just snow` / `just snowfield`
      build and the OCI matrix in `build-images.yml` still pushes.
- [x] **Confirm sysext deltas unaffected by base bootc-lib removal.** Run a real
      `just sysexts` (or the `build.yml` CI job) and confirm no sysext delta grew or
      broke because base no longer ships `libostree-1-1`/`libsoup-3.0-0`/etc. (Low
      risk — no sysext references them — but build-verify it.)
- [x] `build-images.yml` runs green on the branch head (bootc products still
      build, sign, and push to GHCR).

---

## 3. Production key custody (BLOCKING before any real publication)

The DEV key material has been replaced with production keys (2026-07 ceremony):
the committed OpenPGP update pubring `shared/native-ab/keys/import-pubring.gpg`
now carries the production key (uid `snosi native OS updates
<os-updates@frostyard.org>`, fpr `F37282A35CB6BDFEBFC8FE775A2EAC5C8216FD68`),
and the production MOK cert is committed as `shared/native-ab/keys/mok-2026.crt`
(shipped in-image at the version-neutral path `/usr/lib/snosi/mok.crt`). See
runbook §"Production key ceremony." Remaining items in this section rebuild the
images with those keys and confirm nothing private leaked.

- [x] **Generate the production OpenPGP update-signing key** offline (per §ceremony).
      Private half stays offline / in the `native-promotion` environment only. Public
      keyring committed as `shared/native-ab/keys/import-pubring.gpg` (DEV pubring
      replaced). Rotation uses an overlap window (both keys in the shipped pubring).
- [x] **Generate or confirm the production Secure Boot MOK keypair** (`mkosi.key`/`mkosi.crt`).
      Public cert committed as `shared/native-ab/keys/mok-2026.crt` (replaces
      `mok-dev.crt`; shipped at `/usr/lib/snosi/mok.crt`). Private key stays in
      protected signing only. Note: MOK rotation is a fleet-wide re-enrollment event —
      see CLAUDE.md "MOK Rotation."
- [x] **Confirm the production PCR signing keypair** (`pcr-signing.{key,crt}`,
      generated in the key ceremony) exists and is in the encrypted offsite backup.
      This is a **build-time** key (mkosi `SignExpectedPcr` reads
      `.snosi-private/pcr-signing.{key,crt}`), same custody tier as the MOK key —
      its private half goes into the `native-build` environment secrets in §4
      (`NATIVE_PCR_SIGNING_KEY` / `NATIVE_PCR_SIGNING_CERTIFICATE`), **not** the
      offline OpenPGP promotion tier. The public half is **not** committed to the
      repo; the build extracts it from the cert. (Nothing to commit here.)
- [x] **Local pre-flight rebuild with the production keys** (optional but
      recommended — the authoritative production images are built by CI in §4/§6/§7;
      this catches a bad/misformatted key locally in minutes instead of inside a
      gated CI run). Place the four build-time keys where the secure build reads
      them, all gitignored: `mkosi.key`/`mkosi.crt` at the **repo root** and
      `pcr-signing.{key,crt}` in **`.snosi-private/`**; then extract the PCR public
      key: `openssl x509 -in .snosi-private/pcr-signing.crt -pubkey -noout >
  .snosi-private/pcr-signing.pub`. For each profile: `just <profile>` then
      `OUTPUT_NAME=<profile> ./test/native-ab-secure-artifact-test.sh "" "" ""
  .snosi-private/pcr-signing.pub single`. This validates the MOK + PCR keys
      produce correctly-signed UKIs; the OpenPGP update key is validated separately
      by the publish→install round-trip in §6/§7. Do **not** publish the local build.
- [x] Confirm **no private key material is tracked** after the swap:
      `git grep -l 'PRIVATE KEY'` returns nothing; `.snosi-private/` and `mkosi.key`
      remain gitignored.

---

## 4. GitHub environments & secrets (BLOCKING before CI publication)

`build-native-images.yml` fails loudly until these exist. Create two **protected**
GitHub environments with required reviewers. See runbook §"Secret inventory" for
the full table.

- [ ] Create environment **`native-build`** (protected). Add secrets:
  - `NATIVE_SECURE_BOOT_KEY`, `NATIVE_SECURE_BOOT_CERTIFICATE`
  - `NATIVE_PCR_SIGNING_KEY`, `NATIVE_PCR_SIGNING_CERTIFICATE`
  - `NATIVE_R2_ACCESS_KEY_ID`, `NATIVE_R2_SECRET_ACCESS_KEY`,
    `NATIVE_R2_ACCOUNT_ID`, `NATIVE_R2_BUCKET`
- [ ] Create environment **`native-promotion`** (protected, required reviewers).
      Add secret:
  - `NATIVE_UPDATE_SIGNING_KEY` (OpenPGP update-signing private key — never leaves
    this environment; consumed only by `promote.sh --signing-key`).
- [ ] Confirm the interim protected-builder constraints are honored: the workflow
      triggers on `workflow_dispatch` + `main` push **only** (no `pull_request`/fork),
      writes key material to runner-local files with `always()` cleanup, and never
      echoes secrets. (Already coded; verify the environment protection rules back it.)
- [ ] **Long-term:** migrate MOK/PCR signing to an HSM/PKCS#11 or a locked
      self-hosted signer (the current in-runner key files are the documented interim
      risk — runbook §"Interim protected-builder constraints").

---

## 5. Cloudflare / R2 origin (BLOCKING before publication)

R2 is the only blob origin. The metadata cache-bypass is a correctness
requirement, not a nicety — a stale edge-cached `SHA256SUMS`/`.gpg` pair defeats
the signature-first ordering.

- [ ] Create the R2 bucket and confirm it is served under
      `https://repository.frostyard.org/os/native/v1/<product>/x86-64/` and
      `https://repository.frostyard.org/isos/native/v1/` (frozen in contract §5).
- [ ] Add a Cloudflare **cache rule that bypasses cache** for the exact names
      `SHA256SUMS` and `SHA256SUMS.gpg` under those prefixes (runbook §"Cache-Control
      and cache-bypass rules").
- [ ] Wire `promote.sh --purge-hook <cmd>` to a real Cloudflare purge script that
      purges exactly the two metadata URLs, and **verify from a second region** that
      the new matched pair is served (runbook §14-15). Do not treat an API 200 alone
      as success.
- [ ] Confirm payload objects get `Cache-Control: public, max-age=31536000, immutable`
      and both metadata files get `no-store` (the workflow/scripts set these — verify
      on real responses).

---

## 6. Per-product artifact & capacity validation (per product)

Run for `cayo-ab`, then `snow-ab`, then `snowfield-ab`. Snowfield capacities are
still `PROVISIONAL` — this is where they get confirmed with production keys.

- [ ] `just <product-ab>` builds clean with production keys.
- [ ] `OUTPUT_NAME=<product-ab> test/native-ab-secure-artifact-test.sh ... single`
      passes (root-package coherence, private systemd lib + TPM token plugin in
      initrd, UKI `.pcrpkey`/`.pcrsig` sections). See
      `test/native-ab-secure-boot-test.sh` for the exact argument list.
- [ ] Snowfield only: `sudo test/snowfield-artifact-test.sh` passes (Surface
      kernel packages present, no backports kernel, Surface modules/firmware/initrd
      content).
- [ ] Capacity budgets pass: root slot ≥20% headroom (spare/total), UKI + two
      copies + shim + MokManager + systemd-boot fit the 1 GiB ESP. Update
      `docs/native-ab-capacities.md` with the production-key measurements and remove
      the `PROVISIONAL` marker for any product that passes.
- [ ] `check-native-publication-guard.sh` passes for all three production profiles
      (`SecureBoot=yes`, `ShimBootloader=signed`, `SignExpectedPcr=yes`, NvPCR
      disable, ab-root include, pubring present, no `KernelModules=` filter).

---

## 7. Runtime validation gates (per product)

- [ ] **QEMU secure full window** — `sudo PROFILE=<product-ab>
test/native-ab-secure-boot-test.sh --full-window` green (N→N+3, slot reuse,
      rollback, 3-try boot-count fallback, per-boot NvPCR clean, recovery unlock,
      under enforced Secure Boot + unattended TPM). Done for snow-ab; **run for
      cayo-ab and snowfield-ab**.
- [ ] **QEMU end-to-end install** — `sudo test/native-installer-e2e-test.sh`
      green for cayo-ab + snow-ab (add `--with-snowfield` only when running on/for
      Surface). Confirms ISO boot on virgin varstore, own-boot-medium refusal in the
      real initramfs, signed install with stock pubring trust, pre-enrollment
      Security Violation, restage-mok, MOK-enrolled enforced/unattended boot.
- [ ] **Surface hardware gate (snowfield only, PENDING HUMAN GATE)** — cannot be
      done in QEMU. On a representative Surface device (CLAUDE.md "PENDING HUMAN
      GATE" has the full step list):
  1. `just snowfield-ab` + artifact tests (§6).
  2. `sudo PROFILE=snowfield-ab test/native-ab-secure-boot-test.sh --full-window`
     green.
  3. Write the installer ISO to USB with raw `dd`/`cp` (preserves the ISO9660
     volume ID — Ventoy/Rufus ISO-DD label rewriting defeats the installer-medium
     self-refusal). Enroll the Snosi MOK cert via MokManager on the signed-shim
     boot. Run `/usr/libexec/snosi-install --product snowfield-ab --encrypt-var
--recovery-key-file <off-disk path> ...` against the real disk.
  4. Verify unattended TPM unlock, then install → update → rollback → fallback
     with **touch, pen, keyboard/cover, Surface storage/network, and power
     management** all functional and required modules loaded under lockdown.
  5. Confirm S3 suspend/resume works and **S4 hibernation is blocked gracefully**
     (expected under `lockdown=integrity` — must not crash/hang).

---

## 8. First production publication (per product, after gates pass)

Products promote independently — a Snowfield failure must not block Cayo/Snow.
Full commands in runbook §"Candidate → verify → promote → purge procedure."

- [ ] For the very first autostage-enabled release, build the profile with
      `SNOSI_NATIVE_AUTOSTAGE=1` so the installed image acquires the static
      `snosi-sysupdate-stage.timer` activation link (runbook §6; the Phase 4
      mechanism). Until then, native images ship with automatic staging **off** and
      updates are manual only.
- [ ] Run the pipeline against **real R2** (not the local rehearsal origin):
      `prepare-native-publication.sh --xz` → `generate-sbom.sh` →
      `publish-candidate.sh` (candidate prefix) → `verify-remote.sh` (size/SHA/full
      GET/range GETs from the public URL) → `promote.sh --signing-key <prod key>
--pubring <prod pubring> --purge-hook <cf-purge>` (signature-first,
      manifest-last, no-store, purge).
- [ ] `test-public-origin` equivalent: from a clean machine, verify the promoted
      index with the **shipped** production pubring and confirm a real install/update
      succeeds from the public URL.
- [ ] Publish the installer ISO to `isos/native/v1/` (same candidate→verify→promote
      flow; runbook §"Installer ISO publication").
- [ ] Publish GitHub release notes linking the R2 URLs, GHCR digests, SHA-256s,
      update-key fingerprint, SBOM/provenance, and minimum disk sizes (runbook / plan
      §"GitHub Releases"). No OS blobs in the release — R2 is the only origin.

---

## 9. Rollout & operational readiness

- [ ] Internal canary: install each product on internal hardware from the real
      ISO, take at least one real published update, and confirm
      `snosi-update-status` / `snosi-update-status --check` report correctly.
- [ ] Confirm the withdrawal path works against real R2: `withdraw.sh --purge-hook
<cmd>` restores the previous matched `SHA256SUMS`+`.gpg` pair and un-offers a
      bad release (runbook §"Withdrawal").
- [ ] Apply the retention policy (keep current + previous 2 stable; 90-day
      withdrawn grace; installer ISOs retained shorter than root objects) — runbook
      §"Retention policy application."
- [ ] Migration doc for existing bootc users: backup → reinstall → restore (native
      A/B cannot be created in place on a bootc disk). Track installed format so bootc
      hosts are never offered native updates and vice-versa.

---

## Post-launch follow-ups (do NOT block first use, but track)

These were reviewed and accepted as ship-safe; close them on their own cadence.

- [ ] Rotate DEV → production keys is done in §3; after GA, retire the DEV
      pubring/cert from history references and confirm no supported image still trusts
      DEV material.
- [ ] Add live test coverage for the stager's not-newer guard (currently
      belt-and-suspenders, structurally correct, no dedicated test).
- [ ] `snosi-install`: add ownership (not just mode) check on `--*-file` secret
      inputs; refuse `EUID==0` in the unit test to avoid hitting the production origin;
      document the Ventoy/Rufus volid limitation to users (already in CLAUDE.md).
- [ ] Snowfield cert-binding harness assertions get their first real execution
      during the §7 Surface `--full-window` run — confirm they pass there.

---

## Quick gate summary

| Gate                                 | Blocks                     | Where |
| ------------------------------------ | -------------------------- | ----- |
| updex component release              | **merge**                  | §1    |
| bootc-parity sign-off                | **merge**                  | §2    |
| production key ceremony              | **any real publish**       | §3    |
| GitHub environments/secrets          | **CI publish**             | §4    |
| Cloudflare cache-bypass + purge      | **publish**                | §5    |
| artifact + capacity (per product)    | **that product's publish** | §6    |
| QEMU full-window + e2e (per product) | **that product's publish** | §7    |
| Surface hardware                     | **snowfield publish only** | §7    |

Nothing in §8 (first publication) may run until §1–§5 are all `[x]` and the
product's §6–§7 rows are `[x]`.
