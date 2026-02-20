# Cayo Ship Design

Ship the cayo server image branch: rebase onto main, audit packages/configs, add cayoloaded, clean up, and squash-merge via PR.

## Context

- `cayo` branch is 1 commit ahead of main (`feat: cayo guess`), main is ~50 commits ahead
- cayo is the server version of snow: no desktop, no GUI
- cayo ships podman; cayoloaded adds docker + incus baked in

## Approach: Rebase & Incremental

Rebase `cayo` onto current `main`, then apply all work as incremental commits. Squash-merge via PR at the end.

## 1. Rebase & Catch Up

Rebase `cayo` onto `main` to pick up all recent commits (CI improvements, package dedup, shell hardening, legacy cleanup). The cayo commit is a pure addition (92 new files), so conflicts should be minimal. Verify CI workflow, Justfile, and .gitignore still include cayo after rebase.

## 2. Package & Config Audit

Moderate audit of cayo's packages and systemd configs for headless server appropriateness.

**Remove obvious mismatches from `shared/packages/cayo/mkosi.conf`:**
- GUI packages (virt-viewer, nm-connection-editor already in RemovePackages)
- Desktop-oriented packages (switcheroo-control for GPU switching)
- Mobile broadband packages (modemmanager, mobile-broadband-provider-info)
- Review the large "Server-relevant diffoscope packages" section (~130 packages) for desktop carry-over

**Review systemd configs in `shared/cayo/tree/`:**
- Verify 30+ unit files and 9 presets make sense for headless server
- Review iwd (WiFi) config relevance

## 3. cayoloaded Profile

Create `mkosi.profiles/cayoloaded/mkosi.conf`: cayo + docker + incus baked into image (not sysexts).

**Refactor virt packages:**
- Split `shared/packages/virt/mkosi.conf` into:
  - `shared/packages/virt-base/mkosi.conf` - headless incus (no GUI packages)
  - `shared/packages/virt/mkosi.conf` - includes virt-base + GUI packages (virt-viewer, qemu-system-gui, qemu-system-modules-spice)
- snowloaded uses full `virt` (with GUI)
- cayoloaded uses `virt-base` (headless)

**Docker in cayoloaded:**
- Include docker packages directly: docker-ce, docker-ce-cli, containerd.io, docker-buildx-plugin, docker-compose-plugin, docker-ce-rootless-extras
- Include docker systemd config (presets, sysusers, tmpfiles from docker sysext)

**Incus in cayoloaded:**
- Include `shared/packages/virt-base/mkosi.conf` for headless incus
- Include incus tree for presets/sysusers

## 4. Cleanup

**Shell script hardening:**
- Apply `set -euo pipefail` to cayo scripts
- Use `mktemp` patterns, add trap cleanup

**Package deduplication:**
- Run `check-duplicate-packages.sh` against cayo packages
- Remove packages already in base

**CI updates:**
- Add `cayoloaded` to build matrix in `.github/workflows/build-images.yml`
- Add `cayoloaded` target to `Justfile`
- Add `.gitignore` entry for cayoloaded homebrew cache

**README:**
- Add cayo and cayoloaded to image documentation

## 5. Ship

- Run full lint/validation pass
- Push rebased + cleaned branch
- Create PR targeting main with squash-merge
- PR summarizes: cayo server image, cayoloaded (server + docker + incus), virt refactor, package audit, cleanup
