---
name: Incident report
about: Report a production-impacting incident (bad publish, broken pipeline, wrong image promoted)
title: "[incident] "
labels: "incident"
assignees: ""
---

## Summary

One or two sentences: what broke, what is user-visible, and current status
(ongoing / mitigated / resolved).

## Impact

- **Affected profiles/images:** (e.g. `cayo`, `snow`, `snowfield`, `flurry`)
- **Affected tags:** (`latest`, a specific version tag, or both)
- **User-facing effect:** (stale image, failed pull, wrong image promoted,
  broken install/update path)
- **Started (UTC):**
- **Detected (UTC):**

## Detection

How was this found? (CI failure, `check-bootc-publication-guard.sh` or
another guard/test failing, user report, monitoring/alert, manual
inspection). If nothing detected this automatically, say so — a detection
gap is itself an action item.

## Relevant links

- Failing workflow run:
- Relevant runbook, if one applies:
  [runbooks/image-publication-failure.md](../../runbooks/image-publication-failure.md)
  or note that no runbook exists yet.

## Current mitigation status

What has been done so far to stop further impact (e.g. `latest` left
untouched per [ADR-0008](../../docs/adr/0008-digest-first-release-latest-is-promotion.md),
a bad tag reverted, a workflow paused).

## Security vulnerabilities

Do not report security vulnerabilities here. Follow the private reporting
instructions in the
[security policy](https://github.com/frostyard/snosi/security/policy).

## Follow-up

Once resolved, file a postmortem using
[docs/postmortem-template.md](../../docs/postmortem-template.md) and link
it here.
