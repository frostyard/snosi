# Plan: Move sysext hosting from Cloudflare R2 to GHCR

**Status:** Proposed
**Last verified:** 2026-09-13

This plan moves the 27 sysext overlay images off the `ext/<name>/` namespace of
`repository.frostyard.org` (Cloudflare R2 bucket `frostyardrepo`) onto GHCR as
OCI artifacts, keeps the existing OpenPGP trust root (core ADR-0014), and
teaches `frostyard-updex` — the only production sysext client — to pull from a
registry. It does not touch the apt namespaces (`pool/`, `dists/`), the native
A/B namespace (`os/native/v1/`), or the ISO namespace (`isos/`). It amends
core ADR-0009 (single origin) and ADR-0010 (repogen-to-R2, never delete) for
the sysext namespace only. Two cheaper mitigations (compression, retention)
are called out first because they cut the bill within days and remain
worthwhile after the migration.

## Why the bill grows (measured 2026-09-13, public origin)

Sizes below were measured by reading every `ext/<name>/SHA256SUMS` and
`HEAD`-ing each listed object. They are a floor: repogen rebuilds each
`SHA256SUMS` from the previous manifest, not from a bucket listing, so any
object that ever fell out of a manifest is orphaned and invisible here.

| Namespace | Files indexed | Bytes |
|---|---|---|
| `ext/` (27 sysexts) | 263 | 135 GiB |
| `os/native/v1/` (3 products) | 21 | 9.5 GiB |
| `isos/native/v1/` | 1 | 0.7 GiB |

Three facts drive the `ext/` number:

1. **Nothing is ever deleted.** `publish-to-r2` uploads with `aws s3 sync`
   and no `--delete` (repogen `action.yml:561-565`); core ADR-0010 makes
   never-delete policy. Every version ever published is still stored.
2. **Nothing is compressed.** Every published object is a bare `.raw`; no
   sysext `mkosi.conf` and neither the root nor base config sets
   `CompressOutput=`. The transfer files already accept `.raw.zst` first.
3. **High-churn upstreams republish daily.** `chatgpt` has 26 versions at
   ~1.3 GiB each (34 GiB), `claude-desktop` 26 (14.7 GiB), `code-server` 20
   (11.8 GiB), `vscode` 17 (16.5 GiB), `github-copilot` 13 (15.4 GiB). The
   `check-packages.yml` sentinel bumps plus `SYSEXT_REVISION` rebases make a
   new 1.3 GiB object per upstream release.

Storage on R2 is billed per GB-month, so the bill tracks the cumulative
never-pruned total, which is why it looks exponential while the number of
sysexts is flat. GHCR charges nothing for storage or transfer of public
packages (GitHub billing docs, "GitHub Packages usage is free for public
packages"; container registry storage and bandwidth "currently free").

## Cheap wins that do not need GHCR (do these first, they survive the move)

- **Compress sysext output.** Add `CompressOutput=zstd` (and a
  `CompressLevel=`) to the shared sysext fragment so the postoutput script
  finds `<name>.raw.zst`. `sysext-postoutput.sh` already iterates
  `raw raw.gz raw.xz raw.zst ...`; the transfer `MatchPattern` already lists
  `.raw.zst` first; updex decompresses by filename suffix
  (`download/download.go:234,267-279`) and strips the suffix from the target
  name (`updex/install.go:159-184`). Electron payloads compress roughly 3x.
  Expected effect: every future object is a third of today's size on any
  backend. One-line config change plus a `SYSEXT_REVISION` bump is not
  required (new versions arrive compressed on their own).
- **Prune R2 `ext/` to the last K versions per sysext.** A one-off script
  (`aws s3 ls` the prefix directly, never trust the manifests, keep the K
  newest by `dpkg --compare-versions` order plus everything referenced by
  a currently shipped image, delete the rest, then rewrite and re-sign
  `SHA256SUMS`). This is the only action that shrinks the existing bill;
  the migration alone only stops growth. ADR-0010 says removal is a manual
  bucket operation, so this needs no ADR change, only a runbook entry.

With both, the sysext footprint drops from 135 GiB to roughly 10-15 GiB and
growth to a few GiB per month. Do the migration for the structural reasons
below (free, content-addressed, per-repo tags, no shared mutable index, GC
through the Packages API), not because R2 cannot be made cheap.

## The pipeline today, end to end

Producer (snosi `build.yml`):

1. `sudo -E mkosi build` builds base plus all sysexts; the shared
   `shared/sysext/postoutput/sysext-postoutput.sh` renames each output to
   `<name>_<version>_<osver>_<arch>.raw` (Debian epoch `:` encoded as `+`,
   optional `+rN`) and writes `<name>.<version>.manifest.json`.
2. `sysextmv.sh` / `manifestmv.sh` move them into `output/sysexts/` and
   `output/manifests/<name>/`.
3. `frostyard/repogen/.github/actions/publish-to-r2@ea8cd1f` (v0.4.1 YAML,
   but `repogen-version` defaults to `latest`, so the binary is v0.5.0)
   syncs `ext/` metadata down, rebuilds `ext/<name>/SHA256SUMS` from the
   old manifest plus new files, signs it with `REPOGEN_GPG_KEY`
   (`gpg --detach-sign --digest-algo SHA512`, binary), regenerates the
   shared `ext/index`, and `aws s3 sync`s everything up.
4. `ryand56/r2-upload-action` uploads `output/manifests/` to `manifests/`.

The `build` job runs PR-controlled mkosi as root and is therefore pinned to
`contents: read` by `test/build-workflow-permissions-test.py`; it must never
gain `packages: write`.

Storage: `ext/index`, `ext/<name>/{SHA256SUMS,SHA256SUMS.gpg,<name>.transfer,
<files>}` plus `index.html` at each level. Served straight off the R2 custom
domain; no Worker route covers `/ext/*`.

Consumer (every image):

- The base image ships `usr/lib/sysupdate.<name>.d/<name>.{transfer,feature}`
  for each sysext with `Type=url-file`,
  `Path=https://repository.frostyard.org/ext/<name>/`, `Verify=true`, and
  the repository key at `/usr/lib/systemd/import-pubring.{gpg,pgp}`
  (`mkosi.images/base/mkosi.conf:15-16`).
- **`frostyard-updex` does all sysext fetching.** It reimplements the
  `url-file` half of systemd-sysupdate in Go (README: "replicating the
  functionality of systemd-sysupdate for url-file transfers"): it fetches
  `<Path>/SHA256SUMS` and `.gpg` (`manifest/manifest.go:66-129`,
  `manifest/gpg.go`), regex-matches manifest filenames against
  `MatchPattern` to enumerate versions (`updex/list.go:57-68`), downloads
  `<Path>/<file>` with streaming SHA-256 (`download/download.go:118-264`),
  stages into `/var/lib/extensions.d/`, links into `/var/lib/extensions/`,
  and runs `systemd-sysext refresh`. It never calls `systemd-sysupdate`,
  `updatectl`, or D-Bus. Installed version on this host: 2.0.0.
- Consumers of updex: `snosi-firstboot` (CLI `--json`), pilothouse (CLI
  `--json`), chairlift (**Go SDK, pinned `v1.5.0` in its `go.mod`**).
- `systemd-sysupdate` itself only ever reads the default `sysupdate.d`
  target (native OS updates) in production; `systemd-sysupdate components`
  merely enumerates directory names. Its `[Source] Type=` set in systemd 261
  is `url-file, url-tar, tar, regular-file, directory, subvolume`; there is
  no OCI source, so **sysupdate cannot be the registry client**. That is
  fine because it is not the sysext client today either.

## Hard constraints found in the code

| Constraint | Where | Consequence for the design |
|---|---|---|
| updex hard-codes `url-file`; any other `Type=` is silently dropped from the feature set | `config/transfer.go:229-253` (`IsSysextTransfer`, ADR-0002), `updex/list.go:26-27` | A new source type must be added in both places or the sysext disappears from `features list` with no error |
| Version discovery is "regex the filenames in SHA256SUMS" | `updex/list.go:57-68`, `version/pattern.go` | OCI has tags, not a filename list; either synthesize a manifest from tags or keep publishing a signed SHA256SUMS-shaped document |
| Compression detected from the URL string | `download/download.go:234` | Blob URLs end in a digest; the backend must pass the logical filename instead |
| No auth of any kind on transfer URLs; 401 is not retried | `download/download.go:153`, `manifest/manifest.go:78`, retry classes at `download.go:164-169` | GHCR requires an anonymous bearer-token exchange even for public packages (`401` + `WWW-Authenticate` then `GET https://ghcr.io/token?scope=repository:<name>:pull`) |
| Cross-origin redirect must strip `Authorization` | pattern exists only in `catalog/catalog.go:137-154` | GHCR redirects blob GETs to a CDN origin |
| Manifest cache keyed on `Source.Path` only | `updex/features.go:468,499,580,603`; flagged in `docs/design/overview.md:92` | Key must include type (and later auth identity) |
| Catalog renderer forces `Type=url-file` | `catalog/catalog.go:294-295,383-384` | Catalog-sourced sysexts stay on url-file until phase 5 |
| Doc-contract tests fail the build on drift | `updex/readme_target_keys_contract_test.go`, `design_overview_contract_test.go`, `sdk_api_download_options_contract_test.go`; coverage ratchet 85.1 | New `[Source]` keys, new `internal/` package, and new `download` options each need doc updates in the same PR |
| chairlift links the SDK, not the CLI | `chairlift/go.mod:8` (`updex v1.5.0`) | An old chairlift build filters OCI transfers out and the GUI loses those features; chairlift must bump and release in the rollout window |
| Trust root is one OpenPGP key baked into images | core ADR-0014, `test/sysext-signature-verification-test.sh` pins fingerprint `432C…2F97` | Keep OpenPGP as the client-verified signature; cosign is additive, not a replacement, unless a fleet-wide key rollout is accepted |
| Single origin, frozen namespaces, repogen-to-R2 never-delete | core ADR-0009, ADR-0010 | Both need an amendment ADR in frostyard/core before the behavior changes |
| `build` job must stay `contents: read` | `test/build-workflow-permissions-test.py` | Publication moves to a second, main-only job that never runs mkosi |

## Target design

### Registry layout

One GHCR package per sysext, nested under a namespace that keeps them apart
from the bootable images (`ghcr.io/frostyard/{floe,snow,snowfield}`):

```
ghcr.io/frostyard/sysext/<name>
  tags:
    <encoded version>   one per published version (immutable content)
    index               the signed version list (moves on every publish)
```

Per-version artifact (pushed with `oras push`):

- `artifactType`: `application/vnd.frostyard.sysext.v1`
- one layer: the `.raw.zst` bytes, mediaType
  `application/vnd.frostyard.sysext.layer.v1.raw+zstd` (`+xz`, `+gzip`, or
  bare `.raw` mapped the same way), annotation
  `org.opencontainers.image.title=<name>_<version>_<osver>_<arch>.raw.zst`.
  **The layer digest is the SHA-256 of the file bytes, which is exactly the
  value repogen writes into `SHA256SUMS` today.**
- manifest annotations: `org.opencontainers.image.version=<version>`
  (unencoded, authoritative), `org.frostyard.sysext.os-version=13`,
  `org.frostyard.sysext.architecture=x86-64`,
  `org.frostyard.sysext.key-package=<KEYPACKAGE>`,
  `org.opencontainers.image.source=https://github.com/frostyard/snosi`,
  `org.opencontainers.image.revision=<sha>`, `org.opencontainers.image.created`.
- referrer (via `oras attach`, as `build-images.yml` already does for SBOMs):
  the mkosi manifest JSON, artifactType
  `application/vnd.frostyard.sysext.manifest+json`. This replaces the
  `manifests/` R2 upload for sysexts.

Tag encoding: OCI tags match `[A-Za-z0-9_][A-Za-z0-9._-]{0,127}`; Debian
versions may contain `+`, `~`, and `:` (already `+`-encoded by the postoutput
script) but never `_`. Encode `+` as `_P` and `~` as `_T`; the mapping is
reversible, but nothing needs to reverse it because the annotation carries
the real version. Tags only need to be unique and human-readable.

`index` artifact:

- `artifactType`: `application/vnd.frostyard.sysext.index.v1`
- two layers: `SHA256SUMS` (`text/plain`) and `SHA256SUMS.gpg`
  (`application/pgp-signature`), byte-for-byte the formats repogen emits
  today (`<sha256>  <filename>` lines; detached binary signature, SHA-512
  digest, key `432C…2F97`).
- It is regenerated on every publish **from registry state**: list tags,
  fetch each version manifest, emit one line per version from the layer
  digest and `image.title`. Because it is derived rather than accumulated,
  deleting a version tag through the Packages API and republishing the
  index is a complete, consistent unpublish. No orphaning is possible.

Why keep a SHA256SUMS-shaped index at all when tags exist: it preserves the
existing signed-document trust model (ADR-0014 "verify the signed index
before trusting any filename or digest"), it lets updex reuse its manifest
parser, signature verifier, version regexes, and `Verify=true` semantics
verbatim, it costs one small fetch instead of one manifest fetch per tag,
and it keeps `MatchPattern` (with `%w`/`%a` specifiers) meaningful. A
tags-only design would need per-tag manifest fetches for every `check`, a
second signature format (cosign) with a second trust root, and a rewrite of
version discovery.

Optional, not consumed by updex: `cosign sign --key` each version digest with
the existing `COSIGN_PRIVATE_KEY`, so registry-side policy tooling and humans
can verify with the shipped `cosign.pub`. Cheap because `build-images.yml`
already does it; do not make updex depend on it.

### Transfer file shape

```ini
[Transfer]
Features=tailscale
Verify=true

[Source]
Type=oci
Path=ghcr.io/frostyard/sysext/tailscale
MatchPattern=tailscale_@v_%w_%a.raw.zst \
             tailscale_@v_%w_%a.raw.xz \
             tailscale_@v_%w_%a.raw.gz \
             tailscale_@v_%w_%a.raw

[Target]
Type=regular-file
Path=/var/lib/extensions.d/
MatchPattern=tailscale_@v_%w_%a.raw.zst \
             tailscale_@v_%w_%a.raw.xz \
             tailscale_@v_%w_%a.raw.gz \
             tailscale_@v_%w_%a.raw
CurrentSymlink=tailscale.raw
```

`Type=oci` is an updex-only value. `systemd-sysupdate --component=<name>`
would refuse to parse it, which nothing in production does; verify with
`test/native-ab-components-test.sh`, whose ad hoc `testa`/`testb` components
keep `url-file`, and add a static assertion that no shipped default
`sysupdate.d/` transfer uses `Type=oci`. The alternative of overloading
`url-file` with a registry-shaped URL was rejected: it would make sysupdate
"succeed" at parsing and then fail at fetch with a 401, and updex would have
to sniff hostnames.

## updex changes (frostyard/updex, target release 2.1.0)

Work from `origin/main` (`dfa8c08`); the `feat/sysupdate-components` branch
already landed as #132 and should be ignored.

1. **Registry client, new package `registry/`** (documented in
   `docs/design/overview.md` or `design_overview_contract_test.go` fails).
   Minimal OCI Distribution client, no `containers/image` or `oras-go`
   dependency (both pull in far more than updex needs and would dominate the
   binary):
   - `Resolve(ref, tag)`: `GET /v2/<name>/manifests/<tag>` with `Accept:
     application/vnd.oci.image.manifest.v1+json`; returns manifest bytes,
     digest, layers, annotations.
   - `Blob(ref, digest)`: `GET /v2/<name>/blobs/<digest>` returning a
     `*http.Response` body; follows the CDN redirect and strips
     `Authorization` when the origin changes (copy the shape of
     `catalog.doListRequest`).
   - Anonymous bearer flow: on `401`, parse `WWW-Authenticate: Bearer
     realm=…,service=…,scope=…`, `GET realm?service&scope` with no
     credentials, cache the token per `(host, scope)` for its `expires_in`,
     retry once. Only `https` realms on the same registry host are accepted.
   - Optional credentials for private packages: read
     `${REGISTRY_AUTH_FILE:-/run/containers/0/auth.json}` then
     `~/.config/containers/auth.json` (podman's format, already the format
     `bootc-update-stage` and the secure images use) and present basic auth
     on the token request. Public GHCR needs none; keep this behind a
     `ClientConfig` field so the default path stays credential-free.
   - Error classification through `internal/retry` (`429`/`5xx` transient,
     everything else fatal), per ADR-0008. Size caps: manifests 4 MiB, same
     constant as `manifest.maxManifestSize`.
2. **Source dispatch.**
   - `config/transfer.go`: accept `Type=oci` in `IsSysextTransfer`, validate
     `Path` as `host/name[/name...]` (no scheme, no tag, no digest).
   - `updex/list.go`: replace the type rejection with a small `source`
     interface `{ Manifest(ctx) (*manifest.Manifest, error); Open(ctx,
     filename, sha256) (io.ReadCloser, int64, error) }` with `urlFileSource`
     (current behavior) and `ociSource`. `ociSource.Manifest` resolves tag
     `index`, downloads its two layers, and calls a new
     `manifest.ParseAndVerify(content, sig, verify)` split out of
     `manifest.Fetch` so the parser and OpenPGP check are shared byte for
     byte. `ociSource.Open` maps the manifest line's hash straight to
     `blobs/sha256:<hash>`; no per-version manifest fetch is needed.
   - `updex/install.go`: build the download from the source instead of
     string concatenation; pass the logical filename to `detectCompression`
     (a latent bug fix worth landing on its own).
   - `download/download.go`: add `WithBody(func(ctx) (io.ReadCloser,
     int64, error))` or `WithRoundTripper` so the streaming SHA-256, size
     ceilings, fsync, decompress, and atomic rename are reused unchanged;
     document the new option in `docs/specs/sdk-api.md`.
   - `updex/features.go`: manifest cache key becomes
     `Source.Type + "\x00" + Source.Path`.
3. **Catalog (phase 5, optional).** `catalog.RenderTransferTo` and
   `validateCatalogTransferTo` accept an `oci` source when a `.conf`
   declares `Registry=`; ADR-0006's byte-preserving renderer gains one
   branch. Not needed for snosi's 27 image-shipped sysexts.
4. **Tests.** Generalize `internal/testutil/httpserver.go` with an
   `OCIRegistryServer` double: `/v2/`, token endpoint returning `401` then
   a bearer token, `/manifests/<tag>`, `/blobs/<digest>` with an optional
   cross-origin redirect. Cover: anonymous token flow, token expiry, 429
   retry, 401 after token (fatal), redirect header stripping, index
   signature failure with `Verify=true` (must not fall back), manifest
   line whose hash does not match the blob digest (must fail closed),
   compression detection from filename, cache-key separation between a
   url-file and an oci transfer sharing a `Path`. Update `config/transfer_test.go`
   (`Type=url-file` assertions), `catalog/catalog_test.go:320` (deliberately
   still rejects `url-tar`; now also asserts `oci` is rejected in catalogs
   until phase 5), and `tests/e2e/e2e_test.go` with a second binary run
   against the fake registry. Keep coverage above the 85.1 ratchet.
5. **Docs and contracts.** README `[Source]` table gains `Type=oci`;
   `docs/design/overview.md` names `registry/`; `docs/specs/sdk-api.md`
   names the new download option; a new ADR "OCI registry source for
   sysext transfers" records the tag/index/blob-addressing decisions and
   that OpenPGP stays the trust root; `docs/org-adrs.md` notes the ADR-0009
   amendment.
6. **Release.** Tag `v2.1.0`, which the existing `release.yml` publishes as
   `frostyard-updex` deb to the Frostyard apt repo (that deb stays on R2,
   unchanged). Rough size: 700-900 lines of Go plus tests.

## snosi changes

1. **Compression** (`shared/sysext/` fragment or each sysext
   `mkosi.conf`): `CompressOutput=zstd`. Independent of everything else.
2. **`build.yml` split.** Keep `build` exactly as it is (`contents: read`,
   runs mkosi) and have it `actions/upload-artifact` `output/sysexts/` and
   `output/manifests/`. Add job `publish-sysexts` with `needs: build`,
   `if: github.event_name != 'pull_request'`, `permissions: {contents: read,
   packages: write}`, no checkout of PR-controlled code, no mkosi. It logs
   in to GHCR with the run-scoped `GITHUB_TOKEN` through stdin exactly as
   `build-images.yml:337,418` do (`GHCR_USER` env, never interpolated), and
   runs the publisher below. `test/build-workflow-permissions-test.py` needs
   one extra assertion: the only job with `packages: write` contains no
   `mkosi` invocation. `packages: write` on `GITHUB_TOKEN` creates a new
   package the first time it pushes (the same cutover check the CLAUDE.md
   notes for the first Floe `secure-build`); the org may require the
   package to be made public and linked to the repo once in the UI.
3. **Publisher `shared/sysext/publish/ghcr-publish.sh`** (fixture test
   `test/sysext-ghcr-publish-test.sh` in `validate.yml`, driven against
   a local `registry:2` container or the `oras` `--plain-http` fake):
   - parse `<name>_<version>_<osver>_<arch>.raw[.zst]` exactly as repogen's
     `parser.go:52-80` does (four `_`-separated parts, fail closed);
   - skip-duplicates: `oras manifest fetch` on the encoded tag; if present,
     verify the layer digest equals the local file's SHA-256 and skip, else
     fail (this is repogen v0.5.0's `DetectDigestConflicts` semantics);
   - `oras push ghcr.io/frostyard/sysext/<name>:<tag> --artifact-type …
     --annotation … <file>:<mediaType>`; `oras attach` the mkosi manifest
     JSON; optional `cosign sign --key env://COSIGN_PRIVATE_KEY`;
   - regenerate `SHA256SUMS` from `oras repo tags` plus each version's
     manifest, sort by filename, sign with `REPOGEN_GPG_KEY` (import into a
     throwaway `--homedir`, `gpg --detach-sign --digest-algo SHA512 --batch
     --yes`), push tag `index`, then `oras manifest fetch` it back and
     `gpgv` it against `mkosi.sandbox/etc/apt/keyrings/frostyard.gpg`
     before the job is allowed to succeed (ADR-0014: verify before trust);
   - `ext/index` has no consumer in snosi, updex, chairlift, pilothouse,
     firn, or core; drop it.
4. **Transfer files.** Rewrite the 27 `usr/lib/sysupdate.<name>.d/<name>.transfer`
   files to the `Type=oci` shape above via one `sed`, and update the
   template in `docs/design/sysexts.md` "Sysupdate Registration".
   `test/sysext-authoring-contract-test.sh` and
   `test/sysext-signature-verification-test.sh` continue to pin
   `Verify=true`; add a pin that every sysext transfer has `Type=oci` and a
   `Path=ghcr.io/frostyard/sysext/<name>` matching its directory name, and a
   pin that nothing under the default `sysupdate.d/` target uses `oci`.
5. **Base image dependency ordering.** Bump the `frostyard-updex` version
   sentinel in `shared/download/package-versions.json` only once 2.1.0 is in
   the apt repo; refuse to build base with `Type=oci` transfers against an
   older updex (a finalize assertion: `dpkg-query -W frostyard-updex` must
   be `>= 2.1.0` when any shipped transfer says `Type=oci`). This is the
   same release-ordering hazard already documented for component discovery.
6. **Retention job.** New scheduled workflow `prune-sysexts.yml` (weekly,
   `packages: write`): for each package under `frostyard/sysext/*`, keep the
   newest K version tags by `dpkg --compare-versions` on the
   `image.version` annotation (K=5 desktop apps, K=10 infra), delete the
   rest through `DELETE /orgs/frostyard/packages/container/<name>/versions/<id>`,
   then re-run the index regeneration step. Verify first that the run-scoped
   token may delete org package versions; if not, this needs a fine-grained
   PAT with `delete:packages`, stored like `COPILOT_ASSIGNMENT_TOKEN`.
   Never delete the `index` tag or a version referenced by a currently
   published image's `packages.txt`.
7. **Docs.** `docs/design/sysexts.md` (registration template, publishing,
   SYSEXT_REVISION note now says "tag exists" instead of "filename exists"),
   `docs/design/ci-cd.md` (job graph, artifact table row), `docs/design/build-pipeline.md`
   (`manifestmv.sh` no longer feeds R2 for sysexts), `docs/integration-contracts.md`
   §4.4 and the layout line at 384, `docs/native-ab-contracts.md:141`
   (`ext/<name>/` is no longer a frozen namespace), README, CLAUDE.md
   "Sysext Constraints", a snosi ADR "sysexts publish to GHCR", and a
   `.memory/corrections.jsonl` entry recording that R2 never pruned and
   never compressed.
8. **Frostyard/core.** Amend ADR-0009 (sysexts move to
   `ghcr.io/frostyard/sysext/<name>`; other namespaces unchanged) and
   ADR-0010 (sysexts no longer go through repogen; retention is automated
   for that namespace only), plus a line in `docs/org-adrs.md`. ADR-0014 is
   unchanged: the same key signs the index.

## Sibling repositories

- **repogen:** no change required. Its sysext generator simply stops being
  called by snosi. Optional follow-up: delete the `sysext` package type once
  no other repo uses it (grep the org first). The 30 `himmelblau` versions
  on R2 predate the sysext's removal and 2026-09 reinstatement in snosi;
  they were published by snosi, not an external publisher, and are ordinary
  prune candidates.
- **chairlift:** its `go.mod` pin of `github.com/frostyard/updex v1.5.0`
  is stale, not a deliberate choice. Bump it to `v2.1.0` and release before
  any image ships `Type=oci` transfers; otherwise its features list silently
  omits every sysext. Budget for API work: the 2.0.0 major sits between the
  pin and the target, so `chairlift/internal/updex/updex.go:102-118` may
  need changes beyond the version edit.
- **pilothouse and snosi-firstboot:** CLI consumers; unaffected once the
  deb updates.
- **Firn:** does not touch `ext/`; unaffected.

## Rollout phases

### Phase 0 — Stop the bleeding (days)

- Land `CompressOutput=zstd` for sysexts.
- Run the R2 prune runbook once (keep last 3 per sysext), rewrite and
  re-sign each `SHA256SUMS`, confirm with `updex features check` on a
  current image.
- **Done when:** `ext/` measures under 20 GiB and a fresh publish adds a
  `.raw.zst`.

### Phase 1 — updex 2.1.0 with `Type=oci` (1-2 weeks)

- Registry client, source dispatch, tests, docs, ADR, release to apt.
- chairlift bumps its SDK pin and releases.
- **Done when:** on a current snosi image with 2.1.0 installed from apt, a
  hand-written `/etc/sysupdate.test.d/test.transfer` with `Type=oci`
  against a manually pushed test package installs, verifies the index
  signature, links, and refreshes; and `Verify=true` with a tampered index
  fails closed.

### Phase 2 — Dual publication (one release cycle)

- `build.yml` gains `publish-sysexts` and pushes to GHCR **while the R2
  step keeps running**. Transfer files still say `url-file`.
- **Done when:** every one of the 27 packages exists under
  `ghcr.io/frostyard/sysext/*` with a verified `index`, and
  `test/sysext-ghcr-publish-test.sh` is green in `validate.yml`.

### Phase 3 — Switch consumers (next base image)

- Bump the updex sentinel, flip the 27 transfer files to `Type=oci`, add the
  finalize version assertion and the static pins. Ship base/snow/snowfield/
  floe (bootc) and the native profiles.
- **Done when:** `test/tests/03-sysexts.sh` on a fresh bootc install runs
  `updex features check --json` against GHCR and a `features enable
  tailscale --now` merges; `snosi-firstboot`, pilothouse, and chairlift list
  features on that image.

### Phase 4 — Retire R2 `ext/` (after the last url-file image is off the fleet)

- Remove the `publish-to-r2` and `manifests/` steps from `build.yml`, drop
  the R2 sysext secrets from that workflow, enable `prune-sysexts.yml`,
  amend core ADR-0009/0010.
- Images that predate Phase 3 keep reading R2 until they update the OS, so
  keep the pruned `ext/` prefix online (a few GiB) for one more support
  window, then delete it. The native A/B EOL (2026-09-30, ADR-0015) bounds
  how long native images with `url-file` transfers must be served.
- **Done when:** `ext/` is deleted from `frostyardrepo`, the bill line for
  the bucket reflects only apt, native, and ISO objects, and
  `docs/native-ab-contracts.md` no longer lists `ext/`.

### Phase 5 — Optional: catalogs on GHCR

- Extend updex's catalog renderer/validator to emit `Type=oci`.
- **Done when:** a `.catalog` repo can point `updex catalog add` at a GHCR
  namespace.

## Risks and open questions

- **GHCR anonymous rate limits** are not published; a fleet polling 27
  indexes hourly is far below any realistic threshold, but `updex features
  check` should keep treating `429` as transient (it does) and the index
  fetch should honor `ETag`/`If-None-Match` to make repeated checks cheap.
- **GHCR free tier is "currently free" for public container storage** and
  GitHub reserves the right to change it with notice. The design keeps the
  transfer files as the only coupling, so a move to any other OCI registry
  is a `Path=` rewrite plus one image release.
- **A private package** (for a paid or internal sysext) needs the
  credentials branch of the registry client and a place to put
  `auth.json` on an immutable image; out of scope for the 27 public ones.
- **`index` is a moving tag.** Two concurrent `build.yml` runs could race
  on it. `build.yml`'s `concurrency` group already serializes runs per ref;
  the publisher should additionally `oras manifest fetch` the index digest
  before and compare after regeneration, failing the job on a change.
- **Layer size.** The largest sysext is 1.7 GiB uncompressed; GHCR accepts
  multi-GiB layers (the bootc images are larger). Compression makes this
  moot.
- **updex 2.x API vs chairlift 1.5.0.** chairlift's pin is simply stale;
  if the 2.0.0 major changed SDK signatures, its bump is real work rather
  than a version edit and belongs in Phase 1's critical path.
