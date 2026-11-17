# 0042 — Switch the bootc stream with snosi-stream

- **Status:** Accepted
- **Date:** 2026-11-16

## Context

Each bootc product has 2 streams: `ghcr.io/frostyard/<product>:latest`
(trixie) and `ghcr.io/frostyard/<product>:forky` (forky,
[ADR-0037](0037-build-forky-as-a-second-suite.md),
[ADR-0040](0040-move-the-forky-tag-to-a-verified-forky-image-by-dispatch.md)).
Until now a user moved between them with a 3-command chain from
[installing](../installing.md#try-the-next-debian-release-forky). That chain
took 3 review rounds to get right
(`.memory/corrections/2026-11-15-pr-1312-forky-switch-commands.json`):

- bootc's registry-transport composefs pull fails on snosi images, and a
  direct registry `bootc switch` reads the system container policy, which
  root overrides can replace
  ([ADR-0025](0025-scope-strict-container-policy-to-bootc-updates.md)). The
  pull must be `podman pull --signature-policy
  /usr/lib/snosi/containers/bootc-policy.json`, then `bootc switch
  --transport containers-storage`, as `bootc-update-stage` does.
- Separate shell lines go on after a failed pull or switch.
- bootc refuses a switch to an image with the same fs-verity digest as the
  rollback deployment, so the way back to trixie is `bootc rollback` while
  the trixie image is still the rollback deployment.

`test/docs-bootc-switch-test.py` now keeps the documented chain correct, but
every user still types it by hand, and the chain does not do what the stager
does after its pull: check that the local tag still names the verified
image, stage the deployment locked, check its digest, and only then unlock
it. The stager also holds `/run/snosi/update-stage.lock`; a hand-typed
switch that runs while the hourly stager runs can leave a deployment locked
(download-only), and a locked deployment never applies.

## Decision

Base ships the root command `/usr/bin/snosi-stream`. It is the supported way
to move a bootc machine between the 2 streams of its own product. The
manual chain stays in the docs as the fallback.

- `snosi-stream` with no argument prints the product, the followed image
  reference and its transport, the stream (`trixie` for `:latest`, `forky`
  for `:forky`, `other` for any other reference), and the booted, staged and
  rollback deployments (reference, version, digest). It changes nothing.
- `snosi-stream forky|trixie [--reboot]` switches. `--reboot` runs
  `systemctl reboot` only after a successful switch or rollback; without it,
  the command prints the reboot step. Any other argument is a usage error.
- It runs only as root, like `snosi-update-status`.
- The product is `IMAGE_ID` from `/usr/lib/os-release` of the booted image.
  Only `snow`, `snowfield`, `floe` and `sundog` are accepted. The target is
  always `ghcr.io/frostyard/<IMAGE_ID>:latest` or `:forky`; the command takes
  no image reference from the user, so it cannot switch to another product
  or another registry.
- It refuses a system that is not bootc-managed (no `bootc`, a failed
  `bootc status`, or no `.spec.image.image`), and a system with a queued
  rollback (`.status.rollbackQueued`): the next boot already changes the
  deployment, so the user must reboot or undo that first.
- If the followed reference (any transport) is already the target, it prints
  so and exits 0. It does not reboot in that case, also with `--reboot`. A
  deployment staged for the target that is still download-only is locked, so
  it never applies (an interrupted switch leaves exactly that state): instead
  of reporting a pending update, the command says the staged deployment is
  locked, names the repair, `sudo systemctl start
  bootc-update-stage.service` (whose already-staged branch verifies the staged
  digest and unlocks it), and exits 1 without pulling or staging.
- It takes `/run/snosi/update-stage.lock`, the lock of `bootc-update-stage`,
  and waits for a running stager run (30 minutes at most, then it fails).
  So the 2 never stage at the same time.
- The fetch is the stager's: `podman image prune -f`, then `podman pull
  --quiet --signature-policy /usr/lib/snosi/containers/bootc-policy.json`
  with the policy path as a literal in immutable `/usr` and no environment
  override. The pull must print a valid image ID, and that ID must have a
  valid registry manifest digest. The command stops at the first failure: a
  failed pull never falls back to an older local copy, and nothing is staged.
- If the pulled digest is the rollback deployment's digest and the rollback
  deployment's reference is the target, the command runs `bootc rollback`
  instead of a switch (bootc refuses that switch). If the digest matches but
  the rollback reference is another one, it refuses: a rollback would leave
  the machine on a reference that is not the stream.
- Otherwise it stages as the stager does: the local tag must still name the
  pulled image ID, then `bootc switch --quiet --download-only --transport
  containers-storage <target>`; the staged digest must be the pulled digest
  and the deployment must be download-only; then `bootc upgrade --quiet
  --from-downloaded`, after which the staged digest must still be the pulled
  digest and the deployment must not be download-only.
- `test/snosi-stream-test.sh` drives the command with PATH stubs for
  `bootc`, `podman` and `systemctl`, and a fixture os-release behind a PAIRED
  test hook ([ADR-0009](0009-snosi-env-var-classes.md) class 3):
  `SNOSI_STREAM_TEST_HOOKS=1` is refused without `SNOSI_STREAM_OS_RELEASE`,
  and any hooks value other than `0` or `1` is refused. Only the pair lifts
  the root check; it moves the os-release path (`SNOSI_STREAM_OS_RELEASE`) and
  lets the lock fixture shorten the lock wait (`SNOSI_STREAM_LOCK_WAIT`). It
  cannot change the policy path or the image reference, and without the hooks
  value every one of those variables is inert.
- `.github/risk-paths.json` lists `**/usr/bin/snosi-stream` at L1
  (update-verification): the command pulls and stages the OS image.

## Consequences

- The safe path is the only path a user types: 1 command, no chain to
  mistype, the same strict policy and the same lock-check-unlock staging as
  automatic updates, and no switch while the stager runs.
- After a switch, `bootc-update-stage.timer` follows the new tag. The runtime
  files `/run/snosi/update-staged` and `update-check` keep the state of the
  last stager run until its next run (at most 1 hour); that run's
  already-staged branch rewrites them and publishes the staged-package
  sidecar ([ADR-0014](0014-update-status-pkg-diff.md)). `snosi-stream`
  writes neither file.
- The rollback branch returns to the older trixie deployment with that
  deployment's own `/etc`; the stager then stages the newest `:latest` image
  as usual. A switch carries the current `/etc` into the new deployment.
- The command needs the network also for the rollback branch, because it
  decides by the digest of the verified pull, which is the same test bootc
  applies. An offline machine can still run `bootc rollback` by hand.
- The command depends on the bootc status JSON fields that the stager
  already reads (`spec.image`, `status.{booted,staged,rollback}.image`,
  `imageDigest`, `downloadOnly`) and on `rollbackQueued`. A bootc change to
  them must update both scripts and their tests.
- The command adds 1 privileged path. Its L1 entry gives a change to it
  `risk:high`, and the stub test runs in `make verify` and `validate.yml`.

## Alternatives considered

- **Keep only the documented chain:** every user keeps typing a chain that
  needed 3 review rounds, and it has no lock, no tag check and no locked
  staging.
- **A plain `bootc switch` from the registry:** it fails on snosi images and
  reads the replaceable system policy (ADR-0025).
- **Accept any image reference:** a typo or a foreign registry would switch
  the OS to an image the product does not publish. The strict policy still
  rejects unsigned images, but 2 fixed streams of the booted product are all
  the use case needs.
- **Decide the rollback branch by reference alone, with no pull:** it works
  offline, but a rollback reference that matches the target with an older
  digest would boot an old image when a plain switch to the newest image
  works. The digest test matches the case bootc refuses.
- **Write the stager's runtime files after a switch:** it duplicates the
  stager's sidecar and semaphore logic in a second script; the next stager
  run repairs them within the hour.

## References

- Shapes: [installing](../installing.md#try-the-next-debian-release-forky),
  [design/testing.md](../design/testing.md)
- Builds on: [ADR-0014](0014-update-status-pkg-diff.md),
  [ADR-0025](0025-scope-strict-container-policy-to-bootc-updates.md),
  [ADR-0037](0037-build-forky-as-a-second-suite.md),
  [ADR-0040](0040-move-the-forky-tag-to-a-verified-forky-image-by-dispatch.md)
