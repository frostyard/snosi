# PR Review Rubric

Use this rubric when reviewing pull requests in this repository. A review should
focus on correctness, security, maintainability, and whether the submitted change
preserves the repository's documented build, test, and release contracts.

## Required review gates

A pull request is ready to merge only when the reviewer can answer "yes" to each
applicable gate:

- **Scope:** Does the change solve the stated issue without unrelated rewrites or
  incidental cleanup?
- **Behavior:** Are user-visible behavior, boot/install/update flows, and failure
  modes intentional and documented when they change?
- **Tests:** Are targeted tests, fixtures, or manual validation included for the
  changed path, or is the reason for skipping tests explicit and reasonable?
- **Security:** Does the change avoid introducing secrets, weakening signature,
  Secure Boot, TPM, update-policy, or installer trust boundaries, and broadening
  accepted inputs without a corresponding guard?
- **Immutability:** Does the change respect the image layout: immutable `/usr`,
  persistent `/var`, overlay `/etc`, and no runtime `systemctl enable`/`disable`
  mutations of shipped policy?
- **Publication safety:** For build, release, or publication changes, are failed
  candidates prevented from promotion and are credentials kept out of images,
  logs, retained artifacts, and committed files?
- **Documentation:** Are directly related docs updated, especially contracts in
  `docs/`, operational context in `CLAUDE.md`, and architecture notes in
  `docs/design/` (formerly `yeti/`)
  when source behavior changes?

## Reviewer response guide

Prefer review comments that identify a concrete risk and the smallest acceptable
fix. Mark blocking comments when a change can break an install, update, security
boundary, publication pipeline, or documented contract. Non-blocking suggestions
should be clearly labelled so they do not obscure merge-critical feedback.
