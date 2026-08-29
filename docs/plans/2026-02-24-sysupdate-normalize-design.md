# Normalize sysupdate transfer and feature files

**Status:** Shipped with a changed layout — every sysext now owns a drop-in directory (`mkosi.images/base/mkosi.extra/usr/lib/sysupdate.<name>.d/<name>.transfer`) instead of the single shared `sysupdate.d/` this doc assumed.  
**Last verified:** 2026-08-29

## Problem

Not all sysexts defined in `mkosi.images/` have corresponding sysupdate `.transfer` and `.feature` files in `mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/`. The `1password-cli` sysext is missing both files entirely, and `dev`/`debdev` share a grouped `devel.feature` rather than having standalone feature files.

There is also a typo in `debdev.transfer` line 9: `debdevdev_@v_@a.raw.xz` should be `debdev_@v_@a.raw.xz`.

## Design

Normalize so every sysext has exactly one `<name>.transfer` + `<name>.feature` pair.

### New files

- `1password-cli.transfer` - Features=1password-cli, source https://repository.frostyard.org/ext/1password-cli/
- `1password-cli.feature` - Description=1Password CLI, Enabled=false
- `dev.feature` - Description=Development Tools, Enabled=false
- `debdev.feature` - Description=Debian Development Tools, Enabled=false

### Edits

- `dev.transfer` - change Features=devel to Features=dev
- `debdev.transfer` - change Features=devel to Features=debdev, fix debdevdev typo

### Deletions

- `devel.feature` - replaced by standalone dev.feature and debdev.feature

### Documentation

- Update CLAUDE.md to document that every sysext must have matching .transfer and .feature files

## Result

14 files total (7 transfer + 7 feature), one pair per sysext:
1password-cli, debdev, dev, docker, incus, podman, tailscale
