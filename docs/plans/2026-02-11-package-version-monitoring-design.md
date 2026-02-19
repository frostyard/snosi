# Package Version Monitoring

Monitor external APT packages for updates and trigger rebuilds automatically.

## Problem

External packages (Edge, VS Code, Docker, 1Password) update independently. Builds only run on push to main, so the images can ship stale versions until the next unrelated commit triggers a rebuild.

## Approach

A daily GitHub Actions workflow queries the external APT repos for latest package versions using a Docker container with the existing `mkosi.sandbox/etc/apt/` configs. When a version change is detected, it commits the updated tracking file to main, which triggers both build workflows.

## Monitored Packages

| Package | APT Source | Consumed By |
|---------|-----------|-------------|
| `microsoft-edge-stable` | packages.microsoft.com/repos/edge | Desktop images |
| `code` | packages.microsoft.com/repos/code | Desktop images |
| `docker-ce` | download.docker.com/linux/debian | Docker sysext |
| `1password-cli` | downloads.1password.com | 1password-cli sysext |

Excluded: Frostyard (we control releases), Linux Surface (kernel-level, managed separately).

## Components

### Version tracking file: `shared/download/package-versions.json`

Sits alongside `checksums.json`. Stores the last-seen candidate version for each monitored package:

```json
{
  "microsoft-edge-stable": "136.0.3240.50-1",
  "code": "1.100.0-1749588012",
  "docker-ce": "5:28.2.2-1~debian.13~trixie",
  "1password-cli": "2.30.3-1"
}
```

This file is purely for change detection. It does not control what gets installed; mkosi always pulls the latest from repos at build time.

### Workflow: `.github/workflows/check-packages.yml`

**Trigger:** Daily cron + `workflow_dispatch` for manual runs.

**Step 1 — Query APT repos via Docker:**

Run a `debian:trixie` container with `mkosi.sandbox/etc/apt/` mounted in. This reuses the existing repo configs and signing keys as the single source of truth.

```yaml
- name: Check latest package versions
  run: |
    docker run --rm \
      -v $PWD/mkosi.sandbox/etc/apt/sources.list.d:/etc/apt/sources.list.d \
      -v $PWD/mkosi.sandbox/etc/apt/keyrings:/etc/apt/keyrings \
      -v $PWD/mkosi.sandbox/etc/apt/trusted.gpg.d:/etc/apt/trusted.gpg.d \
      debian:trixie bash -c '
        apt-get update -qq 2>/dev/null
        for pkg in microsoft-edge-stable code docker-ce 1password-cli; do
          version=$(apt-cache policy "$pkg" | grep Candidate: | awk "{print \$2}")
          echo "$pkg=$version"
        done
      ' > latest-versions.txt
```

**Step 2 — Compare and update:**

Read `latest-versions.txt`, compare each version against `package-versions.json`. Skip any package where the candidate is `(none)` (repo unreachable). If any versions differ, update the JSON and set `has_updates=true`.

**Step 3 — Commit and push:**

If updates were found, commit the updated `package-versions.json` directly to main with a descriptive message listing what changed:

```
chore: update package versions

microsoft-edge-stable: 136.0.3240.50-1 -> 136.0.3240.76-1
```

The push to main triggers both `build.yml` (sysexts) and `build-images.yml` (desktop images) via their existing `push: branches: [main]` trigger.

### Permissions

The workflow needs `contents: write` to push commits directly to main.

## Design Decisions

**Direct commit vs PR:** The existing `check-dependencies.yml` creates a PR via `peter-evans/create-pull-request`. This workflow commits directly because the goal is automatic rebuilds without manual intervention. The tracking file is purely informational — it doesn't affect what gets installed — so there is no risk from an automated commit.

**Docker container vs HTTP parsing:** Mounting the existing `mkosi.sandbox/etc/apt/` configs into a Debian container reuses the repo definitions as a single source of truth. Adding a new external repo to mkosi.sandbox automatically includes it in monitoring. HTTP parsing of `Packages.gz` files would be faster but duplicates repo URLs and is more fragile.

**Trigger both builds:** Rather than mapping packages to specific build workflows, both builds trigger on any update. This is simpler and avoids missed rebuilds if package-to-image mappings change.

**Daily schedule:** App packages like Edge and VS Code update frequently enough that weekly checks (like `check-dependencies.yml`) would leave images stale. Daily strikes the right balance.

## Edge Cases

- **Repo down:** If a repo is unreachable during `apt-get update`, `apt-cache policy` returns `(none)` as candidate. The script skips these to avoid overwriting good data.
- **No changes:** If all versions match, the workflow exits cleanly with no commit.
- **First run:** The `package-versions.json` must be seeded with initial versions. The first workflow run can populate it.
- **Concurrent builds:** Both build workflows have concurrency groups that cancel in-progress runs on new pushes, so rapid back-to-back updates are handled.
