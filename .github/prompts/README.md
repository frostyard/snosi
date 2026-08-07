# Prompts catalog

Reusable prompts for AI coding agents working in this repository.

Each file is a task-scoped prompt: paste it (or reference it) at the start of a
session, then replace the `<...>` placeholders with the specifics of your task.
Every prompt assumes the agent has first read `CLAUDE.md` and `yeti/OVERVIEW.md`,
which hold the architecture, contracts, and operational constraints that most
mistakes in this repository come from ignoring.

| Prompt | Use it for |
|--------|-----------|
| [`add-sysext.md`](add-sysext.md) | Adding or changing a system extension under `mkosi.images/` |
| [`native-ab-change.md`](native-ab-change.md) | Touching the native A/B profiles, channels, or update path |
| [`update-docs.md`](update-docs.md) | Bringing `CLAUDE.md`, `README.md`, and `yeti/` back in sync with code |
| [`triage-ci-failure.md`](triage-ci-failure.md) | Investigating a failed workflow run |

## Conventions

- Prompts describe *how to work here*, not project status; keep status in
  `CLAUDE.md` and `yeti/`.
- Keep each prompt self-contained and under roughly one screen.
- When a contract changes (for example `docs/native-ab-contracts.md`), update
  the prompt that points at it in the same pull request.
