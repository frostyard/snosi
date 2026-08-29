# Postmortem Template

Copy this file to `docs/postmortems/YYYY-MM-DD-short-title.md` when writing
up an incident. Keep it blameless: focus on systems and signals, not
individuals. See
[docs/adr/0008-digest-first-release-latest-is-promotion.md](adr/0008-digest-first-release-latest-is-promotion.md)
for a worked example of the "Context" section referencing a real incident
(GitHub Actions run 30627996880).

## Summary

One or two sentences: what broke, for how long, and who/what was affected.

## Impact

- **User-facing impact:** (e.g. which image profiles/tags were affected,
  whether `latest` pointed at a wrong or stale digest, whether any
  unverified image was ever reachable)
- **Duration:** first-detected timestamp → resolved timestamp
- **Detection:** how was this found (CI failure, guard script, user
  report, monitoring/alert)? If detection was slow or missing, note that
  explicitly — a missing alert is itself a finding.

## Timeline

All timestamps in UTC.

| Time | Event |
|------|-------|
|      | First deviation from expected behavior |
|      | Detected |
|      | Mitigated / stopped further impact |
|      | Root cause identified |
|      | Resolved |

## Root cause

What actually happened, at the level of the specific step, script, or
workflow job that failed or behaved incorrectly. Link to the relevant
runbook (e.g. [runbooks/image-publication-failure.md](../runbooks/image-publication-failure.md))
if one exists, or note that none existed and one should be written.

## Resolution

What was done to stop the impact and restore correct behavior. Note any
manual steps taken and whether they should become part of a runbook or an
automated safeguard instead.

## Contributing factors

List conditions that made this possible or made it worse (e.g. missing
guard check, a fallback that guessed instead of failing closed, an alert
that didn't exist, documentation that was stale).

## Action items

| Action | Owner | Type (prevent / detect / mitigate) | Status |
|--------|-------|-------------------------------------|--------|
|        |       |                                     | open   |

Every postmortem should produce at least one action item. If the answer is
"nothing to change," state why explicitly rather than leaving this empty.

## Lessons learned

What would have caught this sooner, or prevented it entirely? Is there an
existing guard/test that should have failed but didn't (e.g.
`check-bootc-publication-guard.sh`, `test/bootc-secure-artifact-test.sh`)?
