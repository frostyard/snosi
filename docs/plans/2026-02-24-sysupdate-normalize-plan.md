# Sysupdate Normalization Implementation Plan

**Status:** Shipped with a changed layout — per-sysext `sysupdate.<name>.d/` drop-in directories replaced the single shared `sysupdate.d/` directory this plan assumed.  
**Last verified:** 2026-08-29

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ensure every sysext has a standalone `<name>.transfer` + `<name>.feature` pair in `mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/`.

**Architecture:** Declarative systemd-sysupdate config files. Each `.transfer` defines how to download a sysext, referencing a `.feature` that controls whether it's enabled. One pair per sysext, consistent naming.

**Tech Stack:** systemd-sysupdate INI-style config files

---

### Task 1: Create 1password-cli.feature

**Files:**
- Create: `mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/1password-cli.feature`

**Step 1: Create the feature file**

```ini
[Feature]
Description=1Password CLI
Documentation=https://frostyard.org
Enabled=false
```

**Step 2: Verify**

Run: `cat mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/1password-cli.feature`
Expected: Content matches above.

**Step 3: Commit**

```bash
git add mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/1password-cli.feature
git commit -m "feat: add sysupdate feature file for 1password-cli"
```

---

### Task 2: Create 1password-cli.transfer

**Files:**
- Create: `mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/1password-cli.transfer`

**Step 1: Create the transfer file**

Follow the pattern from `docker.transfer`. The sysext name is `1password-cli`, source path uses the sysext name as the directory.

```ini
[Transfer]
Features=1password-cli
Verify=false

[Source]
Type=url-file
Path=https://repository.frostyard.org/ext/1password-cli/
MatchPattern=1password-cli_@v_@a.raw.zst \
             1password-cli_@v_@a.raw.xz \
             1password-cli_@v_@a.raw.gz \
             1password-cli_@v_@a.raw

[Target]
Type=regular-file
Path=/var/lib/extensions.d/
MatchPattern=1password-cli_@v_@a.raw.zst \
             1password-cli_@v_@a.raw.xz \
             1password-cli_@v_@a.raw.gz \
             1password-cli_@v_@a.raw
CurrentSymlink=1password-cli.raw
```

**Step 2: Verify**

Run: `cat mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/1password-cli.transfer`
Expected: Content matches above.

**Step 3: Commit**

```bash
git add mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/1password-cli.transfer
git commit -m "feat: add sysupdate transfer file for 1password-cli"
```

---

### Task 3: Create standalone dev.feature and debdev.feature

**Files:**
- Create: `mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/dev.feature`
- Create: `mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/debdev.feature`

**Step 1: Create dev.feature**

```ini
[Feature]
Description=Development Tools
Documentation=https://frostyard.org
Enabled=false
```

**Step 2: Create debdev.feature**

```ini
[Feature]
Description=Debian Development Tools
Documentation=https://frostyard.org
Enabled=false
```

**Step 3: Commit**

```bash
git add mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/dev.feature mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/debdev.feature
git commit -m "feat: add standalone feature files for dev and debdev sysexts"
```

---

### Task 4: Update dev.transfer and debdev.transfer, remove devel.feature

**Files:**
- Modify: `mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/dev.transfer:2` — change `Features=devel` to `Features=dev`
- Modify: `mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/debdev.transfer:2` — change `Features=devel` to `Features=debdev`
- Modify: `mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/debdev.transfer:9` — fix typo `debdevdev` to `debdev`
- Delete: `mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/devel.feature`

**Step 1: Edit dev.transfer**

Change line 2 from `Features=devel` to `Features=dev`.

**Step 2: Edit debdev.transfer**

Change line 2 from `Features=devel` to `Features=debdev`.
Change line 9 from `debdevdev_@v_@a.raw.xz` to `debdev_@v_@a.raw.xz`.

**Step 3: Delete devel.feature**

```bash
git rm mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/devel.feature
```

**Step 4: Verify**

Run: `ls mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/ | sort`
Expected: 14 files — `1password-cli.feature`, `1password-cli.transfer`, `debdev.feature`, `debdev.transfer`, `dev.feature`, `dev.transfer`, `docker.feature`, `docker.transfer`, `incus.feature`, `incus.transfer`, `podman.feature`, `podman.transfer`, `tailscale.feature`, `tailscale.transfer`

**Step 5: Commit**

```bash
git add mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/dev.transfer mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/debdev.transfer
git commit -m "fix: normalize dev/debdev to standalone features, fix debdev typo"
```

---

### Task 5: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md` — add sysupdate requirement to Sysext Constraints section, update sysext count from 6 to 7

**Step 1: Update sysext count**

Line 9: change "6 sysext overlay images" to "7 sysext overlay images" and add `tailscale` to the list.

**Step 2: Add sysupdate requirement**

After the existing Sysext Constraints section (after the tmpfiles bullet), add:

```markdown
Every sysext must have matching `<name>.transfer` and `<name>.feature` files in `mkosi.images/base/mkosi.extra/usr/lib/sysupdate.d/`. The `.transfer` file defines how systemd-sysupdate downloads the sysext; the `.feature` file provides metadata and defaults to `Enabled=false`. Use existing files as templates.
```

**Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add sysupdate file requirement for sysexts, update sysext count"
```
