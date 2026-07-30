# Bootc Secure Artifact Validator Prerequisites Design

## Problem

Protected build run `30551607539` proved that the corrected MOK certificate
secret passes credential materialization for `cayo`, `snow`, and `snowfield`.
All three profiles then packaged their secure OCI candidate and failed at the
same local artifact-validation boundary with `BLOCKED: missing bootc`.

`test/bootc-secure-artifact-test.sh` requires a host `bootc` executable before
calling `shared/bootc-secure/assemble-uki.sh --validate`. The validator does not
use that executable. It computes the storage composefs digest by invoking the
candidate image through Podman and running the image's pinned bootc 1.16.3:

```text
podman run ... IMAGE bootc container compute-composefs-digest-from-storage IMAGE
```

The hosted runner intentionally has Podman but no independently installed host
bootc. The wrapper therefore blocks a valid validation path on an unused tool.

## Scope

Correct only the live artifact validator's host prerequisite contract. Do not
change UKI assembly, digest computation, candidate labels, signing credentials,
registry publication, promotion ordering, or the pinned bootc compatibility
contract.

## Design

Replace `bootc` with `podman` in the command prerequisites checked by
`test/bootc-secure-artifact-test.sh`. Keep the remaining prerequisites and the
call to `assemble-uki.sh --validate` unchanged.

The candidate image remains the sole bootc runtime for storage-digest
validation. This avoids adding an unpinned host bootc package and ensures the
validator exercises the same bootc version packaged in the artifact under
review.

Add regression coverage that asserts the live validator requires `podman` and
does not require host `bootc`. The test must fail against the current wrapper
and pass after the prerequisite correction.

## Documentation

Update `CLAUDE.md`, `README.md`, and `yeti/ci-cd.md` to record the dependency
boundary: protected local and policy-copied artifact validation use Podman to
execute bootc from the candidate image. A host bootc executable is neither
required nor an acceptable substitute for that pinned image runtime.

## Verification

Run the secure artifact fixtures, the new prerequisite regression, the bootc
publication guard, ShellCheck for the modified shell files, and actionlint for
`build-images.yml`. After review and merge, dispatch `build-images.yml` from
`main` and require all three protected profiles to pass local artifact
validation before any immutable push, then continue through signing, remote
verification, policy-copied validation, and `latest` promotion.

The rerun creates production registry state if it succeeds. A failed local
validation must continue to prevent all registry writes.
