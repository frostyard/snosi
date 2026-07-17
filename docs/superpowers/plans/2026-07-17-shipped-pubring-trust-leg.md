# Shipped Vendor Keyring Trust Leg Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a QEMU update-harness leg that performs a sysupdate hop with NO `/etc/systemd/import-pubring.*` override, so systemd-sysupdate must verify the signed index using ONLY the shipped `/usr/lib/systemd/import-pubring.pgp` vendor keyring — closing the last untested link that let the 2026-07-17 signature-verification outage (commit 91718d7) ship.

**Architecture:** The leg goes in `test/native-ab-secure-boot-test.sh` — the ONLY harness that boots the production profiles running Forky systemd 261, whose vendor keyring path is `import-pubring.pgp`. This is load-bearing: Trixie's systemd 257 (verified on this host: `strings /usr/lib/systemd/systemd-pull` shows only `.gpg` paths) still reads the OLD `/usr/lib/systemd/import-pubring.gpg` name, so every `cayo-ab-raw`-based harness (updateux, components, update-test, publication-test — including publication-test's existing "never touch /etc, verify against the stock shipped pubring" leg) structurally CANNOT exercise the `.pgp` link, which is exactly why the outage slipped past all of them. Because the committed pubring is now the PRODUCTION key (private half offline-only, per `shared/native-ab/keys/README.md`), the harness bakes its ephemeral TEST keyring into the built images at BOTH `/usr/lib/systemd` names via two mkosi CLI `--extra-tree` flags — CLI list-setting values append AFTER config-file values (`.mkosi/mkosi/config.py` `finalize_value`: `return cfg_value + v`) and `install_extra_trees` copies in list order with overwriting `cp`, so the ephemeral pair wins over `shared/outformat/ab-root/mkosi.conf`'s committed pair. The `/etc/systemd/import-pubring.gpg` scp override is removed entirely; the existing Step 6 secure update hop becomes the positive shipped-trust-path proof, and a new Step 6c proves the negative: an index signed by a valid-but-untrusted key is rejected (the outage's exact failure-mode class, `gpg: Can't check signature: No public key`).

**Tech Stack:** bash, mkosi (pinned `.mkosi` checkout), gpg/gpgv, QEMU/OVMF/swtpm, systemd-sysupdate 261.

## Global Constraints

- The shipped default trust configuration is never weakened: the committed production pubring file `shared/native-ab/keys/import-pubring.gpg` is never modified on disk; the swap happens only in test-built image content via `--extra-tree`.
- Verification property (frozen): systemd-sysupdate must verify using ONLY `/usr/lib/systemd/import-pubring.pgp` — no `/etc/systemd/import-pubring.*` file may exist in the guest (asserted).
- Version grammar `^[0-9]{14}$`; fabricated newer versions use the hardlink trick from `test/native-ab-updateux-test.sh` Step 4 (no extra mkosi build).
- Default-mode assertion flow before Step 6 is unchanged; `--full-window` continues to work (Step 6c restores the origin's known-good N+1 index before returning).
- `set -euo pipefail`, shellcheck-clean (validate.yml runs shellcheck).

---

### Task 1: Harness changes in `test/native-ab-secure-boot-test.sh`

**Files:**
- Modify: `test/native-ab-secure-boot-test.sh`

**Interfaces:**
- Consumes: `$WORK_DIR/gnupg` (ephemeral signing homedir), `publish_dest` global set by `publish_version`, helpers `assert_eq`/`assert_true`/`assert_false`/`assert_contains`, `vm_ssh`, `guest_version`.
- Produces: env var `SIGNING_GNUPGHOME` (required with `SKIP_BUILD=1`), `$WORK_DIR/import-pubring.gpg` (exported ephemeral public ring, now created BEFORE builds), Step 6c.

- [ ] **Step 1: Move ephemeral keygen before the builds; add `SIGNING_GNUPGHOME`**

Add `: "${SIGNING_GNUPGHOME:=}"` to the env-default block (after `BUILD_N3_DIR`). Insert after the `mkdir -p "$WORK_DIR/..."`/`chmod 700 "$WORK_DIR/gnupg"` lines, before the `SKIP_BUILD` build block:

```bash
# The ephemeral update-signing key must exist BEFORE the builds:
# build_profile bakes its public keyring into every built image over the
# committed production pubring (whose private half is offline-only --
# shared/native-ab/keys/README.md), so it can no longer be generated
# lazily at publish time. With SKIP_BUILD=1 the prebuilt images already
# contain SOME baked ring, so the matching homedir must be supplied.
if [[ "$SKIP_BUILD" == 1 ]]; then
    [[ -n "$SIGNING_GNUPGHOME" ]] || {
        echo "Error: SKIP_BUILD=1 requires SIGNING_GNUPGHOME (the gnupg homedir whose key was baked into the prebuilt images)" >&2
        exit 1
    }
    cp -a "$SIGNING_GNUPGHOME/." "$WORK_DIR/gnupg/"
else
    gpg --homedir "$WORK_DIR/gnupg" --batch --passphrase '' --quick-generate-key \
        'snosi native A/B secure-boot test <native-ab-secure-boot-test@invalid>' ed25519 sign 0
fi
gpg --homedir "$WORK_DIR/gnupg" --batch --export > "$WORK_DIR/import-pubring.gpg"
```

Delete the old keygen block in Step 6 (the `gpg --quick-generate-key` + `--export` pair above `publish_version "$BUILD_N1_DIR"`), leaving a one-line comment pointing at the pre-build location.

- [ ] **Step 2: Bake the ring in `build_profile`**

```bash
    "$MKOSI" --profile "$PROFILE" \
        --extra-tree "$WORK_DIR/import-pubring.gpg:/usr/lib/systemd/import-pubring.gpg" \
        --extra-tree "$WORK_DIR/import-pubring.gpg:/usr/lib/systemd/import-pubring.pgp" \
        build
```

with a comment explaining the CLI-appends-after-config + overwrite-in-order mechanism (verified in `.mkosi/mkosi/config.py` `finalize_value` and `__init__.py` `install_extra_trees`).

- [ ] **Step 3: Remove the `/etc` pubring override; add shipped-trust-path assertions**

In Step 6: change `vm_ssh 'mkdir -p /etc/sysupdate.d /etc/systemd'` to `vm_ssh 'mkdir -p /etc/sysupdate.d'`; delete the second scp (`import-pubring.gpg` → `/etc/systemd/import-pubring.gpg`). After the transfers scp, add:

```bash
assert_false "no /etc/systemd/import-pubring.gpg override (shipped trust path only)" \
    vm_ssh 'test -e /etc/systemd/import-pubring.gpg'
assert_false "no /etc/systemd/import-pubring.pgp override (shipped trust path only)" \
    vm_ssh 'test -e /etc/systemd/import-pubring.pgp'
ephemeral_ring_hash="$(sha256sum "$WORK_DIR/import-pubring.gpg")"
ephemeral_ring_hash="${ephemeral_ring_hash%% *}"
guest_pgp_hash="$(vm_ssh 'sha256sum /usr/lib/systemd/import-pubring.pgp' | awk '{print $1}' || true)"
assert_eq "shipped /usr/lib/systemd/import-pubring.pgp is the baked ephemeral test ring" \
    "$guest_pgp_hash" "$ephemeral_ring_hash"
guest_gpg_hash="$(vm_ssh 'sha256sum /usr/lib/systemd/import-pubring.gpg' | awk '{print $1}' || true)"
assert_eq "shipped /usr/lib/systemd/import-pubring.gpg twin matches the baked ring" \
    "$guest_gpg_hash" "$ephemeral_ring_hash"
pull_refs_pgp="$(vm_ssh "grep -al 'import-pubring.pgp' /usr/lib/systemd/systemd-pull /usr/lib/systemd/systemd-sysupdate 2>/dev/null" || true)"
assert_true "guest systemd's import machinery references the vendor .pgp name (261 semantics)" \
    bash -c "[[ -n '$pull_refs_pgp' ]]"
```

(with the block comment explaining WHY this harness, and why the 257-based ones can't carry this.)

- [ ] **Step 4: Add Step 6c (wrong-key negative) after Step 6b's health check, before the `FULL_WINDOW` gate**

Save `SHA256SUMS`/`SHA256SUMS.gpg`, hardlink N+1's published root/verity/efi under `wrong_fake_version=$(printf '%014d' $((n1_version + 1)))`, append their hashes to `SHA256SUMS`, sign with a fresh `$WORK_DIR/gnupg-wrong` key, `gpg --verify` sanity-check the wrong-key signature is itself valid, run the stager: assert rc!=0, `outcome=failed`, no `/run/snosi/update-staged`, no `${IMAGE_ID}_${wrong_fake_version}_r` partition, running version still N+1. Then remove the fake hardlinks and restore the saved index pair. (Full code in the implementation; mirrors updateux Step 4's structure.)

- [ ] **Step 5: Update the harness header** (step 6 narrative, new step 6c, env-overrides list gains `SIGNING_GNUPGHOME`) and run `shellcheck test/native-ab-secure-boot-test.sh`.

- [ ] **Step 6: Commit** `test: secure-boot harness exercises the shipped vendor pubring (.pgp) trust path`

### Task 2: Documentation

**Files:**
- Modify: `CLAUDE.md` (".pgp fix 2026-07-17" paragraph + secure-boot harness description)
- Modify: `yeti/testing.md` (secure-boot test section)
- Modify: `yeti/OVERVIEW.md` (publication-test paragraph over-claims "exactly the same trust path a secure production profile would" — correct with the 257-vs-261 vendor-path distinction)
- Modify: `shared/native-ab/keys/README.md` ("QEMU tests are unaffected" bullet)

- [ ] **Step 1: Apply the four doc updates** — each states: 261 reads `.pgp` (no /usr `.gpg` fallback), 257 reads `.gpg`, only secure-boot-test boots 261, it now bakes the ephemeral ring at both /usr names via CLI `--extra-tree` and runs with NO `/etc` override, positive + wrong-key negative.

- [ ] **Step 2: Commit** `docs: record the shipped-pubring trust-path coverage`

### Task 3: Verification

- [ ] **Step 1:** `shellcheck test/native-ab-secure-boot-test.sh` — clean. *(0 findings)*
- [ ] **Step 2:** `bash -n test/native-ab-secure-boot-test.sh` — parses. *(pass)*
- [ ] **Step 3:** Full run: `sudo PROFILE=cayo-ab test/native-ab-secure-boot-test.sh` (default mode, ~1h: two cayo-ab builds + QEMU SB/TPM boot + Step 6/6b/6c). Expect prior 47 assertions + 6 new Step-6 trust asserts + 6 new Step-6c asserts, 0 failed. **Result: 59/59 passed, 0 failed** (N=20260718014753 → N+1=20260718015500; includes +1 for the pre-existing conditional cayo netdev-owner assert). Baked-ring swap verified in-guest by sha256; systemd 261 `.pgp` string canary confirmed on systemd-pull; wrong-key index rejected with `outcome=failed`, nothing staged.
