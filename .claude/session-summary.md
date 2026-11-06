# Session Summary

This file is a learning artifact for AI agents working in this repository. It
captures a short, running record of what recent sessions accomplished so a
new session can pick up context quickly instead of starting cold.

Related learning artifacts:

- `.memory/corrections.jsonl` — append-only log of corrections learned during
  past sessions (see `.memory/README.md` for conventions).
- `docs/design/` (formerly `yeti/`) — AI-oriented architecture and
  decision-rationale documentation; start at `docs/design/overview.md`.
- `AGENTS.md` — the canonical agent instructions for this repository;
  `CLAUDE.md`, `GEMINI.md`, `.cursorrules` and
  `.github/copilot-instructions.md` are symlinks to it.

## Conventions

- Keep entries short: date, scope, what changed, and any follow-up.
- Prefer promoting durable facts to `AGENTS.md` or `docs/` and note that here
  rather than duplicating long-form detail in this file.
- This file complements, but does not replace, `.memory/corrections.jsonl`.

## Log

- 2026-08-08: Added this `session-summary.md` artifact to satisfy the ACMM
  `acmm:session-summary` criterion (frostyard/snosi#567). No source changes.
- 2026-11-05: Brought the repository to core's baseline (ADR-0071): `make
  verify`/`check`/`ci`, `mise.toml`/`mise.lock`, `ci.yml`, the template gate,
  `.claude/skills`, and `docs/superpowers/` folded into `docs/` and deleted.
