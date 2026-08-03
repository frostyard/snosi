# Pilothouse Backend Configuration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve Pilothouse's four Cayo backend integrations after their default-off change and fail sysext builds before installation when a direct DEB declares an unsatisfied runtime dependency.

**Architecture:** A vendor systemd drop-in replaces only `pilothoused.service`'s `ExecStart`, retaining the Debian package arguments while explicitly configuring Updex, Podman, Docker, and Incus. A reusable shell helper delegates complete Debian dependency expressions to `dpkg-checkbuilddeps`; an always-runnable fixture test validates both contracts without requiring a sysext build or live endpoints.

**Tech Stack:** Bash, systemd unit drop-ins, `dpkg-deb`, `dpkg-checkbuilddeps`, GitHub Actions.

## Global Constraints

- Preserve any concurrent Pilothouse 0.7.0 URL, checksum, version, and dependency edits; re-read touched files before each patch.
- Configure exactly one each of `--updex`, `--podman-socket`, `--docker`, and `--incus`.
- Preserve exactly one each of `--socket`, `--socket-group`, and Debian `--admin-group sudo`.
- Backend flags permit bounded probes only; unavailable endpoints must not become startup dependencies.
- Dependency validation must run after verified download and before `dpkg -i`.
- Missing dependencies must fail the build rather than be installed implicitly into the sysext delta.
- Do not claim live Cayo capability validation unless a live Cayo test is run.
- Do not commit unless the user explicitly requests a commit.

---

### Task 1: Add the Failing Pilothouse Contract Test

**Files:**
- Create: `test/pilothouse-sysext-test.sh`
- Modify: `.github/workflows/validate.yml:147-164`

**Interfaces:**
- Consumes: the planned drop-in at `mkosi.images/pilothouse/mkosi.extra/usr/lib/systemd/system/pilothoused.service.d/10-snosi-backends.conf`, the manifest at `mkosi.images/pilothouse/required-paths.txt`, and `assert_deb_dependencies_satisfied DEB_PATH` from Task 2.
- Produces: an always-runnable regression gate covering the service command and direct-DEB dependency helper.

- [ ] **Step 1: Create the failing fixture test**

Create `test/pilothouse-sysext-test.sh` with this structure:

```bash
#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
dropin="$repo_root/mkosi.images/pilothouse/mkosi.extra/usr/lib/systemd/system/pilothoused.service.d/10-snosi-backends.conf"
required_paths="$repo_root/mkosi.images/pilothouse/required-paths.txt"
dependency_helper="$repo_root/shared/download/deb-dependencies.sh"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/pilothouse-sysext-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

assert_count() {
    local expected=$1 pattern=$2 file=$3
    local actual
    actual=$(grep -Ec -- "$pattern" "$file" || true)
    if [[ "$actual" -ne "$expected" ]]; then
        printf 'expected %s match(es) for %s in %s, found %s\n' \
            "$expected" "$pattern" "$file" "$actual" >&2
        exit 1
    fi
}

grep -qx '/usr/lib/systemd/system/pilothoused.service.d/10-snosi-backends.conf' "$required_paths"
assert_count 1 '^ExecStart=$' "$dropin"
assert_count 1 '^ExecStart=/usr/bin/pilothoused ' "$dropin"
for argument in \
    '--socket /run/pilothouse/broker.sock' \
    '--socket-group pilothouse' \
    '--admin-group sudo' \
    '--updex /usr/bin/updex' \
    '--podman-socket /run/podman/podman.sock' \
    '--docker unix:///var/run/docker.sock' \
    '--incus'
do
    assert_count 1 "(^|[[:space:]])${argument}([[:space:]]|$)" "$dropin"
done

unit_root="$scratch/root"
unit_dir="$unit_root/usr/lib/systemd/system"
mkdir -p "$unit_dir/pilothoused.service.d" "$unit_root/usr/bin"
cat >"$unit_dir/pilothoused.service" <<'EOF'
[Unit]
Description=Pilothouse privileged broker

[Service]
Type=simple
ExecStart=/usr/bin/pilothoused --socket /run/pilothouse/broker.sock --socket-group pilothouse --admin-group sudo
EOF
cp "$dropin" "$unit_dir/pilothoused.service.d/10-snosi-backends.conf"
touch "$unit_root/usr/bin/pilothoused"
chmod +x "$unit_root/usr/bin/pilothoused"
systemd-analyze verify --root="$unit_root" pilothoused.service

source "$dependency_helper"

build_deb() {
    local name=$1 depends=$2 output=$3
    local root="$scratch/$name"
    mkdir -p "$root/DEBIAN"
    {
        printf 'Package: %s\nVersion: 1.0\nArchitecture: all\nMaintainer: Snosi Test <test@example.invalid>\nDescription: dependency fixture\n' "$name"
        if [[ -n "$depends" ]]; then
            printf 'Depends: %s\n' "$depends"
        fi
    } >"$root/DEBIAN/control"
    dpkg-deb --build "$root" "$output" >/dev/null
}

dpkg_version=$(dpkg-query -W -f='${Version}' dpkg)
build_deb no-dep '' "$scratch/no-dep.deb"
build_deb satisfied "dpkg (>= $dpkg_version) | snosi-never-installed" "$scratch/satisfied.deb"
build_deb unsatisfied 'snosi-deliberately-missing-dependency' "$scratch/unsatisfied.deb"

assert_deb_dependencies_satisfied "$scratch/no-dep.deb"
assert_deb_dependencies_satisfied "$scratch/satisfied.deb"
if assert_deb_dependencies_satisfied "$scratch/unsatisfied.deb"; then
    printf 'expected unsatisfied dependency expression to fail\n' >&2
    exit 1
fi

printf 'pilothouse-sysext-test: PASSED\n'
```

- [ ] **Step 2: Make the test executable and run it to verify the red state**

Run:

```bash
chmod +x test/pilothouse-sysext-test.sh
./test/pilothouse-sysext-test.sh
```

Expected: FAIL because the drop-in and `shared/download/deb-dependencies.sh` do not exist.

- [ ] **Step 3: Wire the test into validation**

Add this step after `Validate sysext required paths finalizer` in `.github/workflows/validate.yml`:

```yaml
      - name: Validate Pilothouse sysext integration
        # Structural service/drop-in and direct-DEB dependency fixtures. No root,
        # network, live endpoints, or image build.
        run: ./test/pilothouse-sysext-test.sh
```

- [ ] **Step 4: Inspect the task diff**

Run `git diff -- test/pilothouse-sysext-test.sh .github/workflows/validate.yml` and verify no concurrent Pilothouse release edits were touched. Do not commit without an explicit user request.

---

### Task 2: Implement Backend and Dependency Contracts

**Files:**
- Create: `mkosi.images/pilothouse/mkosi.extra/usr/lib/systemd/system/pilothoused.service.d/10-snosi-backends.conf`
- Create: `shared/download/deb-dependencies.sh`
- Modify: `mkosi.images/pilothouse/required-paths.txt:10-14`
- Modify: `mkosi.images/pilothouse/mkosi.postinst.chroot:8-17`
- Modify: `mkosi.images/pilothouse/mkosi.conf:17-23`
- Test: `test/pilothouse-sysext-test.sh`

**Interfaces:**
- Consumes: `dpkg-deb`, `dpkg-checkbuilddeps`, and the verified Pilothouse DEB path.
- Produces: `assert_deb_dependencies_satisfied DEB_PATH`, returning zero for an empty or satisfied `Depends` expression and nonzero with a diagnostic for an unsatisfied expression; produces the effective Pilothouse backend command.

- [ ] **Step 1: Add the systemd drop-in**

Create `10-snosi-backends.conf`:

```ini
[Service]
ExecStart=
ExecStart=/usr/bin/pilothoused --socket /run/pilothouse/broker.sock --socket-group pilothouse --admin-group sudo --updex /usr/bin/updex --podman-socket /run/podman/podman.sock --docker unix:///var/run/docker.sock --incus
```

- [ ] **Step 2: Require the drop-in in built artifacts**

Append this exact path beneath the existing service activation paths in `mkosi.images/pilothouse/required-paths.txt`:

```text
/usr/lib/systemd/system/pilothoused.service.d/10-snosi-backends.conf
```

- [ ] **Step 3: Add the reusable dependency helper**

Create `shared/download/deb-dependencies.sh`:

```bash
#!/bin/bash

assert_deb_dependencies_satisfied() {
    local deb=$1
    local dependencies

    dependencies=$(dpkg-deb --field "$deb" Depends)
    if [[ -z "${dependencies//[[:space:]]/}" ]]; then
        return 0
    fi

    if ! dpkg-checkbuilddeps -d "$dependencies"; then
        printf 'DEB dependencies are not satisfied by the buildroot; add the required runtime packages through Packages=: %s\n' \
            "$dependencies" >&2
        return 1
    fi
}
```

Keep the helper source-only: it defines one function and does not execute work when sourced.

- [ ] **Step 4: Guard Pilothouse installation before mutation**

In `mkosi.images/pilothouse/mkosi.postinst.chroot`, source the helper beside `verified-download.sh`, then call it between `verified_download` and `dpkg -i`:

```bash
source "$SRCDIR/shared/download/verified-download.sh"
source "$SRCDIR/shared/download/deb-dependencies.sh"
DEBS=$(mktemp -d)
trap 'rm -rf "$DEBS"' EXIT
verified_download "pilothouse" "$DEBS/pilothouse.deb"
assert_deb_dependencies_satisfied "$DEBS/pilothouse.deb"

# The DEB is installed directly because it is downloaded from GitHub rather
# than an APT repository. Its declared dependencies must already be satisfied
# by the merged buildroot; the guard above fails before dpkg mutates the root
# if Packages= composition drifts behind a new release.
dpkg -i "$DEBS/pilothouse.deb"
```

Retain the existing sysusers/PAM explanation after the dependency paragraph. Do not alter concurrent 0.7.0 dependency declarations.

- [ ] **Step 5: Correct the package rationale**

Replace the stale `no Depends (static Go binaries)` rationale in `mkosi.images/pilothouse/mkosi.conf` with:

```ini
[Build]
# frostyard-pilothouse is downloaded from GitHub rather than an APT repository,
# so mkosi.postinst.chroot installs it directly. Its declared runtime
# dependencies are kept explicit in Packages= (or supplied by the merged base)
# and checked against the buildroot before dpkg mutates it. The postoutput
# script resolves KEYPACKAGE from the merged dpkg database.
Environment=KEYPACKAGE=frostyard-pilothouse
```

If the concurrent 0.7.0 bump has added a `Packages=` list, preserve that list in the same section.

- [ ] **Step 6: Run the focused test to verify green**

Run `./test/pilothouse-sysext-test.sh`.

Expected: the test prints the deliberate missing-dependency diagnostic once, then `pilothouse-sysext-test: PASSED` and exits zero.

- [ ] **Step 7: Run shell syntax checks**

Run:

```bash
bash -n shared/download/deb-dependencies.sh mkosi.images/pilothouse/mkosi.postinst.chroot test/pilothouse-sysext-test.sh
shellcheck shared/download/deb-dependencies.sh mkosi.images/pilothouse/mkosi.postinst.chroot test/pilothouse-sysext-test.sh
```

Expected: both commands exit zero with no diagnostics.

- [ ] **Step 8: Inspect the task diff**

Run `git diff -- mkosi.images/pilothouse shared/download/deb-dependencies.sh test/pilothouse-sysext-test.sh` and verify the concurrent 0.7.0 URL/checksum/version and any required `Packages=` entries remain intact. Do not commit without an explicit user request.

---

### Task 3: Document and Verify the Complete Integration

**Files:**
- Modify: `README.md:45-62,240-257`
- Modify: `CLAUDE.md` in the Sysext Constraints section
- Modify: `yeti/sysexts.md:233-240`
- Modify: `docs/superpowers/specs/2026-08-02-pilothouse-backends-design.md` only if implementation reveals a factual correction
- Test: `.github/workflows/validate.yml`

**Interfaces:**
- Consumes: the service and dependency behavior implemented in Task 2.
- Produces: user-facing and AI-maintainer documentation that states the implemented contract without claiming unrun live validation.

- [ ] **Step 1: Update README integration descriptions**

Change both Pilothouse table descriptions to identify the explicit integrations:

```text
Pilothouse web administration with capability-gated Updex/container backends
```

Near the sysext table, add a concise paragraph stating that the sysext explicitly configures Updex, Podman, Docker, and Incus, while Pilothouse advertises each backend only after its executable/socket probe succeeds. State that unavailable endpoints do not prevent `pilothoused` from starting.

- [ ] **Step 2: Update detailed sysext documentation**

In `yeti/sysexts.md`'s `### pilothouse` section:

- replace the static/no-Depends claim with the direct-download plus pre-install dependency-guard contract;
- document `pilothoused.service.d/10-snosi-backends.conf` and all four exact flags;
- state that the flags opt probes in but do not force registration or startup failure when endpoints are absent; and
- retain the PAM capture, sysusers, preset, and `Upholds=` details.

- [ ] **Step 3: Update maintainer guidance**

Add a focused Pilothouse paragraph to `CLAUDE.md`'s Sysext Constraints section recording:

```text
Pilothouse sysext: Snosi overrides only pilothoused.service ExecStart to retain
the packaged Debian socket/socket-group/sudo-group arguments and explicitly
configure Updex, Podman, Docker, and Incus. These are probe opt-ins, not hard
dependencies; unavailable endpoints remain unregistered and nonfatal. The
GitHub-release DEB's complete Depends expression must pass
assert_deb_dependencies_satisfied before dpkg -i; add newly required runtime
packages through Packages= rather than installing them implicitly.
```

- [ ] **Step 4: Run focused and shared regressions**

Run:

```bash
./test/pilothouse-sysext-test.sh
./test/sysext-required-paths-test.sh
./check-runtime-etc-guard.sh
```

Expected: all three commands print their pass result and exit zero. The Pilothouse fixture may print the expected `dpkg-checkbuilddeps` rejection for its deliberately invalid DEB.

- [ ] **Step 5: Validate workflow and inspect all changes**

Run:

```bash
actionlint .github/workflows/validate.yml
git diff --check
git status --short
git diff -- .github/workflows/validate.yml mkosi.images/pilothouse shared/download/deb-dependencies.sh test/pilothouse-sysext-test.sh README.md CLAUDE.md yeti/sysexts.md docs/superpowers/specs/2026-08-02-pilothouse-backends-design.md docs/superpowers/plans/2026-08-02-pilothouse-backends.md
```

Expected: `actionlint` and `git diff --check` exit zero; status contains only the intended fix, documentation, any preserved concurrent 0.7.0 bump, and pre-existing user changes. Do not commit without an explicit user request.

- [ ] **Step 6: Request adversarial review**

Ask a reviewer to check argument cardinality, Debian dependency-expression handling, systemd drop-in semantics, preservation of the concurrent release bump, and documentation claims. Address only concrete findings, then rerun Steps 4 and 5.

#### Task 3 Execution Report (2026-08-02)

- Added a focused JSON-pin regression assertion before changing the pin. With
  the prior `0.6.0` value, `./test/pilothouse-sysext-test.sh` exited nonzero
  with: `expected pinned Pilothouse version >= 0.7.0, found 0.6.0 in
  /home/bjk/.local/share/opencode/worktree/2cd0bf4157f9240ff9806944b685628cc1149e8b/merry-walrus/shared/download/sysext-checksums.json`.
- Updated only Pilothouse's `url`, `sha256`, and `version` fields to the
  approved 0.7.0 release. `./test/pilothouse-sysext-test.sh` exited zero and
  printed the expected deliberately-unsatisfied fixture diagnostic followed by
  `pilothouse-sysext-test: PASSED`. `dpkg-deb` also printed its existing
  nonfatal unusual-owner warnings for the synthetic fixture roots.
- `jq -e . shared/download/sysext-checksums.json >/dev/null` exited zero.
- `bash -n shared/download/deb-dependencies.sh
  mkosi.images/pilothouse/mkosi.postinst.chroot
  test/pilothouse-sysext-test.sh` exited zero.
- `shellcheck shared/download/deb-dependencies.sh
  mkosi.images/pilothouse/mkosi.postinst.chroot
  test/pilothouse-sysext-test.sh` exited zero with no diagnostics.
- `git diff --check` exited zero with no output.
