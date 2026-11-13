# 0036 — Prune installer ISOs after each promotion

- **Status:** Proposed
- **Date:** 2026-11-13

## Context

[ADR-0018](0018-remove-native-ab-and-nbc-lanes.md) ended automatic retention
for `isos/native/v1/` and required a separate exact-object decision before
any published object is deleted. Its retention workflow had never run
successfully: the job read repository-level R2 secrets, and those exist only
in the `native-promotion` environment.

Since then `build-installer-iso.yml` has promoted about 3.5 installer ISOs a
day (40 runs from 2026-11-02 to 2026-11-13). Each ISO is about 0.89 GB
(888,588,288 bytes for version 20261113011940). Nothing deletes one. The
bucket held 336 GB on 2026-11-13. R2 bills storage and Class A and B
operations and has no egress fee; storage is the line that grows, by about
3 GB a day without limit.

The live signed index (`SHA256SUMS`) names exactly one ISO, and the
stable-download Worker redirects to that one. An older ISO is reachable only
by someone who kept its versioned URL. An installer ISO is not an update
source: an installed system updates through bootc and never reads this
namespace.

## Decision

The promote job of `build-installer-iso.yml` runs
`shared/native-ab/publish/retention.sh --execute` after the new index and the
stable redirect have verified. The job already has the `native-promotion`
environment's R2 credentials.

The script manages one payload name only:
`snosi-installer_<14-digit version>_x86-64.iso` at the top of
`isos/native/v1/`. It keeps:

- every object the live signed index names, after verifying that index with
  gpgv against `shared/native-ab/keys/import-pubring.gpg`;
- the two newest versions older than the live one;
- every version newer than the live one;
- every object younger than 24 hours (by the time R2 stored it);
- the `.history/<version>/` index pair of every version whose ISO it does
  not delete in the same run, including versions that never had a
  `snosi-installer` ISO;
- every object it cannot classify, including historical
  `snosi-native-installer_*` media.

It deletes the remaining installer ISOs, `.candidate/<version>/` scratch
older than 24 hours, and the `.history/<version>/` index pair of each ISO it
deletes in that run. It refuses to delete anything when the live index is missing, does
not verify, names more than one version, or names an absent object, and when
the index changes between planning and deletion.

One run deletes at most 30 objects. A larger plan deletes nothing, prints its
full list and raises a workflow warning. A maintainer clears such a backlog
by dispatching the workflow with `retention_max_delete` set, after reading
that list. This is a count-bounded authorization, not an exact-object one:
the dispatched run builds and promotes a new ISO first and then plans again,
so its list differs from the list that was read (about one more ISO and its
`.history` pair). The first backlog is every `snosi-installer` ISO outside
the keep window, because no retention run has ever succeeded.

The prune step is the last step of the promote job. A failed delete fails
the job, after the signing key is removed and the promoted marker is
uploaded.

This amends ADR-0018's consequence that the ISO namespace has no automated
retention, and replaces its exact-object gate with the count-bounded one
above for `snosi-installer` ISOs, their candidates and their archived index
pairs only. ADR-0018's gate still governs every other published object.

## Consequences

- Storage for the namespace settles at the kept ISOs: three by the version
  rule plus any younger than 24 hours.
- A versioned ISO URL stops working once that version leaves the keep
  window. Documentation and tests must link the stable URL, not a version.
- Until a maintainer clears the existing backlog, every run warns and deletes
  nothing.
- The step fails the promote job when R2 refuses a delete. The
  `native-promotion` R2 token needs object delete permission.
- A `.history/<version>/` pair younger than 24 hours when its ISO is deleted
  stays for good: later runs delete a pair only together with its ISO.
- Historical `snosi-native-installer_*` media and any other object in the
  bucket are untouched and still need their own decision.

## Alternatives considered

- **An R2 lifecycle rule by age:** deletes the live ISO when no build runs
  for the rule's period, and does not read the signed index.
- **A scheduled retention workflow:** the removed design; it needs the
  environment's credentials in a second job and can race a promotion.
- **Publish less often:** slows growth and reclaims nothing.
- **Delete the backlog automatically on the first run:** removes several
  hundred published objects with no one having read the list.

## References

- Amends: [ADR-0018](0018-remove-native-ab-and-nbc-lanes.md).
- Shapes: [CI/CD](../design/ci-cd.md), [testing](../design/testing.md).
- Enforced by: `test/iso-retention-test.sh`.
