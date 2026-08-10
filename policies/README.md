# Repository policies

This directory contains machine-readable governance policy for automated and
AI-assisted contributions. The policy supplements, and does not replace,
[`AGENTS.md`](../AGENTS.md), [`docs/SECURITY-AI.md`](../docs/SECURITY-AI.md),
and [`docs/risk-tiers.md`](../docs/risk-tiers.md).

`agent-governance.json` is fail-closed: agents cannot merge, release, deploy,
change protected environments, or approve their own exceptions. Every change
requires a pull request, human review, risk classification, and validation
evidence. Changes to a protected boundary also require rejection-path tests.

`test/policy-as-code-test.py` validates the policy's schema and safety
invariants and confirms that the repository validation workflow runs the gate.
The test intentionally rejects unknown policy versions so schema changes need
an explicit test and review update.

Policy exceptions must be proposed in a pull request with rationale and
compensating controls and require maintainer approval. Editing this policy is
not itself an exception to it.
