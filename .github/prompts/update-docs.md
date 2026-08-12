# Prompt: update documentation after a change

Goal: bring the documentation back in sync with `<the change that just landed>`.

A task in this repository is not complete until the documentation is reviewed
and updated. Work through these, in order:

1. `CLAUDE.md` — the operational contract summary an agent reads before any
   change. Update the section that covers the area you touched. Record *why* a
   constraint exists and what breaks without it, not just what the code does.
2. `docs/design/` (formerly `yeti/`) — written for AI consumption:
   architecture, patterns, and decision rationale rather than user-facing
   guides. Update `docs/design/overview.md` plus the focused file for the area
   (`build-pipeline.md`, `ci-cd.md`, `sysexts.md`, `testing.md`).
3. The rest of `docs/` — normative contracts and runbooks (see the index in
   `docs/README.md`). Change these only when the contract itself changed, and
   say so explicitly in the pull request.
4. `README.md` — only when a user-visible output, build target, or supported
   flow changed.

Guidelines:

- Prefer amending an existing section over appending a new one; duplicated,
  drifting descriptions of the same mechanism are worse than none.
- Record root causes for bugs that were non-obvious, including the evidence
  that proved them, so the same investigation is not repeated.
- Mark anything unproven as blocked or provisional. Never describe a gate as
  passing on the strength of a fixture or static check alone.
- Do not create new planning or note files; add them only when explicitly
  requested.
