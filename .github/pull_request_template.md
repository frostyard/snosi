<!-- The repository owner reviews L1 and L2 pull requests, those with the
risk:high label. Branch from the latest main. Reviews apply AGENTS.md,
docs/review-rubric.md and the docs rules. -->

## Summary

<!-- What does this change do, and why? Link the issue it closes. -->

Closes #

## Type of change

- [ ] Image or profile change (`snow`, `snowfield`, `floe`, `sundog`, `firn-installer`)
- [ ] Sysext change
- [ ] Build pipeline / CI change
- [ ] Documentation only
- [ ] Other:

## Risk tier

Declare the highest applicable tier, never lower; the scale is
[docs/risk-tiers.md](../docs/risk-tiers.md) (1 low, 2 moderate, 3 high,
4 critical). A `risk:high` label (a path at L1 or L2, from a glob in
`.github/risk-paths.json` or from core's organization floors; the same
workflow adds the `level:L1` to `level:L4` label) means tier 3 or higher:
name each matched path and why the change is safe.

Risk tier: <!-- 1-4 --> — <!-- justification -->

## Validation

<!-- List the commands you actually ran and their outcome. -->

- [ ] `make verify` passes (the baseline gate)
- [ ] `shellcheck` / `validate.yml` static checks pass for touched scripts
- [ ] Relevant `just` build target(s) succeed
- [ ] Relevant tests in `test/` were run
- [ ] Revert test for a fix: the new test fails with the fix reverted; command: <!-- name it -->
- [ ] Workflows changed: every action is SHA-pinned with `# vX.Y.Z`, `permissions: {}`, and `persist-credentials: false`

Commands run:

```
```

## Docs housekeeping

<!-- Delete rows that do not apply. -->

- [ ] Documentation updated (`AGENTS.md`, `README.md`, `docs/`) where relevant
- [ ] New docs started from their category's `TEMPLATE.md` and indexed in `docs/README.md`
- [ ] Cross-links added in both directions (ADR ↔ design ↔ spec ↔ plan)
- [ ] New significant decision recorded as an ADR first, in this PR

## Checklist

- [ ] Changes are as small and focused as possible
- [ ] No secrets, keys, or credentials are committed
- [ ] New external downloads are pinned and go through `verified_download()`
- [ ] Blocking review point fixed: guard added and 1 `.memory/corrections.jsonl` line added
