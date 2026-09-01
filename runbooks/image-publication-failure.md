# Runbook: Secure Image Publication Failure

## Purpose

This runbook is for on-call triage of a failed or stalled `secure-build`
publish in `.github/workflows/build-images.yml`. It covers the digest-first
pipeline described in
[ADR-0008](../docs/adr/0008-digest-first-release-latest-is-promotion.md):
**Push → Sign → Verify → Validate → Promote**, in that pinned order.

Read this when: a `secure-build` job fails after "Push immutable version
tag", or `latest` does not reflect an expected new release.

## User impact

Consumers pulling `ghcr.io/frostyard/<profile>:latest` (or `snow`, `cayo`,
`snowfield` images) either get a stale image or, if the failure is upstream
of promotion, no change at all. **No consumer can ever receive an unsigned
or unverified image under `latest`** — that is the invariant this pipeline
protects, and it is not the failure mode to remediate around.

## Step 1 — Identify where the pipeline stopped

Open the failing `secure-build` run and find the last completed step among:

1. `Push immutable version tag` — the 14-digit version tag was pushed;
   `latest` is untouched. **This is a safe, visible half-state.**
2. `Sign immutable image digest` — `cosign sign` failed against the pushed
   digest (never a tag). Check Cosign auth: it receives registry auth only
   through command-scoped `DOCKER_CONFIG`, not `--registry-config`.
3. `Verify pushed secure image` — remote verification
   (`shared/bootc-secure/ci/verify-published-image.sh`) failed: capability
   labels, tag→digest agreement, or `cosign verify` against the committed
   `cosign.pub` did not match.
4. `Validate policy-copied secure artifact` — the policy-gated `skopeo
   copy` succeeded but `test/bootc-secure-artifact-test.sh` rejected the
   copied bytes.
5. `Promote validated digest to latest` — `promote-published-image.sh`'s
   registry-to-registry `skopeo copy --all "$IMAGE@$DIGEST" "$IMAGE:latest"`
   failed, or the post-promotion re-inspect of `latest` did not resolve to
   the expected digest.

If the failure is at step 1–4, **do not manually push or retag `latest`.**
The version tag stays published; `latest` is only ever moved by step 5
succeeding. This is intentional per ADR-0008, not a bug to work around.

## Step 2 — Confirm the guard did not silently permit reordering

Run the static, network-free guard locally against the checked-out workflow:

```sh
./check-bootc-publication-guard.sh
```

It asserts the five named steps above appear exactly once each, in
monotonically increasing line order, in
`.github/workflows/build-images.yml`. If this fails, the workflow itself
was edited out of contract — fix the step order before re-running the
pipeline, don't just re-trigger it.

## Step 3 — Re-run vs. roll forward

- **Transient infra failure (registry timeout, runner OOM, disk space)**:
  re-run the failed job. The version tag is immutable and already correct;
  re-running only needs to get past the failed step.
- **Signing/verification/policy failure**: do not retry blindly. These
  steps fail closed by design (see
  [bootc-secure-operations.md](../docs/bootc-secure-operations.md#build-modes-and-publication)).
  Treat a verify/validate failure as a signal that credentials, the
  `cosign.pub`, or the containers policy diverged from what the image
  actually contains, and fix the divergence first.
- **`latest` did not move but the version tag looks correct**: this is the
  designed half-state, not an incident on its own. Consumers pinned to the
  version tag are unaffected; only `latest` consumers are behind. Re-run
  promotion once the root cause is fixed.

## Step 4 — Predecessor / release-notes gap (no incident, but visible)

If a release ships with empty/missing changelog notes, check whether
`shared/bootc-secure/ci/resolve-snow-release-predecessor.sh` skipped
(`skip=true`) because no prior release had a discoverable, cosign-signed
`application/vnd.syft+json` SBOM referrer. This is the fix for the
run-30627996880 incident (a failed-build, no-SBOM tag was previously picked
as predecessor by guessing from registry tag listings). An empty changelog
is the correct, safe outcome here — do not "fix" it by reintroducing tag
listing as a fallback; that reintroduces the original incident class.

## Step 5 — Escalate / close out

- If root cause is unclear after Steps 1–4, or the guard (Step 2) is
  green but the failure recurs across profiles (`cayo`, `snow`,
  `snowfield`), open an incident using
  [.github/ISSUE_TEMPLATE/incident_report.md](../.github/ISSUE_TEMPLATE/incident_report.md).
- Once resolved, write up a postmortem using
  [docs/postmortem-template.md](../docs/postmortem-template.md),
  referencing the ADR-0008 run-30627996880 postmortem as a format example.

## References

- [ADR-0008 — Publish by digest; `latest` is a promotion, never a push](../docs/adr/0008-digest-first-release-latest-is-promotion.md)
- [docs/bootc-secure-operations.md](../docs/bootc-secure-operations.md)
- `check-bootc-publication-guard.sh`
- `.github/workflows/build-images.yml` (`secure-build` job)
- `shared/bootc-secure/ci/verify-published-image.sh`
- `shared/bootc-secure/ci/promote-published-image.sh`
- `shared/bootc-secure/ci/resolve-snow-release-predecessor.sh`
