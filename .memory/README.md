# `.memory/` — agent learning and correction capture

This directory is the repository's durable, version-controlled memory for AI
agents working in snosi. It exists so an agent starts a session with the
corrections and hard-won findings of previous sessions instead of starting
cold.

It complements, and does not replace, the existing documentation:

- `CLAUDE.md` — normative build/architecture guidance for agents.
- `docs/` — the four-category documentation tree (`docs/README.md`); its
  `docs/design/` docs (formerly `yeti/`) carry the detailed architecture and
  decision rationale written for AI consumption.

Use `.memory/` for the *deltas* between what an agent believed and what turned
out to be true. When a correction hardens into a general rule, promote it into
`CLAUDE.md` or the relevant `docs/` page and keep the correction entry as the
record of how it was learned.

## Files

- `corrections.jsonl` — append-only JSON Lines log of corrections. One JSON
  object per line, never rewritten or reordered; edit an existing entry only to
  fix a factual error in it.

## `corrections.jsonl` entry shape

```json
{"date": "2026-08-07", "scope": "shared/native-ab", "correction": "what was believed and what is actually true", "evidence": "file:line, command output, or issue/PR reference", "promoted_to": "CLAUDE.md section, docs/<file>.md, or null"}
```

Field notes:

- `date` — ISO `YYYY-MM-DD` of when the correction was established.
- `scope` — repo-relative path, profile name, or subsystem the correction
  applies to.
- `correction` — one or two sentences: the mistaken belief and the verified
  reality, with the reality stated positively.
- `evidence` — how it was verified: a path plus line, a command that was run,
  or an issue/PR number. Never "seemed to work".
- `promoted_to` — where the durable form of this rule now lives, or `null` if
  it has not been promoted yet.

Do not record secrets, credentials, or personal data here; this directory is
committed to the repository.
