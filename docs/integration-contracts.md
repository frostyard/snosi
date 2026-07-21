# Frostyard Integration Contract Map

This document maps every integration point between the Frostyard tools that
ship in (or produce) snosi images, and the explicit and implicit contracts at
each boundary. It exists because these contracts are mostly *implicit* —
serialization shapes, exit codes, text-table columns, filename grammars, and
`key=value` file formats that no single schema enforces — and a drift in any
one of them breaks a consumer in another repository silently.

The prompting incident: `pilothouse` expected an empty array `[]` from
`updex features check --json` when no sysext updates were available, but updex
emits `null` (Go nil-slice serialization). This document catalogs that bug and
every other place the same class of hazard exists.

**Fragility legend:** 🔴 fragile (implicit, unversioned, easy to break) ·
🟡 watch (partially enforced or asymmetric) · 🟢 robust (schema-checked or
type-safe on both ends).

Every claim carries a `repo/path:line` reference. Paths are relative to the
Frostyard workspace root (the parent of `snosi/`).

---

## 1. Tool inventory

### Frostyard-authored tools installed by snosi

| Tool | Package | Where declared | Scope |
|---|---|---|---|
| nbc | `frostyard-nbc` | `snosi/mkosi.images/base/mkosi.conf:44` | all images (legacy updater) |
| updex | `frostyard-updex` | `snosi/mkosi.images/base/mkosi.conf:45` | all images (sysext feature/update manager) |
| chairlift | `frostyard-chairlift` | `snosi/shared/packages/snow/mkosi.conf:6` | snow, snowfield (+ `-ab`) |
| igloo | `frostyard-igloo` | `snosi/shared/packages/snow/mkosi.conf:7` | snow, snowfield (+ `-ab`) |
| snow-first-setup | `snow-first-setup` | `snosi/shared/packages/snow/mkosi.conf:8` | snow, snowfield (+ `-ab`) |
| intuneme | `frostyard-intuneme` | `snosi/shared/packages/snow/mkosi.conf:67` | snow, snowfield (+ `-ab`) |
| bootc | `bootc` | `snosi/shared/packages/bootc/mkosi.conf:4` | bootc profiles (cayo, snow, snowfield) |
| ostree | `libostree-1-1` | `snosi/shared/packages/bootc/mkosi.conf:5` | bootc profiles |
| pilothouse | `frostyard-pilothouse` | `snosi/mkosi.images/pilothouse/mkosi.conf:23` (sysext) | opt-in sysext, all products |

`pilothouse` is the **only** Frostyard-authored sysext (all 17 other sysexts
wrap third-party tools). It is a pinned GitHub-release `.deb`
(`snosi/shared/download/sysext-checksums.json:37-40`,
`snosi/mkosi.images/pilothouse/mkosi.postinst.chroot:8-17`), not an APT install.

### Producing repositories

| Repo | Produces | Consumed by |
|---|---|---|
| `updex` | `frostyard-updex` deb + Go SDK | snosi scripts, chairlift, pilothouse |
| `pilothouse` | `frostyard-pilothouse` deb (sysext) | end users (web UI) |
| `chairlift` | `frostyard-chairlift` deb (GTK app) | end users |
| `first-setup` | `snow-first-setup` deb (+ `core.json`) | snosi-firstboot |
| `nbc` | `frostyard-nbc` deb | snosi legacy timer units |
| `bootc-debian` | `bootc`, `libostree-1-1` debs | snosi bootc profiles |
| `repogen` | APT repo layout + sysext repo layout at `repository.frostyard.org` | snosi APT sources + `.transfer` files |
| `snosi` | native OS + installer-ISO layout at `repository.frostyard.org` | snosi `.transfer` files, installer redirect Worker |

`igloo` and `intuneme` have **no** update/sysext/native-OS integration
(confirmed exhaustively) — they are Incus-container tools. They are listed for
completeness and excluded from the contract catalog below.

---

## 2. Producer → consumer edge list

```
updex ──CLI(--json)──────────► pilothouse   (features check / list / update / enable / disable)
updex ──Go SDK───────────────► chairlift    (Features / CheckFeatures / Enable / Disable / UpdateFeatures)
updex ──CLI(--json)──────────► snosi-firstboot (features list --json, features enable --now)
updex ──.feature/.transfer───► systemd-sysupdate + updex itself (component discovery)

systemd-sysupdate ──CLI──────► snosi-sysupdate-stage, snosi-update-status
systemd-sysext ──CLI(--json)─► pilothouse

bootc ──status --format json─► bootc-update-stage, snosi-update-status, chairlift
nbc ──CLI(update)────────────► snosi nbc-update-download.service

/run/snosi/update-check   ──► snosi-update-status, motd hook 86
/run/snosi/update-staged  ──► snosi-update-status, bootc-update-notify, motd hook 86
   (written by bootc-update-stage AND snosi-sysupdate-stage)

core.json (first-setup) ─────► snosi-firstboot (flatpak core set)
features.json (snosi build)──► snosi-install --print-features ──► setup-gui model.py
first-boot.json (installer)──► snosi-firstboot
snosi-install --*-json ──────► setup-gui model.py

repogen APT layout ──────────► snosi APT sources
repogen sysext layout ───────► snosi sysext .transfer files
snosi native/ISO layout ─────► snosi OS/ISO .transfer files + installer redirect Worker
```

---

## 3. Serialization hazards — the `null` vs `[]` class

This is the highest-value section. Go serializes a **nil slice** (`var x []T`)
as `null` and an **allocated empty slice** (`x := []T{}` / `make([]T, 0)`) as
`[]`. A consumer that unmarshals into a typed slice tolerates both; a consumer
that hand-validates "is this an array?" or another language's parser may not.

### 3.1 The updex `features check` / `features update` bug (root cause)

`CheckFeatures` and `UpdateFeatures` declare their top-level result as a **nil
slice** and return it unmodified when no enabled feature yields a result:

```go
// updex/updex/features.go:465
var allResults []CheckFeaturesResult
...
// updex/updex/features.go:531
return allResults, nil
```

```go
// updex/updex/features.go:364
var allResults []UpdateFeaturesResult
```

The CLI encodes this directly (`updex/cmd/updex/features_run.go:206-212`) through
Go's indent encoder (`clix@v0.3.0/output.go:14-30`). Result:

```sh
updex --silent -C /empty-dir features check --json
# null       ← NOT []
```

By contrast, `features list` and `components` are **safe** — they explicitly
allocate:

```go
// updex/updex/features.go:34-37    (Features)
if len(features) == 0 {
    return []FeatureInfo{}, nil
}
// updex/updex/domain.go:110        (Components)
infos := make([]ComponentInfo, 0, len(components))
```

**Second-order hazard (nested):** even when the top-level array is non-empty,
`CheckFeaturesResult.Results` / `UpdateFeaturesResult.Results` have plain
`json:"results"` tags (no `omitzero`, `updex/updex/results.go:29-33`) and are
appended to a nil slice. A feature with transfers but no matching manifest
versions produces `{"feature":"x","results":null}`.

**Contract summary for updex CLI JSON:**

| Command | Empty output | Fragility |
|---|---|---|
| `features list --json` | `[]` | 🟢 |
| `components --json` | `[]` | 🟢 |
| `features check --json` | `null` (top-level and nested) | 🔴 |
| `features update --json` | `null` (top-level and nested) | 🔴 |
| `features enable/disable --json` | JSON object (or exit 1 with no object on non-root) | 🟡 |

**Recommended upstream fix (updex):** initialize both top-level slices with
`make([]T, 0)` and initialize `featureResult.Results` before the inner loop.
This makes empty results `[]` uniformly and matches `features list`.

### 3.2 pilothouse — inbound fixed, outbound still nil

pilothouse consumes `updex -C <dir> --json features check`
(`pilothouse/internal/modules/sysext/manager.go:106-129`). The inbound bug was
fixed in **v0.2.1**, commit `c2d1a17`:

```go
// pilothouse/internal/modules/sysext/manager.go:349-351
if bytes.Equal(trimmed, []byte("null")) {
    return nil, nil          // terminal null == no updates
}
```

Regression test asserts *semantic* emptiness, not non-nilness
(`pilothouse/internal/modules/sysext/manager_test.go:50-57`).

**But the same class of bug is pushed one hop downstream.** pilothouse
re-emits its own maintenance state over the broker, and `Updates` is a plain
slice fed a possibly-nil value:

```go
// pilothouse/internal/modules/maintenance/manager.go:36
Updates []sysext.AvailableUpdate `json:"updates"`
// manager.go:84 — available may be nil
state := State{Jobs: make([]Job, 0, ...), OSVersion: ..., Updates: available}
```

So the broker query `org.frostyard.pilothouse.maintenance.state` returns
`{"updates":null}` when there are no updates. The server-rendered HTMX UI uses
`len(state.Updates)` and doesn't care, but any JSON consumer of the broker
would face the identical `null`-vs-`[]` problem updex just handed pilothouse.
🟡 — self-consistent today, latent for future consumers.

**Asymmetry to note:** pilothouse's `features list` parser does **not** accept
`null` (`manager.go:319-336`) — only `features check` does. If updex ever
regressed `features list` to nil, pilothouse would fail there with
`"feature array missing from updex output"`. 🟡

### 3.3 chairlift — type-safe via Go SDK (immune)

chairlift links the **updex Go library at v1.3.0** and calls
`Features` / `CheckFeatures` / `EnableFeature` / etc. directly
(`chairlift/internal/updex/updex.go:102-118`). It never parses updex's JSON —
it consumes the returned Go values with `len()` and `for range`, both nil-safe
(`chairlift/internal/views/features_page.go:96-99,145-159`). 🟢

Mutations go through `pkexec chairlift-updex-helper`
(`chairlift/internal/updex/updex.go:138-172`); the helper emits JSON but the
caller **ignores stdout** and uses only exit code + stderr — so helper
output-shape drift can't break the GUI. 🟢 (though see §7 for a PolicyKit
action-ID mismatch that is a separate latent issue).

### 3.4 snosi's own JSON contracts — the positive pattern

These got it right and are the standard the ecosystem should adopt:

- **`first-boot.json` producer forces `[]`, never null:**
  `snosi/shared/native-installer/tree/usr/libexec/snosi-install:959-967` emits
  `features_json="[]"` explicitly when empty.
- **`features.json` publication enforces array type:**
  `snosi/shared/native-ab/publish/prepare-native-publication.sh:301-302`
  fails the build unless `.features | type == "array"`.
- **setup-gui rejects null/missing arrays:**
  `snosi/shared/native-installer/setup-gui/setup_gui/model.py:146-148`
  raises unless `isinstance(feats, list)`.
- **`--list-disks-json` top-level is always an array**, `refusal: null` is a
  meaningful sentinel (installable):
  `snosi/shared/native-installer/tree/usr/libexec/snosi-install:157-163`.

---

## 4. Integration point catalog

Each entry: **Producer** → **Consumer**, transport, contract, fragility.

### 4.1 updex CLI JSON → pilothouse
- **Producer:** `updex` (v1.3.0+), commands `features check/list/update/enable/disable`.
- **Consumer:** `pilothouse/internal/modules/sysext/manager.go` (both web and broker processes).
- **Transport:** subprocess, `--json`, stdout parsed as a *stream* of JSON values (allows progress records before the array). `SYSTEMD_PAGER=cat` forced.
- **Contract:** `features check` → array of `{feature, results:[{component,current_version,newest_version,update_available}]}`; pilothouse filters `update_available==true`. Terminal `null` accepted as empty (post-fix).
- **Fragility:** 🔴 (the historical bug) → 🟡 (fixed inbound; see §3.2 for residual outbound + list asymmetry).

### 4.2 updex Go SDK → chairlift
- **Producer:** `updex` Go module, pinned `v1.3.0` (`chairlift/go.mod:5-11`).
- **Consumer:** `chairlift/internal/updex/updex.go`.
- **Transport:** in-process function calls (read path) + `pkexec` helper (write path, exit-code only).
- **Contract:** SDK signatures `Features/Components/EnableFeature/DisableFeature/UpdateFeatures/CheckFeatures`. Version lockstep matters: chairlift must track updex's SDK API, not just its CLI.
- **Fragility:** 🟢 for shape; 🟡 for version coupling (a breaking SDK change requires a coordinated chairlift bump).

### 4.3 updex CLI JSON → snosi-firstboot
- **Producer:** `updex --silent features list --json` (array of `{name,...}` objects; `[]`-safe when empty, §3.1).
- **Consumer:** `snosi/shared/outformat/ab-root/tree/usr/libexec/snosi-firstboot:59`
  — `jq -r '.[]?.name'` (extract every feature name).
- **Contract:** JSON array of feature objects, each with a `name` field. Empty
  list (`[]`), missing/`null`, or a non-JSON blob from a transient failure all
  collapse to empty `known` via `2>/dev/null || true`, which disables the
  stale-feature pre-check (fail-open). Also depends on
  `updex features enable "$f" --now` exit code (0=ok, nonzero=retry next boot)
  — `snosi-firstboot:67`.
- **Fragility:** 🟢 — array-typed JSON on a stable field; the previous 🔴
  text-table dependency (`awk 'NR>1'` on the header + column 1) was retired in
  favor of `--json` + `jq`.

### 4.4 .feature / .transfer files → updex + systemd-sysupdate
- **Producer:** snosi base image ships `usr/lib/sysupdate.<name>.d/<name>.{feature,transfer}` per sysext (`snosi/mkosi.images/base/mkosi.extra/...`).
- **Consumers:** updex component discovery (`updex/config/component.go:103-145`), systemd-sysupdate `components`.
- **Contract:**
  - Component dir grammar `sysupdate.<name>.d`, name `^[a-zA-Z0-9_-]+$` (dotted names ignored).
  - updex reads only `[Feature]` keys `Description`, `Documentation`, `AppStream`, `Enabled` — **unknown keys ignored** (`updex/config/feature.go:166-193`). This is why snosi's `X-Snosi-Products=` is safe (`snosi/shared/outformat/ab-root/finalize/features-catalog.finalize:23-29`).
  - updex only surfaces sysext-shaped transfers: `Source.Type==url-file`, `Target.Type` empty/`regular-file`, no `PathRelativeTo` (`updex/config/transfer.go:202-232`) — this deliberately excludes native OS partition/UKI transfers from the shared `sysupdate.d`.
  - **Minimum updex version for component discovery: v1.3.0.** Older updex reads only legacy `sysupdate.d` and silently drops every component-scoped sysext. This is the release-ordering constraint in `CLAUDE.md`.
  - Enable/disable writes `/etc/sysupdate.<component>.d/<feature>.feature.d/00-updex.conf` (`updex/updex/features.go:83-112`).
- **Fragility:** 🟢 (unknown-key tolerance is verified) with a 🟡 release-ordering coupling (updex ≥1.3.0 must ship before base images using per-component dirs).

### 4.5 systemd-sysupdate CLI → snosi stagers
- **Producer:** `/usr/lib/systemd/systemd-sysupdate` (`check-new`, `update`, `pending`, `list`, `components`).
- **Consumers:** `snosi/shared/outformat/ab-root/tree/usr/libexec/snosi-sysupdate-stage`, `snosi/mkosi.images/base/mkosi.extra/usr/bin/snosi-update-status`.
- **Contract (implicit, hard-won):**
  - `check-new`: candidate version on **stdout only** (stderr is progress) — capturing `2>&1` corrupts the version. Candidate is the last stdout line, must match `^[0-9]{14}$`. Nonzero exit conflates "nothing newer" with all failures, so snosi disambiguates with an independent signed-index probe (`snosi-sysupdate-stage:177-221`).
  - `pending`: **exit status only** (output discarded), 0 = newer version installed (`snosi-update-status:113-119`).
  - No JSON parsing of sysupdate anywhere; `lsblk -J` is parsed instead for partition accounting (`snosi-sysupdate-stage:119-126`).
- **Fragility:** 🟡 — heavily defended against sysupdate's quirks, but every defense is an implicit contract with a specific systemd version's output behavior.

### 4.6 systemd-sysext CLI JSON → pilothouse
- **Producer:** `systemd-sysext list/status --json=short`.
- **Consumer:** `pilothouse/internal/modules/sysext/manager.go:258-292`.
- **Contract:** unmarshaled into typed Go structs; `null`→nil→empty-map is tolerated. 🟢

### 4.7 bootc status JSON → three consumers
- **Producer:** `bootc status --format json`.
- **Consumers:** `bootc-update-stage:38-50`, `snosi-update-status:206-208`, `chairlift/internal/bootc/bootc.go:112-171`.
- **Contract:** object with `spec.image.{image,transport}` and `status.{booted,staged,rollback}.image.imageDigest`; missing→empty via `// empty`. chairlift treats `status.booted: null` (with exit 0) as "not a bootc system". post-stage digest must exactly match the podman-pulled digest (bootc `switch` to identical spec is a silent no-op — `bootc-update-stage:121`). 🟢 (typed, defensively parsed).

### 4.8 nbc CLI → snosi legacy timer
- **Producer:** `nbc update --download-only` (`nbc/cmd/update.go:203-290`).
- **Consumer:** `snosi/mkosi.images/base/mkosi.extra/usr/lib/systemd/system/nbc-update-download.service:12-14`, gated `ConditionKernelCommandLine=!composefs`.
- **Contract:** exit 0 including "already current" and "not nbc-managed (composefs detected)" — nbc self-detects composefs and no-ops with exit 0 (`nbc/pkg/update.go:72-92`). Nonzero = real failure. Text output is human-facing; `--json` is JSON-Lines except `update --check --json` which is one object. 🟢

---

## 5. State-file & filesystem contracts

### 5.1 `/run/snosi/update-check` (key=value)
Written by **both** stagers with identical field order:
```
outcome=<current|staged|failed|held-rollback>
checked_at=<iso-8601>
image=<image/channel>
running_version=<version or empty>
remote_version=<version or empty>
```
- bootc producer: `bootc-update-stage:26-31` (all four outcomes; `held-rollback` is bootc-only).
- native producer: `snosi-sysupdate-stage:74-79` (`current`/`staged`/`failed` only — no `held-rollback` on native, deliberately).
- Consumers: `snosi-update-status` (`key()` sed extractor, empty-tolerant), motd hook `86-bootc-update-staged`.
- **Fragility:** 🟡 — plain sed field extraction; robust to missing fields, but field-name drift is silent.

### 5.2 `/run/snosi/update-staged` (key=value, transport-tagged)
```
# bootc shape                 # native shape
image=<ref>                   image=<channel>
digest=sha256:<hex>           version=<14-digit>
staged_at=<iso-8601>          staged_at=<iso-8601>
```
- **Cross-transport invariant:** exactly one of `digest=` / `version=` is present.
- Producers: `bootc-update-stage:81-85`, `snosi-sysupdate-stage:97-101`.
- Consumers key off whichever exists: `bootc-update-notify:26-29` (`id="${digest:-$version}"`), motd hook `86:23-26`, `snosi-update-status`. The native stager also re-reads its own file (`snosi-sysupdate-stage:207-209`) — so it must find `version=`, not `digest=`.
- **Fragility:** 🔴 — the invariant is a convention with no enforcement; a producer emitting both (or the wrong one for its transport) would confuse consumers that prefer `digest`.

### 5.3 Other filesystem contracts
- `/var/lib/extensions.d/` — sysext download target; `/var/lib/extensions/` — sysext discovery symlinks (updex writes, `systemd-sysext refresh` reads).
- `/etc/sysupdate.<name>.d/<feature>.feature.d/00-updex.conf` — updex enable/disable drop-in (also the whole-file test-override mechanism for `.transfer`).
- `/run/pilothouse/broker.sock` — HTTP-over-Unix between pilothouse web and broker (see §6).
- `/run/reboot-required`, `/proc/uptime`, `/etc/os-release` (`PRETTY_NAME`, `IMAGE_VERSION`) — pilothouse maintenance inputs (`pilothouse/internal/modules/maintenance/manager.go:86-173`).

---

## 6. JSON file contracts (installer / first-boot / catalog)

### 6.1 `core.json` (first-setup → snosi-firstboot)
- **Producer:** `first-setup/snow_first_setup/core.json`, installed to `/usr/share/org.frostyard.FirstSetup/snow_first_setup/core.json` (`first-setup/snow_first_setup/meson.build:34-45`).
- **Shape:** `{"core":[{"name":"<label>","id":"<flatpak-id>"}]}`.
- **Consumer:** `snosi-firstboot:85` reads only `.core[].id`, `sort -u` (duplicates tolerated by design). `name` ignored.
- **Fragility:** 🟢 — single source of truth, dedup-safe.

### 6.2 `first-boot.json` (installer → snosi-firstboot)
- **Producer:** `snosi-install:959-967` — `{"features":[...],"core_flatpaks":bool}`, `features` forced to `[]` (never null).
- **Consumer:** `snosi-firstboot:47,70` — `jq -r '.features[]? // empty'` (absent/null/[] all tolerated), `.core_flatpaks // false`.
- **Fragility:** 🟢 — producer forces array, consumer tolerates all three empties.

### 6.3 `features.json` catalog (snosi build → installer → setup-gui)
- **Producer:** `features-catalog.finalize:47-66` — `{"proto":1,"product":"<id>","features":[{name,description,documentation,default}]}`. Published as `<channel>_<version>.features.json` in the signed `SHA256SUMS`.
- **Consumers:** `snosi-install --print-features` (fetches hash-verified, prints unchanged); `setup-gui model.py:140-149` (rejects non-array `features`).
- **Publication check:** `prepare-native-publication.sh:301` enforces `.features|type=="array"`.
- **Fragility:** 🟢 — array-typed on all ends.

### 6.4 snosi-install command JSON → setup-gui model.py
- `--print-defaults` → `{proto:1, products:[...], defaults, origin_default, mok_cert_default, regexes}`; consumer requires `proto==1` and all five per-product fields (`model.py:41-60`). 🟢
- `--list-disks-json` → array, `refusal:null`==installable (`snosi-install:157-163`, `model.py:107-123`). 🟢
- `--print-features` → §6.3. 🟢
- `--json-progress` → line-delimited events `start/phase/log/error/done` (proto 1); consumer ignores unknown events and does **not** enforce `proto==1` on progress lines (forward-compatible by design, `model.py:375-438`). 🟢

---

## 7. Naming & signing contracts (repository.frostyard.org)

### 7.1 APT (repogen → snosi APT sources)
- Layout: `dists/stable/{InRelease,Release,Release.gpg}`, `dists/stable/main/binary-amd64/{Packages,Packages.gz}`, `pool/main/<letter>/<name>/*.deb` (`repogen/internal/generator/deb/generator.go:63-231`).
- Suite `stable`, component `main` (`snosi/mkosi.sandbox/etc/apt/sources.list.d/frostyard.sources`).
- Signing: `InRelease` clear-signed + detached `Release.gpg` with the Frostyard repo GPG key. 🟢

### 7.2 Sysext (repogen → snosi .transfer files)
- Layout: `ext/index`, `ext/<name>/{SHA256SUMS,<name>.transfer,<name>_<version>_<osversion>_<arch>.raw[.zst|.xz|.gz]}` (`repogen/internal/generator/sysext/generator.go:21-364`).
- **Filename grammar:** exactly four `_`-separated non-empty fields — **no field may contain an underscore** (`generator.go:342-353`).
- **Signing posture:** sysext `SHA256SUMS` is **unsigned**; generated transfers are `Verify=false`. This matches snosi's "accepted risk — unsigned sysexts on native installs" (`CLAUDE.md`). 🟡 (accepted risk, documented).

### 7.3 Native OS + ISO (snosi's own pipeline → snosi .transfer files)
- OS layout: `os/native/v1/<product>/x86-64/`, transfers `Verify=yes`, signed `SHA256SUMS.gpg` (`snosi/shared/native-ab/channels/*/tree/usr/lib/sysupdate.d/*.transfer`, `snosi/shared/native-ab/publish/promote.sh:300-313`).
- ISO layout: flat `isos/native/v1/`, frozen name `snosi-native-installer_<14-digit>_x86-64.iso`.
- **Not produced by repogen** — this is snosi's separate publish pipeline (`shared/native-ab/publish/`). 🟢 (signed, schema-checked).

### 7.4 bootc-debian deb versioning
- `<upstream>-frostyard<UTC YYYYMMDDHHMM>` so rebuilds sort newer in APT (`bootc-debian/build.sh:51-55`). Publishes via repogen, then `repository_dispatch` type `build` to snosi. 🟢

### 7.5 chairlift PolicyKit action-ID mismatch (latent)
- The helper exposes `enable-feature`/`disable-feature`/`update` (`chairlift/cmd/chairlift-updex-helper/main.go:29-46`), but the PolicyKit policy XML defines actions `list`/`update`/`vacuum` (`chairlift/data/org.frostyard.ChairLift.updex.policy:11-42`) — no explicit action for enable/disable. 🟡 — worth verifying enable/disable escalation still authorizes as intended.

---

## 8. Recommendations (non-binding, prioritized)

1. **Fix updex at the source (🔴→🟢).** Initialize the top-level slices in
   `CheckFeatures`/`UpdateFeatures` with `make([]T, 0)` and initialize
   `featureResult.Results` before the inner loop (`updex/updex/features.go`).
   This eliminates the `null` at the origin and makes all six list-returning
   commands uniformly `[]`-on-empty. Every downstream workaround becomes
   belt-and-suspenders instead of load-bearing.
2. **Normalize pilothouse broker output (§3.2).** Set
   `maintenance.State.Updates` to `make([]sysext.AvailableUpdate, 0)` so the
   broker never emits `updates:null`. Otherwise the same bug re-emerges for the
   next broker JSON consumer.
3. **Adopt an ecosystem convention:** *producers always emit `[]`, never
   `null`; consumers always accept both.* snosi's `first-boot.json` producer and
   `setup-gui` consumer already model this — hold them up as the standard.
4. **~~Migrate snosi-firstboot off the text table (§4.3).~~ Done** — it now
   uses `updex --silent features list --json` (`[]`-safe) + `jq -r '.[]?.name'`
   instead of `awk 'NR>1'`, removing the 🔴 column/header dependency.
5. **Version-couple carefully:** the updex ≥1.3.0 component-discovery
   requirement (§4.4) and the chairlift↔updex SDK lockstep (§4.2) are ordering
   constraints that need coordinated releases — keep them in each repo's
   release checklist.

---

## 9. Maintenance note

This map is only as good as its references. When any of these change, update
the corresponding section here:
- updex CLI output shapes or SDK signatures (§3.1, §4.1, §4.2)
- pilothouse broker query result structs (§3.2, §6 note)
- the `/run/snosi/*` field sets (§5.1, §5.2)
- the repository layout / filename grammars / signing posture (§7)

Cross-reference: `docs/native-ab-contracts.md` (§3/§4/§5 naming, signing),
`CLAUDE.md` ("Sysext Constraints", "OS Update Staging", "Native A/B Update
UX") for the snosi-internal side of these same contracts.
