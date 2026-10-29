# Plan: Scope the strict container policy to bootc updates

**Status:** Phases 1-2 implemented — Brian chose option A on 2026-10-29 (desk
T478b); see [ADR-0025](../adr/0025-scope-strict-container-policy-to-bootc-updates.md).
Both phases landed in one change. One image ships both, and the previous
image's stager stages the update under its own strict policy, so no window
exists between them.  
**Last verified:** 2026-10-29 (lab proof)

Before this plan, the system `/etc/containers/policy.json` rejected every
registry image except five signed Frostyard repositories. That protected bootc
updates, but it also blocked ordinary root and service-account container work.
This plan moves the strict check onto the one fetch that stages updates,
relaxes the system default, and keeps Frostyard product repositories
signature-checked for every caller. It also records the diagnosis of the
2026-10-29 Floe `qa-controlled` copy and a safe per-command workaround.

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

So the exact source passes the current signature policy on a current host.
This does not prove the push: write access to `floe:qa-controlled` is a
separate registry permission, and its failure is not a policy rejection.
A policy rejection means one of:

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

| Threat | Kept out today | A: chosen (ADR-0025) | B: keep reject, document flags | C: A + `ghcr.io/frostyard` namespace reject |
| --- | --- | --- | --- | --- |
| T1 Forged image pushed to a Frostyard repo (GHCR or token compromise) reaches an automatic update | yes | yes (stager uses `/usr` policy) | yes | yes |
| T2 Same, by a manual `bootc switch`/`upgrade` to a Frostyard repo | yes | yes (scopes stay signed) | yes | yes |
| T3 Manual `bootc switch` to a foreign registry image | yes (policy) | stager refuses updates from it; Secure Boot expected to refuse its UKI (Phase 4 proof) | yes | foreign: as A; namespace lookalikes: yes |
| T4a Root dotfile or `/etc` drift weakens the automatic update policy | **no** | yes | no | yes |
| T4b Same, for manual registry operations (`bootc switch`, root `podman pull`) | **no** | no | no | no |
| Normal root/service-account use | **blocked** | works | blocked unless every command adds a flag | works, except other `ghcr.io/frostyard/*` images |

Firn is outside all three: it verifies with `cosign verify --key` and pins the
digest before install, and never reads the target's policy.

## Phase 1 — Update policy in `/usr` (small)

- Add `shared/bootc-secure/tree/usr/lib/snosi/containers/bootc-policy.json`,
  equal to today's `/etc/containers/policy.json`.
- `mkosi.images/base/mkosi.extra/usr/libexec/bootc-update-stage`: pull with
  `podman pull --signature-policy /usr/lib/snosi/containers/bootc-policy.json`,
  from a literal `readonly BOOTC_POLICY=` with no environment override: the
  path is in immutable `/usr`.
- Schema-1 `oci.policy` → the new path;
  `test/bootc-secure-install-contract-test.sh` follows.
- `test/bootc-container-policy-test.sh`:
  - run the existing strict assertions (`default` reject, exact scopes,
    `sigstoreSigned` only, no catch-all, local transports) against
    `bootc-policy.json`;
  - new: the stager passes `--signature-policy` with that path. Keep a
    static check, and also record the `podman pull` arguments in the stub of
    `run_updater_digest_fixture` (a successful staging run) and assert the
    flag and path there; a failing stub alone cannot prove the flag;
  - keep the `podman pull --policy` ban (that flag is the pull policy);
  - `verify_vm_registry_policy` derives the VM policy from `bootc-policy.json`.
- **Done when:** `validate.yml` is green and a lab update run stages a signed
  Snow digest through the new flag. Status: implemented, and met before the
  merge by the lab proof below (Brian chose "lab proof first", desk T481a).

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
  works and `bootc-update-stage` still rejects an unsigned image. Status:
  implemented. The lab proof below ran the alpine pull and the stager on a
  fresh Floe install of a signed image with the #1181 files in a transient
  `/usr` overlay; a fresh Floe built from `main` after the merge remains to
  be seen.

## Lab proof before the merge (2026-10-29, desk T481a)

A signed image can only come from `build-images.yml` on `main`, so the proof
has two parts. Both ran as dev Workflows on minideb under lease `lab-dev`.

**Secure path, the #1181 stager on signed images (PASS).** The Firn
installer ISO `snosi-installer_20261029172115` (SHA256SUMS signature valid
for `F37282A3…8216FD68`) installed a signed image N with Secure Boot on,
following the immutable version tag of a signed N+1. The run then put the
stager and both policy files of PR head `4f9d82c` (sha256 equal to the PR
files) into a `bootc usr-overlay`, and judged every step:

| Run | N → N+1 | Result |
| --- | --- | --- |
| `dev-pr1181-secure-snow-k2vcf` | Snow `20261029023049` → `20261029102309` (`sha256:52bde2f1…`) | PASS |
| `dev-pr1181-secure-floe-5hhlw` | Floe `20261028230726` → `20261029102316` (`sha256:d8ab1ea6…`) | PASS |

In both runs, on bootc 1.17.1 with Secure Boot enabled:
- the strict policy rejects by default and the system policy accepts by
  default; `podman pull quay.io/libpod/alpine` works as root under the system
  policy and is rejected under `bootc-policy.json`;
- with the run lock held, a stager run exits 0 and writes no check result;
- stager run 1 staged N+1 locked (`--download-only`), verified the digest and
  unlocked it: `outcome=staged`, staged digest = N+1, `downloadOnly=false`;
  the bootc journal shows the download-only and from-downloaded operations;
- stager run 2 reported the update as already staged;
- after a reboot, N+1 booted under Secure Boot, the rollback slot held N, and
  no unit failed.

**Image path, mechanics images built from the #1181 head.** The throwaway
branch `murbella/pr1181-lab-proof-build` (PR head plus 1 workflow commit,
never merged) published unsigned QA images `snow:mechanics-pr1181-20261029173103`
and `floe:mechanics-pr1181-20261029173015`; the `mechanics` alias did not
move. Runs `dev-pr1181-update-snow-x7lg8` and `-7hv88` installed the Snow one
with `bootc install to-disk --target-imgref` the signed N+1, and proved the
image's own files: the strict policy in `/usr`, the permissive `/etc`
default, the alpine accept and reject, the strict rejection of the unsigned
image, the run lock, and the strict pull of the signed N+1. bootc then
refused to stage a secure N+1 onto a mechanics install (`Conflicting boot
types`; without `--allow-missing-verity`, a fs-verity mismatch). That is the
mechanics-versus-secure tier limit, not a stager result, so those runs do
not judge the stage.

**Limits.** No signed image built from #1181 exists before the merge; the
secure runs prove the PR's stager and policies on signed images with bootc
1.17.1, not the PR's image build. A tag that moves during staging and two
overlapping stagers are proven by the fixtures in
`test/bootc-container-policy-test.sh`, not in the lab.

## Phase 3 — Retire rootless provisioning (optional)

- With a permissive system default, `user-tmpfiles.d/snosi-containers-policy.conf`
  is redundant. Remove the `C`/`d` lines; keep
  `/usr/share/snosi/containers/user-policy.json` for the workaround above.
  Existing user copies stay. For those users the copy still replaces the
  system file, so their manual pulls of Frostyard repositories stay
  unverified, as today; the stager does not depend on them.
- **Done when:** the test drops the two provisioning checks and nothing else
  references the tmpfiles file.

## Phase 4 — Prove the T3 claim before ADR-0025 is Accepted

- Lab: on a Secure Boot VM, `bootc switch` to an image built from the same
  tree but without the MOK-signed UKI. Expect a refused boot and an automatic
  return to the previous deployment, or record what happens.
- **Done when:** the lab run is recorded; ADR-0025 cites it or is revised.

## Open questions

None open; the question below is decided.

- **Registries.d override for the stager:** decided 2026-10-29. The stager runs
  as root, so a `/root/.config/containers/registries.d` would hide the sigstore
  attachments and fail updates closed. Podman has no flag for the registries.d
  path (`--registries-conf` is a different file). Fail closed is enough: the
  pull fails, `outcome=failed` is recorded on every run, and the motd and
  `snosi-update-status` show it. A visible failure that stages nothing is the
  safe result, so no further mechanism is added.

## References

- Implements: [ADR-0025](../adr/0025-scope-strict-container-policy-to-bootc-updates.md)
- Touches: [bootc-secure-install-contract.md](../bootc-secure-install-contract.md),
  [bootc-secure-operations.md](../bootc-secure-operations.md)
