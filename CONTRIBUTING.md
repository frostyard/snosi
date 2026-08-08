# Contributing to snosi

Thanks for contributing to snosi.

## Before you start

- Read `README.md` for project goals and build outputs.
- Read `CLAUDE.md` and `yeti/OVERVIEW.md` for repository architecture, contracts, and operational constraints.
- For security issues, follow `SECURITY.md` and use GitHub Security Advisories (not public issues).
- If you work with an AI coding agent, start from a prompt in `.github/prompts/`.

## Development workflow

1. Create a branch from `main`.
2. Classify the change using [`docs/risk-tiers.md`](docs/risk-tiers.md).
3. Make focused, minimal changes.
4. Run the most relevant local checks before opening a PR.
5. Open a PR with clear context and test evidence.

## Build and test

Common local commands:

```bash
just
just sysexts
just snow
just snowfield
just cayo
```

Validation scripts used by CI are in `test/` and `.github/workflows/validate.yml`.
Run targeted tests for your changes instead of running unrelated full-system builds.

## Pull request expectations

- Keep changes scoped to the issue.
- Do not include generated artifacts, credentials, or secrets.
- Update docs when behavior/contracts change.
- Explain what was changed, why, and how it was validated.
