# 0010 — Credentials cross the sudo boundary as paths, never as bytes

- **Status:** Accepted
- **Date:** 2026-08-12

## Context

The secure image build needs signing material (MOK key/cert, PCR signing
key/cert, cosign key) inside a `sudo`-elevated mkosi invocation in CI.
Secret bytes in command arguments or a broadly preserved environment leak
into process listings, logs, and every child process; and key files that
outlive the job are a rotation liability. Locally, developers need durable
keys that survive `mkosi clean -ff` — which deletes the `.mkosi-private`
directory, because mkosi owns it.

## Decision

- **Bytes land once, before elevation:** the workflow writes each secret to
  a file under `/var/tmp/bootc-secure-credentials` with `umask 077` +
  `chmod 600`. Everything after that point handles *paths*: the sudo
  invocation forwards each `SNOSI_BOOTC_*` variable as an explicit
  `VAR="$VAR"` assignment (never `--preserve-env`), and the values are file
  paths. Only credential paths cross the boundary; secret bytes remain in
  the mode-0600 files.
- **Committed public identities are byte-checked before use:** the
  delivered MOK cert and derived PCR public key must `cmp` equal to the
  committed `shared/native-ab/keys/mok-2026.crt` and
  `pcr-signing-2026.pub`, so a wrong or rotated secret fails loudly before
  any signing happens.
- **Credentials are deleted before any registry write:** the removal step
  (`if: always()`) precedes the first push in the workflow.
- **Durable local keys live in the gitignored `.snosi-private/`** — never
  `.mkosi-private`, which mkosi owns and `mkosi clean -ff` removes.
  Key filenames are year-stamped (`mok-2026.crt`, `pcr-signing-2026.pub`)
  so rotation is visible in every reference, with history retained under
  `.snosi-private/history/`.

The native A/B workflows use the same shape (umask 077, chmod 600 files,
explicit forwarding, `rm -rf` of `/var/tmp/native-promote-secrets`).

## Consequences

- Secrets never appear in `ps`, workflow logs, or the environment of
  arbitrary build children; compromise of a build script reads files it was
  already trusted with, no more.
- The byte-check turns "wrong key configured in repo secrets" from a
  silently mis-signed artifact into an immediate, attributable failure.
- Deleting credentials before the first registry write bounds their
  lifetime to the build phase; nothing that talks to the network still has
  them. (The publication guard requires the cleanup step to exist with
  `if: always()`, but does not yet pin its position before the push — the
  ordering is held by the workflow itself.)
- Year-stamped names force every consumer to be updated at rotation —
  deliberate friction that makes stale-key use impossible to miss.

## Alternatives considered

- **`sudo --preserve-env`:** rejected — forwards the entire environment,
  including anything a previous step exported; explicit per-variable
  assignments are the allowlist form.
- **Secret bytes in env vars/arguments:** rejected — visible to process
  listings and inherited by every child of the elevated build.
- **Durable keys in `.mkosi-private/`:** rejected by mechanism — mkosi owns
  that directory and `mkosi clean -ff` deletes it; a routine clean would
  destroy signing keys.
- **Unversioned key names (`mok.crt`):** rejected — rotation becomes
  invisible; a year-stamp makes the active generation explicit at every
  call site.

## References

- Shapes: [bootc-secure-operations.md](../bootc-secure-operations.md),
  [design/ci-cd.md](../design/ci-cd.md)
- Implemented by: `.github/workflows/build-images.yml` (credential
  materialization, identity `cmp`, cleanup),
  `.github/workflows/build-native-images.yml`, `.gitignore`
  (`.snosi-private/`, `.mkosi-private/`), `shared/native-ab/keys/`
- Guarded by: `check-bootc-publication-guard.sh` (explicit sudo
  forwarding, cleanup-step presence), `test/bootc-publication-guard-test.sh`
- Related: [ADR-0009 — SNOSI_* variable classes](0009-snosi-env-var-classes.md)
- Builds on: [core ADR-0014 — single GPG trust root](https://github.com/frostyard/core/blob/main/docs/adr/0014-single-gpg-trust-root.md)
