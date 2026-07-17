# Native A/B Publication Runbook

Operational procedure for publishing native A/B (`cayo-ab`, `snow-ab`,
`snowfield-ab`) images to production. This is the human-facing companion to
`docs/native-ab-contracts.md` (frozen names/paths/policy) and the plan's
"Atomic Publication Procedure" / "R2 Publication Contract" / "R2 Retention
And Cost Control" / "Build And Signing Key Custody" sections. Read those
first for the *why*; this document is the *how*.

The pipeline scripts live in `shared/native-ab/publish/`:

| Script | Purpose |
|---|---|
| `prepare-native-publication.sh` | Turns one mkosi build's outputs into the frozen public artifact names + unsigned `SHA256SUMS` + `publication-info.json`. Phase 3. |
| `prepare-iso-publication.sh` | Sibling of the above for the network-installer ISO (Task 8.2): stages `shared/native-installer/tools/build-iso.sh`'s already-version-stamped-and-named output plus an unsigned `SHA256SUMS` + `publication-info.json` whose `dest_path` is the flat `isos/native/v1` namespace (no per-product/x86-64 subpath). |
| `generate-sbom.sh` | Generates `<channel>_<version>.sbom.spdx.json` directly from the mkosi package manifest. Called by `prepare-native-publication.sh`; not normally invoked standalone. |
| `publish-candidate.sh` | Uploads immutable versioned objects to a per-version candidate staging path. |
| `verify-remote.sh` | Independently re-verifies every candidate object over HTTP (size, full SHA-256, range GETs) before anything is promoted. |
| `promote.sh` | Copies verified candidates to their final public names, regenerates and signs `SHA256SUMS`, publishes signature-first/manifest-last. |
| `withdraw.sh` | Restores a previously-archived signed index pair (incident response / bad-release rollback of the *index*, not the bits). |
| `verify-installer-redirect.sh` | Confirms the stable installer URL redirects without caching to the expected promoted ISO and that the target is present in `SHA256SUMS`. Run only after `verify-published-index.sh` has authenticated that index. |

All five scripts have `--help`, are `set -euo pipefail`, and are shellcheck
(`-S warning -x`) clean. `shared/native-ab/publish/publish-lib.sh` is a
shared library, not a standalone script.

## Destination addressing

Every pipeline script (except `prepare-native-publication.sh`, which never
touches the network) takes a `dest` argument, in one of two forms:

```text
/local/directory                    -- a plain local path (rehearsal)
rclone:<remote>:<bucket>[/prefix]   -- a real rclone remote
```

Everything after the literal `rclone:` prefix is passed to `rclone` verbatim
as its own destination argument. The scripts always append the frozen
`os/native/v1/<product>/x86-64/` path themselves (`docs/native-ab-
contracts.md` §5), so `dest` is always the bucket/origin *root* -- for the
real Frostyard R2 bucket behind `repository.frostyard.org`, configure an
rclone remote (this document uses the illustrative name `r2`, matching how
`rclone` remotes for Cloudflare R2 are conventionally named; substitute
whatever name your own `rclone.conf` actually uses) pointed at that bucket,
then pass `rclone:r2:<bucket-name>` as `dest`. Nothing in the scripts
hardcodes a bucket name, credential, or remote name -- that is entirely
local `rclone` configuration (`rclone config`), scoped per `docs/native-ab-
contracts.md` §7's R2 credential row: upload authorization only, never a
substitute for the OpenPGP signature.

`verify-remote.sh` and `promote.sh` additionally take a `base-url`: the
HTTP(S) URL of the product's `os/native/v1/<product>/x86-64` directory (the
public read path, e.g. `https://repository.frostyard.org/os/native/v1/cayo/
x86-64` in production, or a local rehearsal origin's equivalent path). This
is deliberately separate from `dest` (the write path): candidate/promote
writes go through the storage API (`rclone`), but verification and the
signed-`SHA256SUMS` regeneration read back over the same HTTP path a real
client (or `curl`) would use, per the plan's "verifies remote size, SHA-256,
full GET" and "Generate SHA256SUMS over the exact bytes served" steps. For a
brand-new promotion the candidate/final HTTP path becomes reachable as soon
as the `rclone copyto` in `publish-candidate.sh`/`promote.sh` completes --
no separate publish step needed on the R2 side.

## Production key ceremony

**Do this BEFORE the first real production publication. Never reuse or
extend the committed DEV key for anything published to
`repository.frostyard.org`.**

1. Generate the production OpenPGP update-signing key **offline**, on a
   machine that never touches the build/CI pipeline:

   ```console
   $ gpg --homedir /path/to/offline/gnupghome --batch --passphrase '<a real passphrase>' \
       --quick-generate-key 'snosi native OS updates <os-updates@frostyard.org>' ed25519 sign 0
   ```

   Use a real passphrase (unlike the DEV key) and store it per your
   organization's secret-custody procedure -- it is needed only to *use* the
   key, which per `docs/native-ab-contracts.md` §7 happens only inside "the
   protected promotion environment", never on a general build runner.

2. Export the **public** half and replace the committed DEV pubring:

   ```console
   $ gpg --homedir /path/to/offline/gnupghome --batch --export \
       > shared/native-ab/keys/import-pubring.gpg
   ```

   During the overlap window (§7 "OpenPGP update key" rotation: "both old
   and new public keys ship in the shipped pubring simultaneously until
   every supported client has fetched an index signed by the new key"),
   `import-pubring.gpg` is a multi-key keyring: export both the outgoing and
   incoming public keys into the same file (`gpg --export key1 key2 > ...`)
   rather than overwriting outright, until every supported client has booted
   an image carrying the new pubring AND fetched at least one index signed
   with the new key.

3. Update `shared/native-ab/keys/README.md` to describe the production key
   (fingerprint, custody location, rotation date) instead of the DEV key,
   and rebuild every native profile so the new pubring ships in
   `/usr/lib/systemd/import-pubring.gpg`.

4. The **private** half never leaves the offline/protected environment and
   is never committed, never an Actions artifact, and never mounted while
   general repository build scripts execute (`docs/native-ab-contracts.md`
   §7 "Protected signing architecture" / "Build And Signing Key Custody" in
   the plan). See "Interim protected-builder constraints" below for what is
   acceptable until a dedicated signer exists.

5. Publish a test candidate through the full pipeline below against a
   **non-production** R2 prefix first (e.g. `rclone:r2:<bucket>/staging-
   test`) and verify a disposable VM can install and verify it end to end
   before pointing any real transfer at production.

## Candidate -> verify -> promote -> purge procedure (production)

Given a fresh build's mkosi output directory `output/` and profile
`cayo-ab` (real production profile names only -- `prepare-native-
publication.sh` refuses `cayo-ab-raw` and anything else not literally
`<ImageId>-ab`):

```console
# 1-4: build, name, compress, locally verify (plan steps 1-4)
$ shared/native-ab/publish/prepare-native-publication.sh --xz \
    output cayo-ab /var/tmp/publish-out
# -> /var/tmp/publish-out/cayo/x86-64/{*.root.raw.xz,*.root-verity.raw.xz,
#    *.disk.raw.xz,*.efi,*.manifest.json,*.sbom.spdx.json,SHA256SUMS,
#    publication-info.json}

# 5-6: upload to the R2 candidate prefix, Cache-Control: public/immutable
# on payloads (plan steps 5-6)
$ shared/native-ab/publish/publish-candidate.sh \
    /var/tmp/publish-out/cayo/x86-64 rclone:r2:frostyardrepo

# 7: independently re-verify every candidate object over HTTP (plan step 7)
$ shared/native-ab/publish/verify-remote.sh \
    /var/tmp/publish-out/cayo/x86-64 \
    https://repository.frostyard.org/os/native/v1/cayo/x86-64

# 8-13: promote to final names, regenerate+sign SHA256SUMS over the exact
# served bytes, signature-first/manifest-last, both no-store (plan steps
# 8-13). Run ONLY inside the protected promotion environment -- this is the
# one command in this whole procedure that touches the private key.
$ shared/native-ab/publish/promote.sh \
    --signing-key /path/to/protected/os-update-signing.key \
    --purge-hook /path/to/cloudflare-purge.sh \
    /var/tmp/publish-out/cayo/x86-64 \
    https://repository.frostyard.org/os/native/v1/cayo/x86-64 \
    rclone:r2:frostyardrepo
```

### 14-15: Cloudflare purge

`promote.sh --purge-hook <cmd>` invokes `<cmd> <sha256sums.gpg-url>
<sha256sums-url>` after a successful signature-first/manifest-last publish.
Locally this is a no-op (nothing to purge against a plain directory). In
production the hook is `shared/native-ab/publish/cloudflare-purge.sh`, which
POSTs those exact two URLs to the Cloudflare purge API and hard-fails unless the
API returns `success: true`. It reads `CF_ZONE_ID` and `CF_API_TOKEN` from the
environment (set by the promote job from the `native-promotion` secrets); the
CI promote step adds `--purge-hook` only when both are present, so
staging/rehearsal runs without CF secrets simply skip the purge. The
`build-native-images.yml` wiring is already in place.

A purge-API `success: true` means the purge was *accepted*, not that the edge is
already serving fresh bytes. So the promote step then runs
`shared/native-ab/publish/verify-published-index.sh` against the public product
URL: it re-fetches the plain `SHA256SUMS`/`SHA256SUMS.gpg` a real client would
get, `gpgv`-verifies the pair against the shipped pubring, asserts the served
`SHA256SUMS` advertises the just-promoted version, and retries to absorb
purge-propagation delay -- a persistent stale/mismatched pair is a hard failure.
This is the "do not treat a 200 alone as sufficient" served-bytes check.

For a true multi-region check (`verify-published-index.sh` runs from the CI
runner's single vantage), also re-fetch the two metadata URLs from a network
path outside the promotion environment after a real production promotion. If
public-origin testing ever shows Cloudflare not honoring the exact-name
cache-bypass rule for `SHA256SUMS`/`SHA256SUMS.gpg`, a Worker-backed atomic
generation switch becomes mandatory before publication continues (plan, "Atomic
Publication Procedure").

### Cache-Control and cache-bypass rules

Configure once, outside these scripts (Cloudflare dashboard or Terraform,
not part of this pipeline):

- An exact-name cache rule bypassing cache for `SHA256SUMS` and
  `SHA256SUMS.gpg` under every product's `x86-64/` path.
- Everything else relies on the `Cache-Control` header the scripts set at
  upload time (`public, max-age=31536000, immutable` for versioned payload
  objects, `no-store` for the two index files) -- R2/Cloudflare honors
  origin `Cache-Control` by default; the exact-name rule above exists
  specifically because immutable-payload edge caching must never also cache
  the two files whose content changes on every promotion.

## Withdrawal (bad release)

Per the plan ("R2 Retention And Cost Control"): withdrawal changes which
signed index a channel advertises. It never deletes or downgrades bits
already on disk, and systems that already installed the bad version need a
**new, higher-versioned repair release** -- never a server-side downgrade.

```console
$ shared/native-ab/publish/withdraw.sh cayo 20260714150036 rclone:r2:frostyardrepo
```

This only works if `promote.sh` archived that version's signed index pair
during a *later* promotion (every `promote.sh` run archives the pair it is
about to overwrite to `.history/<version>/` first) -- withdrawal restores an
already-signed pair, it never creates a new signature. `withdraw.sh` refuses
outright (no live files touched) if the archived pair fails `gpgv`
verification against the pubring, or if no archived pair exists for the
requested version. After withdrawal, re-run the purge step manually (the
same Cloudflare-purge wrapper, or `withdraw.sh --purge-hook <cmd>`) and
confirm the previous version is what a fresh `verify-remote.sh`-style check
sees.

## Installer ISO publication

> **Size note:** since the graphical setup wizard landed (GTK4/cage/Mesa
> stack + picker data), the ISO is ~700 MB rather than the ~600 MB
> text-only ISO (the ~1.6 GB rootfs zstd-compresses hard; size is NOT a
> reliable text-vs-GUI check — the two are only ~100 MB apart). Candidate
> upload, `verify-remote`'s full re-download,
> and promotion re-hashing all scale with it; budget CI time accordingly.

The network-installer ISO (`docs/native-ab-contracts.md` "Installer ISO",
§5's flat `isos/native/v1/` namespace -- no per-product/x86-64 subpath, since
there is exactly one installer, not one per product) goes through the
*same* candidate -> verify -> promote -> withdraw pipeline as every OS
product, just staged by `prepare-iso-publication.sh` instead of
`prepare-native-publication.sh`:

```console
# Build + assemble (see CLAUDE.md "Native A/B Prototype" / `just
# native-installer-iso`): produces output/snosi-native-installer_<version>_
# x86-64.iso, already version-stamped and correctly named by
# shared/native-installer/tools/build-iso.sh itself.
$ VERSION=$(date -u +%Y%m%d%H%M%S)
$ shared/native-installer/tools/build-iso.sh output/native-installer output "$VERSION"

$ shared/native-ab/publish/prepare-iso-publication.sh \
    "output/snosi-native-installer_${VERSION}_x86-64.iso" "$VERSION" /var/tmp/iso-publish-out
$ shared/native-ab/publish/publish-candidate.sh /var/tmp/iso-publish-out rclone:r2:frostyardrepo
$ shared/native-ab/publish/verify-remote.sh /var/tmp/iso-publish-out \
    https://repository.frostyard.org/isos/native/v1
$ shared/native-ab/publish/promote.sh --signing-key .snosi-private/os-update-signing.key \
    /var/tmp/iso-publish-out https://repository.frostyard.org/isos/native/v1 \
    rclone:r2:frostyardrepo
```

`publication-info.json`'s `product`/`channel` are both
`snosi-native-installer` (matching the frozen object name's literal prefix,
`snosi-native-installer_<version>_x86-64.iso`) and its `dest_path` is
`isos/native/v1` -- `publish-candidate.sh`/`promote.sh` read that field
(`PUB_DEST_PATH`, `shared/native-ab/publish/publish-lib.sh`) instead of
always deriving `os/native/v1/<product>/x86-64`, so no OS-artifact behavior
changed to add this. `withdraw.sh` has no `publication-info.json` to read
from (it takes `<product> <version> <dest>` directly, for incident response
without a prepared directory on hand), so ISO withdrawal passes the same
path explicitly:

```console
$ shared/native-ab/publish/withdraw.sh --dest-path isos/native/v1 \
    snosi-native-installer 20260714150036 rclone:r2:frostyardrepo
```

`test/native-publication-pipeline-test.sh`'s "ISO-shaped fixture leg"
exercises this whole flow locally (tiny fixture files standing in for a real
ISO) as part of the same fast, non-root, per-PR check.

### Stable installer download URL

The user-facing moving URL is:

```text
https://repository.frostyard.org/isos/native/v1/snosi-native-installer-latest-x86-64.iso
```

`workers/native-installer-redirect/` owns the exact-path Cloudflare Worker
route. The Worker reads `isos/native/v1/SHA256SUMS` directly through an R2
binding, requires exactly one filename matching
`snosi-native-installer_<14-digit-version>_x86-64.iso`, confirms that object
exists with an R2 `head()`, and returns an uncacheable `302` to the immutable
public URL. Missing, oversized, malformed, or ambiguous indexes and missing
target objects fail closed with `503`; only `GET` and `HEAD` are accepted. It
does not list versions, retain a separate `latest` value, proxy ISO bytes, hash
the ISO, or verify OpenPGP in the request path.

That division is deliberate: the redirect is discovery convenience, while
`SHA256SUMS.gpg` authenticates `SHA256SUMS` and the listed SHA-256 authenticates
the downloaded ISO. Because `promote.sh` writes immutable bytes before the
signature and writes `SHA256SUMS` last, a promotion keeps redirecting to the old
ISO until the new publication is complete. Withdrawal uses the same
signature-first/manifest-last ordering; do not declare withdrawal complete
until both the signed-index check and redirect check pass:

```console
$ shared/native-ab/publish/verify-published-index.sh \
    --expect-version "$RESTORED_VERSION" \
    https://repository.frostyard.org/isos/native/v1
$ shared/native-ab/publish/verify-installer-redirect.sh \
    https://repository.frostyard.org/isos/native/v1/snosi-native-installer-latest-x86-64.iso \
    "$RESTORED_VERSION"
```

The Worker deploys independently through
`.github/workflows/deploy-native-installer-redirect.yml`; ISO promotion never
redeploys edge code. The workflow runs the local R2 integration suite, generated
type drift check, TypeScript check, and Wrangler dry-run before deployment. It
uses the existing `NATIVE_R2_ACCOUNT_ID` and a dedicated
`CF_WORKERS_API_TOKEN` in `native-promotion`; scope that token to Worker script
and route edits for `frostyard.org`. The R2 bucket binding is configured in
`wrangler.jsonc`, so no S3 access key is exposed to the Worker. After every ISO
promotion, `build-native-images.yml` runs `verify-installer-redirect.sh` with
the promoted version.

## Retention policy application

Per `docs/native-ab-contracts.md` §13 and the plan's "R2 Retention And Cost
Control" (not yet automated by these scripts -- apply manually via `rclone`
lifecycle rules or a scheduled job until a dedicated retention script
exists):

- Keep the current + previous 2 stable versions' immutable objects per
  product.
- Retain withdrawn versions' objects for 90 days after withdrawal.
- Retain full installer disk images (`*.disk.raw.xz`) for **less** time than
  root/verity update objects.
- Only delete after both the rollback window and the offline-install window
  have passed.
- `promote.sh`'s `.history/<version>/` archive (signed index pairs only,
  tiny) is not subject to the same size-driven pressure as the multi-
  gigabyte payload objects, but should still be pruned once a version's
  payload objects themselves are deleted (an archived index pointing at
  already-deleted objects has no withdrawal value).
- Record compressed bytes and estimated R2 storage/read cost per release
  (plan) -- `publication-info.json`'s `artifacts.*.size` fields are the
  source for this.

## Interim protected-builder constraints (until HSM/PKCS#11 signing exists)

Verbatim-in-substance from the plan's "Build And Signing Key Custody" /
`docs/native-ab-contracts.md` §7 "Protected signing architecture", restated
here as the operational checklist for whatever runs `promote.sh` with the
real key:

1. An unprivileged build job creates the root, verity tree, kernel, initrd,
   unsigned UKI inputs, manifests, SBOM, and provenance without long-lived
   keys. This is everything up through `verify-remote.sh` above.
2. The protected signer (whatever runs `promote.sh --signing-key`) accepts
   artifacts only from a trusted main-branch build with verified provenance
   and expected hashes -- never from a pull-request or fork trigger.
3. Until mkosi supports split final assembly from signing, the accepted
   interim fallback is a dedicated protected builder that:
   - runs only trusted main-branch commits,
   - has no pull-request or fork trigger,
   - receives the signing key ephemerally (mounted only for the `promote.sh`
     invocation, never for the whole job),
   - is destroyed or scrubbed after each build.
   This is an accepted **interim** risk, not the final custody model, and
   must not be treated as adequate once mkosi gains native split-signing
   support (at which point steps 1-5 of `docs/native-ab-contracts.md` §7
   "Protected signing architecture" apply in full, including HSM/PKCS#11
   private-key operations).
4. Plaintext key files are never GitHub Actions artifacts and are never
   mounted while general repository build scripts execute -- only the
   `promote.sh` step itself, and only inside the protected environment.
5. `promote.sh` already implements the publication-side half of step 5
   ("Publication verifies that signed output still binds the exact root,
   verity, kernel, initrd, command line, and source revision from the
   candidate build"): it re-downloads and re-hashes every final object
   before signing, rather than trusting local disk or the copy step. It does
   NOT independently re-derive "this is the same source revision that was
   built" -- that binding comes from provenance checked in step 2, upstream
   of `promote.sh`.
6. Applies equally to the MOK and PCR signing keys (`docs/native-ab-
   contracts.md` §7's other rows) even though those are out of scope for
   this document's procedure (see `docs/native-ab-secure-*` material for
   those).

## CI publication flow

`.github/workflows/build-native-images.yml` automates the procedure above.
It is a **thin caller**: every build/publish/verify/promote step is a call
into one of the scripts documented above (or `test/native-ab-secure-
artifact-test.sh` / `test/snowfield-artifact-test.sh`) -- the only logic
that lives directly in the workflow YAML is orchestration glue (job
ordering, secret-file plumbing, disk-space mitigation) that has no
meaningful existence outside a GitHub Actions runner. If you find yourself
adding a `jq`/`sha256sum`/`curl` pipeline directly in a `run:` block instead
of extending one of the in-repo scripts, that is a defect -- scripts are
testable locally (see "Local rehearsal" below and `shared/native-ab/ci/`);
raw YAML steps are not.

### Trigger

Builds run on **every push and PR to `main`** (mirroring `build-images.yml`,
same sysext `paths-ignore`), plus `workflow_dispatch` and `repository_dispatch`.
Building and publishing are gated separately:

- **Build + public-origin verify** run on every trigger, including PRs.
- **Promotion** (sign + mutate the live R2 index) is gated OUT of PRs at the
  job level (`if: !cancelled() && github.event_name != 'pull_request'`), so a
  PR builds and verifies but never publishes -- only `main` pushes and manual
  `workflow_dispatch` promote. The `native-promotion` environment additionally
  restricts to protected (`main`) branches, so a `workflow_dispatch` fired
  from a feature branch cannot promote either.

Custody trade-off (the approval gate was removed for velocity, 2026-07): the
`native-build` environment no longer requires reviewer approval and is open to
any branch, so **same-repo PR branches build with the Secure Boot/MOK + PCR
signing keys** (fork PRs cannot access secrets, so their build jobs fail as
expected). This relaxes the "interim protected-builder" posture below in
exchange for CI-on-every-PR; the promotion (OpenPGP) key stays main-scoped via
`native-promotion`. Revisit when mkosi gains split final-assembly-from-signing.

The per-ref `concurrency` group
(`build-native-images-${{ github.ref }}`, `cancel-in-progress` only for PRs)
ensures two `main`/dispatch runs can never interleave `promote.sh` invocations
against the same product's live `SHA256SUMS`/`SHA256SUMS.gpg`, while superseded
PR builds (which never promote) may cancel to save runner time.

### Jobs

| Job | Runs | Gated by |
|---|---|---|
| `pin-check` | `shared/native-ab/ci/check-mkosi-pin.sh` (no build) | -- |
| `prepare` | Assigns one version/revision shared by every product this run | -- |
| `build-cayo` / `build-snow` / `build-snowfield` | Bootstraps pinned mkosi, builds the profile, runs the static artifact test(s), `prepare-native-publication.sh --xz`, `publish-candidate.sh` | `native-build` environment |
| `test-public-origin` | `verify-remote.sh` against the real public URL, one matrix leg per product | -- (read-only, no secrets) |
| `promote-cayo` / `promote-snow` / `promote-snowfield` | `promote.sh` | `native-promotion` environment |
| `build-iso` / `test-public-origin-iso` / `promote-iso` | Builds the network installer, verifies its candidate, promotes its signed index, then verifies the stable redirect | `native-build` / `native-promotion` environments as appropriate |
| `release-notes` | Non-blocking GitHub Release summarizing whichever products actually promoted | -- |

Each `build-*`/`promote-*` triple is three independent jobs, not a matrix,
so one product's failure (a build error, a rejected signature, a network
blip) never blocks another's -- `test-public-origin` and each `promote-*`
job independently check for their own product's upstream artifact via a
`continue-on-error: true` download and simply no-op (not fail) when it is
absent, the same "did the artifact actually appear" pattern
`build-images.yml`'s own `release` job already uses for its `snow-tag`
artifact.

Only small pipeline records (`publication-info.json`, `SHA256SUMS`, and tiny
marker files) ever pass between jobs as GitHub Actions artifacts. The
multi-gigabyte payload objects themselves are uploaded directly from the
`build-*` job's runner to R2 via `rclone` and never touch Actions artifact
storage -- `verify-remote.sh` and `promote.sh` re-download the actual bytes
over HTTP from the public origin in later jobs, exactly as a real client
would, per the "never trust local disk" property described above.

### Secret inventory

| Secret | Environment | Consumed by | Written to | Scope / rotation |
|---|---|---|---|---|
| `NATIVE_SECURE_BOOT_KEY` | `native-build` | mkosi build step only | `mkosi.key` | Secure Boot/MOK private key. See CLAUDE.md "MOK Rotation" / `docs/native-ab-contracts.md` SS7. |
| `NATIVE_SECURE_BOOT_CERTIFICATE` | `native-build` | mkosi build step only | `mkosi.crt` | Public half of the above; also needs MOK enrollment on every installed machine before rotation. |
| `NATIVE_PCR_SIGNING_KEY` | `native-build` | mkosi build step only | `.snosi-private/pcr-signing.key` | PCR 11 signing key. Rotation: dual-signed transition UKIs, `PCR_SIGNING_KEY_PREVIOUS` -- see CLAUDE.md "Native A/B Prototype" rotation rules. |
| `NATIVE_PCR_SIGNING_CERTIFICATE` | `native-build` | mkosi build step only | `.snosi-private/pcr-signing.crt` | Public half of the above. |
| `NATIVE_R2_ACCOUNT_ID` | (repo-level) | `publish-candidate.sh`, `promote.sh` (via `rclone`) | `RCLONE_CONFIG_R2_ENDPOINT` env var | Upload authorization only -- never a substitute for the OpenPGP signature (`docs/native-ab-contracts.md` SS7). |
| `NATIVE_R2_ACCESS_KEY_ID` | (repo-level) | same | `RCLONE_CONFIG_R2_ACCESS_KEY_ID` env var | Same scope. Use a dedicated R2 API token scoped only to the native publication bucket/prefix -- do not reuse the `R2_ACCESS_KEY_ID` token `build.yml`/`build-images.yml` already use for sysexts/manifests. |
| `NATIVE_R2_SECRET_ACCESS_KEY` | (repo-level) | same | `RCLONE_CONFIG_R2_SECRET_ACCESS_KEY` env var | Same scope. |
| `NATIVE_R2_BUCKET` | (repo-level) | publication jobs and redirect-Worker preflight | `rclone:r2:<bucket>` dest argument / deploy assertion | Finalized bucket name behind `repository.frostyard.org` (`frostyardrepo`). The Worker config must match this secret; CI verifies the named bucket exists before Wrangler can auto-provision resources. |
| `NATIVE_UPDATE_SIGNING_KEY` | `native-promotion` | `promote.sh --signing-key` only | `/var/tmp/native-promote-secrets/os-update-signing.key` | OpenPGP update-signing private key (armored `gpg --export-secret-keys`). Never leaves this environment. Rotation: overlap window, both keys in the shipped pubring -- see "Production key ceremony" above. |
| `NATIVE_UPDATE_SIGNING_PASSPHRASE` | `native-promotion` | `promote.sh --passphrase-file` only | `/var/tmp/native-promote-secrets/passphrase` | Passphrase for the production signing key. The key is passphrase-protected, so `promote.sh` signs via `gpg --pinentry-mode loopback --passphrase-file`. Omit only if the key has no passphrase (not recommended); then `promote.sh` runs without `--passphrase-file`. |
| `CF_ZONE_ID` | `native-promotion` | `cloudflare-purge.sh` env | never on disk (env only) | Cloudflare zone id for `repository.frostyard.org`. If unset, the promote step skips the edge purge (the no-store header + cache-bypass rule are the primary protection). |
| `CF_API_TOKEN` | `native-promotion` | `cloudflare-purge.sh` env | never on disk (env only) | Cloudflare API token scoped to **Zone.Cache Purge** on that zone only. If unset, the promote step skips the edge purge. |
| `CF_WORKERS_API_TOKEN` | `native-promotion` | `deploy-native-installer-redirect.yml` / Wrangler only | never on disk (env only) | Dedicated token scoped to deploy the redirect Worker and edit its `frostyard.org` route. It does not need the OpenPGP signing key or S3 credentials. |

Every secret-consuming step writes key material to a runner-local file
immediately before the one command that needs it, `chmod 600`s it, never
echoes it, and removes it in a dedicated `if: always()` (or
`if: !cancelled()`) cleanup step in addition to each script's own internal
trap-based cleanup (`promote.sh`'s ephemeral `GNUPGHOME`, in particular).
Plaintext key files are never GitHub Actions artifacts.

### Interim protected-builder constraints, applied

Until mkosi supports split final assembly from signing
(`docs/native-ab-contracts.md` SS7 "Protected signing architecture"), the
`build-*` jobs are themselves the accepted interim "protected builder"
described above: main-branch-only trigger, no pull-request/fork path,
ephemeral key files scoped to a protected `native-build` environment, and
key material present only for the single `mkosi build` step. This is not
the final custody model -- once mkosi can assemble a signed UKI/ESP from an
already-built unsigned root without needing the private keys present for
the whole build, the Secure Boot/MOK and PCR signing steps should move to
their own protected signer job, mirroring how `promote-*` already isolates
the OpenPGP key to the smallest possible step.

### What has NOT been exercised

**Production R2 upload through this workflow has not been exercised.** The
exercised path is: (1) the local rehearsal below (`test/native-ab-
publication-test.sh`, `test/native-publication-pipeline-test.sh`), which
proves every script's logic against a local directory `dest` and a local
HTTP origin, and (2) this workflow's *structure* -- job graph, environment
gating, secret plumbing, disk mitigation -- validated with `actionlint` and
by hand-tracing every `run:` step's script references (no GitHub Actions
run is possible without pushing, and pushing was out of scope for the
change that introduced this workflow). Before the first real run against
`repository.frostyard.org`, walk the "First production publication
checklist" below.

## First production publication checklist

Everything above this point can be rehearsed locally. This is what remains
before `build-native-images.yml` is allowed to touch the real
`repository.frostyard.org` origin:

1. **Production key ceremony.** Complete "Production key ceremony" above
   for the OpenPGP update-signing key: generate offline, export the public
   half into `shared/native-ab/keys/import-pubring.gpg` (replacing or
   overlap-extending the committed DEV key), rebuild every native profile so
   the new pubring ships, and store the private half only as the
   `NATIVE_UPDATE_SIGNING_KEY` secret in the `native-promotion` GitHub
   environment -- never anywhere else.
2. **Secure Boot/MOK and PCR signing keys.** Generate (or carry over from an
   already-validated `cayo-ab-secure`-style spike) production Secure
   Boot/MOK and PCR signing key pairs. Store them as the `native-build`
   environment's `NATIVE_SECURE_BOOT_KEY`/`NATIVE_SECURE_BOOT_CERTIFICATE`/
   `NATIVE_PCR_SIGNING_KEY`/`NATIVE_PCR_SIGNING_CERTIFICATE` secrets. Confirm
   the MOK certificate is enrollable via MokManager on real hardware before
   any machine is expected to trust images built with it (see
   `docs/native-ab-contracts.md` SS7's MOK Rotation section for the
   enrollment-overlap procedure).
3. **R2 credentials.** Create a dedicated R2 API token scoped only to the
   native publication bucket/prefix (upload authorization only, per
   `docs/native-ab-contracts.md` SS7 -- do not reuse the sysext/manifest
   token `build.yml`/`build-images.yml` already use). Store
   `NATIVE_R2_ACCOUNT_ID`/`NATIVE_R2_ACCESS_KEY_ID`/
   `NATIVE_R2_SECRET_ACCESS_KEY`/`NATIVE_R2_BUCKET` as repository secrets.
4. **Protected environments.** Create the `native-build` and
   `native-promotion` GitHub environments with required-reviewer protection
   restricted to the `main` branch, and add the secrets above to the correct
   environment (never as plain repository secrets for the signing keys).
5. **First run: staging prefix, not production.** Point `NATIVE_R2_BUCKET`
   (or a temporary override) at a **non-production** prefix first (e.g.
   `<bucket>/staging-test`) and manually verify a disposable VM can install
   and update from it end to end -- the same check "Production key ceremony"
   step 5 above describes -- before ever letting the workflow write to the
   real `os/native/v1/<product>/` paths.
6. **`SNOSI_NATIVE_AUTOSTAGE`.** Native A/B images ship with autostage
   disabled by default (Phase 4's mechanism, `shared/outformat/ab-root/
   mkosi.conf` forwards `SNOSI_NATIVE_AUTOSTAGE` via `Environment=`, gating
   the static `snosi-sysupdate-stage.timer` enablement link). Only set
   `SNOSI_NATIVE_AUTOSTAGE=1` for the profile build once the first real
   promoted release has been manually verified reachable and installable --
   do not enable unattended staging before a single real release has been
   proven end to end.
7. **Cloudflare cache rule.** Before the first promotion, add the exact-name
   cache-bypass rule for `SHA256SUMS`/`SHA256SUMS.gpg` under every product's
   `x86-64/` path (see "Cache-Control and cache-bypass rules" above) --
   `promote.sh` sets the right origin headers regardless, but the edge cache
   rule is what makes the "purge" step below actually matter.
8. **Purge-hook wiring.** Write the Cloudflare purge wrapper script (see the
   "14-15: Cloudflare purge" example above), store `CF_ZONE_ID`/
   `CF_API_TOKEN` as secrets in the `native-promotion` environment, and pass
   `--purge-hook /path/to/cloudflare-purge.sh` to `promote.sh` in each
   `promote-*` job. The workflow as introduced does **not** pass
   `--purge-hook` -- wire it in as part of this checklist, not before.
9. **Re-verify after the first real promotion.** `curl -I` the two metadata
   URLs from a network path outside the promotion environment, confirm a
   second region sees the matching pair, and only then consider
   `build-native-images.yml` production-ready for unattended pushes to
   `main`.

## Local rehearsal (no real R2/Cloudflare)

`test/native-ab-publication-test.sh` runs this entire procedure against a
local directory `dest` and a local HTTP origin (`test/lib/range-http-
server.py` -- see its header for why not plain `python3 -m http.server`),
plus a QEMU guest that verifies the promoted index using the **stock
shipped DEV pubring** (no `/etc` override) -- the same production-shaped
trust path as the ceremony above, just pointed at a fake origin. It also
proves three fail-closed tamper cases (payload corrupted after signing,
partial publication, wrong signing key) and a withdrawal round-trip. Run it
with `sudo ./test/native-ab-publication-test.sh` (tens of minutes; builds
two real `cayo-ab-raw` images unless `SKIP_BUILD=1 BUILD_N_DIR=... BUILD_N1_DIR=...`
point at already-built output dirs). See that script's own header for the
full sequence and why `cayo-ab-raw` (not `cayo-ab`) is used as the build
target while still publishing under the real `cayo-ab` channel name.

`test/native-installer-e2e-test.sh` (Phase 8 exit) drives this same local
rehearsal origin one step further: it publishes real `cayo-ab` and `snow-ab`
through the full `prepare -> publish-candidate -> verify-remote -> promote`
pipeline to a `range-http-server.py` origin, then boots the shipped
network-installer ISO in QEMU and runs a real non-interactive encrypted install
that fetches and `gpgv`-verifies the promoted index with the stock shipped DEV
pubring — the publication path exercised end to end from an actual installer,
not just a verify-only guest. See `yeti/testing.md` "Phase 8 (ISO install
end-to-end)".
