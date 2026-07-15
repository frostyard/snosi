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
| `generate-sbom.sh` | Generates `<channel>_<version>.sbom.spdx.json` directly from the mkosi package manifest. Called by `prepare-native-publication.sh`; not normally invoked standalone. |
| `publish-candidate.sh` | Uploads immutable versioned objects to a per-version candidate staging path. |
| `verify-remote.sh` | Independently re-verifies every candidate object over HTTP (size, full SHA-256, range GETs) before anything is promoted. |
| `promote.sh` | Copies verified candidates to their final public names, regenerates and signs `SHA256SUMS`, publishes signature-first/manifest-last. |
| `withdraw.sh` | Restores a previously-archived signed index pair (incident response / bad-release rollback of the *index*, not the bits). |

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
    /var/tmp/publish-out/cayo/x86-64 rclone:r2:frostyard-repository

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
    rclone:r2:frostyard-repository
```

### 14-15: Cloudflare purge

`promote.sh --purge-hook <cmd>` invokes `<cmd> <sha256sums.gpg-url>
<sha256sums-url>` after a successful signature-first/manifest-last publish.
Locally this is documented as a no-op (nothing to purge against a plain
directory). In production, point it at a small wrapper that calls the
Cloudflare API to purge exactly those two URLs, e.g.:

```bash
#!/bin/bash
# cloudflare-purge.sh <url> <url>...
set -euo pipefail
curl -fsS -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/purge_cache" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$(printf '{"files":%s}' "$(printf '%s\n' "$@" | jq -R . | jq -s .)")"
```

Per the plan: "verify response headers from the public custom domain" and
"test that a second region sees the new matching pair" after every
promotion -- do not treat a 200 from the purge API call alone as sufficient;
re-`curl -I` the two metadata URLs from a network path outside the promotion
environment afterward. If public-origin testing ever shows Cloudflare not
honoring the exact-name cache-bypass rule for `SHA256SUMS`/`SHA256SUMS.gpg`,
a Worker-backed atomic generation switch becomes mandatory before
publication continues (plan, "Atomic Publication Procedure").

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
$ shared/native-ab/publish/withdraw.sh cayo 20260714150036 rclone:r2:frostyard-repository
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
