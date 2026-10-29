# 0025 — Scope the strict container policy to bootc updates

- **Status:** Proposed
- **Date:** 2026-10-29

## Context

Every OCI profile ships `shared/bootc-secure/tree/etc/containers/policy.json`.
It has `default: reject` and accepts registry pulls only from five exact GHCR
repositories (`ghcr.io/frostyard/{cayo,floe,snow,snowfield,sundog}`), each
`sigstoreSigned` with `/usr/lib/snosi/cosign.pub` and `matchRepository`.
Local transports (`containers-storage`, `dir`, `oci`, archives) accept
anything. `registries.d/frostyard.yaml` turns on sigstore attachments for
`ghcr.io`.

That file has one job: an automatic or operator bootc update must not stage an
image that Frostyard did not sign. But containers/image gives one policy to
every process. It reads `$HOME/.config/containers/policy.json` if it exists,
else `/etc/containers/policy.json` (containers-policy.json(5)). So the strict
file also governs:

- root `podman`, `skopeo` and `buildah`, which includes rootful quadlets on
  Floe, a server product;
- every account that never starts a systemd user manager (service accounts,
  `su`, lingering-less automation). The permissive rootless policy
  (`usr/lib/user-tmpfiles.d/snosi-containers-policy.conf`, `C`) arrives only
  when user tmpfiles runs.

Observed on Snow `20261029102309`: an account with no user policy cannot pull
`quay.io/libpod/alpine` ("rejected by policy"). The same account copies
`ghcr.io/frostyard/floe@sha256:bb1269a5…` because that digest carries a valid
signature. Brian's rule: the system policy exists for bootc update security
and must not block normal use.

The trusted fetch seams are narrow:

- `bootc-update-stage` pulls with `podman pull "$image"` and stages with
  `bootc switch --transport containers-storage`. bootc then reads only local
  storage, which the policy accepts. The podman pull is the real gate.
- Firn verifies the digest with `cosign verify --key` itself and installs from
  the installer's storage; it does not consume schema-1 `oci.policy`
  (checked at firn `9968f2b`).
- A manual `bootc switch REGISTRY-REF` or `bootc upgrade` on a `registry`
  transport spec uses bootc's skopeo proxy, which reads the default policy
  path. bootc 1.17.1 has no option to give that proxy another policy file.

Podman 5.4.2 (Trixie) honors `podman pull --signature-policy FILE` (hidden
flag; checked on Snow). That path ignores `$HOME/.config/containers/policy.json`
and `/etc`.

## Decision

1. Snosi ships the strict policy a second time as
   `/usr/lib/snosi/containers/bootc-policy.json`: `default: reject`, the same
   five `sigstoreSigned` scopes, and the same local-transport entries. It sits
   in immutable `/usr`, so `/etc` drift and root dotfiles cannot weaken it.
2. `bootc-update-stage` pulls with
   `podman pull --signature-policy /usr/lib/snosi/containers/bootc-policy.json`.
   Automatic updates accept only signed Frostyard images, from any spec.
3. `/etc/containers/policy.json` changes its `default` to
   `insecureAcceptAnything` and keeps the five Frostyard `sigstoreSigned`
   scopes. Any tool, any user, that pulls a Frostyard product repository by
   name still verifies its signature. Other images pull as on stock Debian.
4. Schema-1 `oci.policy` names `/usr/lib/snosi/containers/bootc-policy.json`.
   The schema number does not change: no consumer reads the field.
5. A static test keeps the `transports.docker` blocks of both files equal.

## Consequences

- Root and service accounts can pull, copy and run ordinary images. Floe
  quadlets work without per-unit flags.
- Automatic updates gain a guard they lacked: a root
  `~/.config/containers/policy.json` or a 3-way-merged `/etc` edit no longer
  replaces the update policy.
- A manual `bootc switch` to a non-Frostyard registry image is no longer
  refused by policy. What still stands in its way: (a) the stager refuses to
  auto-update from it; (b) under Secure Boot its UKI is not signed by the
  enrolled MOK, so it is expected not to boot. (b) is expected, not proven;
  the plan adds a lab proof before this ADR is Accepted. After such a switch
  the stager's pull fails on every run and records `outcome=failed`, which
  the motd and `snosi-update-status` show: loud, not silent.
- A lookalike repository (`ghcr.io/frostyard/snow-x`, `ghcr.io/frost-yard/snow`)
  is not covered by a scope, so manual pulls of it are unverified. The stager
  still refuses it.
- Two policy files must stay in step. The equality test enforces it.
- `docs/bootc-secure-install-contract.md` and
  `docs/bootc-secure-operations.md` change their trust-boundary text.

## Alternatives considered

- **Keep `default: reject`, document flags:** keeps manual `bootc switch`
  refused, but root and service accounts must add `--policy` or
  `--signature-policy` to every pull, and quadlets need `PodmanArgs=`. It
  breaks normal use, against Brian's rule.
- **A bootc-only policy path:** not supported. bootc 1.17.1 starts its skopeo
  proxy with the default policy search path and exposes no flag; skopeo has no
  policy environment variable. Snosi already routes updates through podman, so
  the stager seam gives the same effect.
- **Divert `/usr/bin/bootc` to a wrapper that verifies first:** fragile
  machinery on the most critical path; a package update can undo a diversion
  and the wrapper must track bootc's CLI. Rejected.
- **Add a `ghcr.io/frostyard` namespace `reject` scope:** blocks lookalikes
  inside the namespace, but also blocks root pulls of other Frostyard
  containers. Left open in the plan.
- **Install the rootless policy for root too:** root's dotfile would also
  replace the update policy for bootc and the stager. Rejected.

## References

- Shapes: [plans/2026-10-29-container-policy-scope-plan.md](../plans/2026-10-29-container-policy-scope-plan.md),
  [bootc-secure-install-contract.md](../bootc-secure-install-contract.md),
  [bootc-secure-operations.md](../bootc-secure-operations.md)
- Builds on: [secure bootc platform plan](../superpowers/plans/2026-07-28-bootc-secure-platform.md),
  the rootless split of #872 (`4eed2cd`)
