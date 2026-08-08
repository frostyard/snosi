# AI Quality Assurance

This repository uses existing build, test, and validation workflows as its quality dashboard for agent and code changes.

## Quality Signals

- CI workflows under `/home/runner/work/snosi/snosi/.github/workflows/` provide build, validation, installer, and security checks.
- Native and bootc test harnesses in `/home/runner/work/snosi/snosi/test/` provide reproducible artifact and runtime assertions.
- Dependency and publication checks provide visibility into supply-chain integrity and release correctness.

## How to Review Quality

1. Check workflow run status for `validate.yml`, image build workflows, and installer/native test workflows.
2. Review failing job logs to identify regressions in build output, tests, or publication checks.
3. Confirm issue-specific changes include targeted verification and preserve existing contract tests.

## Quality-Gated Change Expectation

Changes should be considered ready only when relevant existing validations pass and no new security or secret-scanning concerns are introduced.
