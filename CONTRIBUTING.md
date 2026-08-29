# Contributing to snosi

Thanks for contributing to snosi.

## Before you start

- Read `README.md` for project goals and build outputs.
- Read [`ROADMAP.md`](ROADMAP.md) for direction: what is being worked on next,
  what is designed but unscheduled, what the project is deliberately **not**
  doing, and the bar a new sysext has to meet. Checking it first is the
  cheapest way to find out that an idea is already planned — or already
  declined.
- Follow the [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) in all project spaces.
- Read `CLAUDE.md` and `docs/design/overview.md` for repository architecture, contracts, and operational constraints.
- For security issues, follow the private reporting instructions in
  `SECURITY.md`; do not open a public issue.
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
