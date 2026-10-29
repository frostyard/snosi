# Plan: Scope the strict container policy to bootc updates

**Status:** Proposed — awaits Brian's choice of option; see [ADR-0025](../adr/0025-scope-strict-container-policy-to-bootc-updates.md)  
**Last verified:** 2026-10-29

The system `/etc/containers/policy.json` rejects every registry image except
five signed Frostyard repositories. It protects bootc updates, but it also
blocks ordinary root and service-account container work. This plan moves the
strict check onto the one fetch that stages updates, relaxes the system
default, and keeps Frostyard product repositories signature-checked for every
caller. It also records the diagnosis of the 2026-10-29 Floe `qa-controlled`
copy and a safe per-command workaround.

## Diagnosis: the Floe `qa-controlled` copy (T476a)

Command: `skopeo copy --all --preserve-digests --remove-signatures
docker://ghcr.io/frostyard/floe@sha256:bb1269a59a224e05b429776661b419f909d5d58d92c16048129410082d95d592
docker://ghcr.io/frostyard/floe:qa-controlled`.

Facts checked on Snow `20261029102309`, as an account with no
`~/.config/containers/policy.json` (so the strict system policy applied):

- The digest is a single OCI manifest (129 layers), not an index.
- `sha256-bb1269a5….sig` exists; its layer is a cosign simple-signing payload.
- `skopeo --debug copy` logs `Using transport "docker" specific policy section
  "ghcr.io/frostyard/floe"` then `Requirement 0: allowed`. The signature is
  valid with `/usr/lib/snosi/cosign.pub`. A bootc update to this digest is not
  at risk.
- Policy applies to the **source only**; the destination tag is never checked.
- A non-Frostyard source (`quay.io/libpod/alpine`) is rejected on the same
  account. Root reads the same file (when it has no dotfile), so it gets the
  same results.

So the exact command passes on a current host. A rejection means one of:

| Cause | Sign | Fix |
| --- | --- | --- |
| A drifted `/etc/containers/policy.json` (3-way merge keeps a local edit) or a host image older than the Floe scope (#926, 2026-09-06) | `sudo ostree admin config-diff` lists `containers/policy.json`; error "is rejected by policy" | restore the image's file |
| `~/.config/containers/registries.d` exists: it **replaces** `/etc/containers/registries.d`, so sigstore attachments are not read | "A signature was required, but no signature exists" | `--registries.d /etc/containers/registries.d` |
| Another source than the one above (a non-Frostyard image, a `-wrong` repo) | "is rejected by policy" | correct the source |

The exact error text, user and host settle it; it was requested from Brian
through Odrade.

### Safe per-command workaround

Both forms change nothing on the system.

Keep the signature check, ignore user dotfiles (preferred):

```sh
skopeo --policy /etc/containers/policy.json \
  --registries.d /etc/containers/registries.d \
  copy --all --preserve-digests --remove-signatures \
  docker://ghcr.io/frostyard/floe@sha256:bb1269a5… \
  docker://ghcr.io/frostyard/floe:qa-controlled
```

If it still fails, the error is the real cause; do not go on with the second
form until it is understood. To skip the check for one command (the digest
was verified above):

```sh
skopeo --policy /usr/share/snosi/containers/user-policy.json copy …
```

`--remove-signatures` is harmless here: cosign stores the signature by digest
(`sha256-<digest>.sig`), and `--preserve-digests` keeps the digest, so
`qa-controlled` resolves to an already-signed manifest.

## Threats and options

| Threat | Kept out today | A: recommended (ADR-0025) | B: keep reject, document flags | C: A + `ghcr.io/frostyard` namespace reject |
| --- | --- | --- | --- | --- |
| T1 Forged image pushed to a Frostyard repo (GHCR or token compromise) reaches an automatic update | yes | yes (stager uses `/usr` policy) | yes | yes |
| T2 Same, by a manual `bootc switch`/`upgrade` to a Frostyard repo | yes | yes (scopes stay signed) | yes | yes |
| T3 Manual `bootc switch` to a foreign registry image | yes (policy) | stager refuses updates from it; Secure Boot expected to refuse its UKI (Phase 4 proof) | yes | foreign: as A; namespace lookalikes: yes |
| T4 Root dotfile or `/etc` drift weakens update policy | **no** | yes | no | yes |
| Normal root/service-account use | **blocked** | works | blocked unless every command adds a flag | works, except other `ghcr.io/frostyard/*` images |

Firn is outside all three: it verifies with `cosign verify --key` and pins the
digest before install, and never reads the target's policy.

## Phase 1 — Update policy in `/usr` (small)

- Add `shared/bootc-secure/tree/usr/lib/snosi/containers/bootc-policy.json`,
  equal to today's `/etc/containers/policy.json`.
- `mkosi.images/base/mkosi.extra/usr/libexec/bootc-update-stage`: pull with
  `podman pull --signature-policy /usr/lib/snosi/containers/bootc-policy.json`
  (overridable for tests only through an env variable, as `SNOSI_RUN_DIR`).
- Schema-1 `oci.policy` → the new path;
  `test/bootc-secure-install-contract-test.sh` follows.
- `test/bootc-container-policy-test.sh`:
  - run the existing strict assertions (`default` reject, exact scopes,
    `sigstoreSigned` only, no catch-all, local transports) against
    `bootc-policy.json`;
  - new: the stager passes `--signature-policy` with that path (static check,
    and the podman stub in `run_updater_fixture` fails a pull without it);
  - keep the `podman pull --policy` ban (that flag is the pull policy);
  - `verify_vm_registry_policy` derives the VM policy from `bootc-policy.json`.
- **Done when:** `validate.yml` is green and a lab update run stages a signed
  Snow digest through the new flag.

## Phase 2 — Relax the system default (small; only after Phase 1 is on `latest`)

- `/etc/containers/policy.json`: `default` → `insecureAcceptAnything`; keep
  the five `sigstoreSigned` scopes and the local-transport entries.
- `test/bootc-container-policy-test.sh`:
  - replace "unlisted images are rejected" and "the default policy is still
    reject" (system file) with "the system default accepts workload images";
  - keep "valid … signatures are accepted", "every docker scope is still
    sigstoreSigned" and "no catch-all docker scope" for the system file;
  - new: `transports.docker` of both files is equal;
  - `RUN_LIVE=1`: an arbitrary image pulls under the system policy and is
    rejected under `bootc-policy.json`; the signed product image passes both;
    the wrong-key and wrong-identity cases run against `bootc-policy.json`.
- Docs: `bootc-secure-install-contract.md` (rootless paragraph and "OCI
  Acceptance"), `bootc-secure-operations.md` (Trust Boundaries), AGENTS.md.
- **Done when:** on a fresh Floe, `sudo podman pull quay.io/libpod/alpine`
  works and `bootc-update-stage` still rejects an unsigned image.

## Phase 3 — Retire rootless provisioning (optional)

- With a permissive system default, `user-tmpfiles.d/snosi-containers-policy.conf`
  is redundant. Remove the `C`/`d` lines; keep
  `/usr/share/snosi/containers/user-policy.json` for the workaround above.
  Existing user copies stay and stay harmless.
- **Done when:** the test drops the two provisioning checks and nothing else
  references the tmpfiles file.

## Phase 4 — Prove the T3 claim before ADR-0025 is Accepted

- Lab: on a Secure Boot VM, `bootc switch` to an image built from the same
  tree but without the MOK-signed UKI. Expect a refused boot and an automatic
  return to the previous deployment, or record what happens.
- **Done when:** the lab run is recorded; ADR-0025 cites it or is revised.

## Open questions

- **Namespace scope (option C):** do any root workloads pull other
  `ghcr.io/frostyard/*` images? Decide by Phase 2.
- **Registries.d override for the stager:** the stager runs as root. A
  `/root/.config/containers/registries.d` would hide the sigstore attachments
  and fail updates closed: safe, but noisy. Podman has no flag for the
  registries.d path (`--registries-conf` is a different file). Decide by
  Phase 1 whether the fail-closed result is enough.

## References

- Implements: [ADR-0025](../adr/0025-scope-strict-container-policy-to-bootc-updates.md)
- Touches: [bootc-secure-install-contract.md](../bootc-secure-install-contract.md),
  [bootc-secure-operations.md](../bootc-secure-operations.md)
