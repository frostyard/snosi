# Bootc Secure Packaging Sudo Environment Design

## Problem

Protected run `30555492550` passed credential materialization for Cayo, Snow,
and Snowfield. Cayo and Snow then completed `Package image` but failed local
artifact validation with `Error: missing assembled UKI`.

The protected package step declares `SNOSI_BOOTC_SECURE=1` and the four
credential-path variables in its GitHub Actions environment, but invokes the
packager as:

```text
sudo TMPDIR="$TMPDIR" ./shared/outformat/image/buildah-package.sh ...
```

Sudo receives only the explicitly assigned `TMPDIR`; its default environment
filter removes the five `SNOSI_BOOTC_*` variables. The packager consequently
takes its non-secure default, commits one ordinary image, and never calls the
UKI assembly path. The validator correctly rejects that image before any
registry write.

## Scope

Correct only the protected package invocation's sudo environment boundary and
the publication guard that enforces it. Do not change credential contents,
assembly behavior, validation behavior, registry ordering, labels, or the
secretless mechanics build.

## Design

Pass these values as explicit command environment assignments after `sudo`:

```text
TMPDIR
SNOSI_BOOTC_SECURE
SNOSI_BOOTC_MOK_KEY
SNOSI_BOOTC_MOK_CERT
SNOSI_BOOTC_PCR_KEY
SNOSI_BOOTC_PCR_CERT
```

Explicit assignments are preferred to `sudo --preserve-env`: they make the
privilege boundary visible at the call site and do not depend on runner sudo
policy. Only credential paths cross the boundary; secret bytes remain in the
mode-0600 files already created under `/var/tmp`.

Extend `check-bootc-publication-guard.sh` so each secure variable must appear
both in the step's GitHub Actions `env:` block and in the sudo command
environment. Extend the isolated publication-guard fixture with one mutation
per forwarded variable, proving that a declaration without forwarding fails.

## Documentation

Update `CLAUDE.md`, `README.md`, and `yeti/ci-cd.md` to record that GitHub step
environment variables do not automatically cross sudo and that the protected
packager forwards only the secure assembly flag and credential paths.

## Verification

Run the publication-guard fixture and real-tree guard, secure package cleanup
and negative fixtures, ShellCheck, actionlint, and `git diff --check`. After
review and merge, dispatch `build-images.yml` from `main` and require all three
profiles to pass secure packaging and local validation before any immutable
push. Continue watching through immutable signing, remote verification,
policy-copied validation, and `latest` promotion.

A successful rerun changes production registry state. A failed package or
local validation must continue to leave immutable and mutable registry tags
untouched.
