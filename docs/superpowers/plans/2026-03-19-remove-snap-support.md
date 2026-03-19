# Remove Snap Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove all Snap/snapd integration from the snow desktop images.

**Architecture:** Pure subtraction — delete 2 files and edit 2 files. All changes are under `shared/snow/` and `shared/packages/snow/`. No new files, no code, no tests (mkosi config changes).

**Spec:** `docs/superpowers/specs/2026-03-19-remove-snap-support-design.md`

---

### Task 1: Remove snapd systemd units and tmpfiles config

**Files:**
- Delete: `shared/snow/tree/usr/lib/systemd/system/snap.mount`
- Delete: `shared/snow/tree/usr/lib/tmpfiles.d/snapd.conf`

- [ ] **Step 1: Delete snap.mount**

```bash
rm shared/snow/tree/usr/lib/systemd/system/snap.mount
```

This is the systemd mount unit that bind-mounts `/var/lib/snapd/snap` to `/snap`.

- [ ] **Step 2: Delete snapd.conf tmpfiles rule**

```bash
rm shared/snow/tree/usr/lib/tmpfiles.d/snapd.conf
```

This is the tmpfiles.d rule that creates `/var/lib/snapd/snap` at boot.

- [ ] **Step 3: Commit**

```bash
git add -u shared/snow/tree/usr/lib/systemd/system/snap.mount shared/snow/tree/usr/lib/tmpfiles.d/snapd.conf
git commit -m "chore: remove snap systemd mount unit and tmpfiles config"
```

### Task 2: Remove snapd packages and desktop reference

**Files:**
- Modify: `shared/packages/snow/mkosi.conf:143-146` — remove 4 lines (blank line + comment + 2 packages)
- Modify: `shared/snow/tree/usr/share/glib-2.0/schemas/zz0-01-snowlinux-desktop.gschema.override:17` — remove snap-store from apps list

- [ ] **Step 1: Remove snap package group from mkosi.conf**

In `shared/packages/snow/mkosi.conf`, delete lines 143-146 (the blank line before `# Snap`, plus the 3-line snap group). This leaves a single blank line (the existing line 147) between the Container Dependencies and diffoscope diffs sections:

```diff
          passt
-
-# Snap
-Packages=snapd
-         squashfs-tools

 # diffoscope diffs
```

- [ ] **Step 2: Remove snap-store from GNOME app folder**

In `shared/snow/tree/usr/share/glib-2.0/schemas/zz0-01-snowlinux-desktop.gschema.override`, change line 17:

```diff
-apps=['bbrew.desktop', 'snap-store_snap-store.desktop']
+apps=['bbrew.desktop']
```

- [ ] **Step 3: Commit**

```bash
git add shared/packages/snow/mkosi.conf shared/snow/tree/usr/share/glib-2.0/schemas/zz0-01-snowlinux-desktop.gschema.override
git commit -m "chore: remove snap packages and desktop store reference"
```

### Task 3: Verify no remaining snap references

- [ ] **Step 1: Search for any remaining snap references**

```bash
grep -ri 'snapd\|snap-store\|snap\.mount' shared/ mkosi.images/ mkosi.profiles/
```

Expected: no output (zero matches).

Note: `gnome-snapshot` in `saved-unused/` and `squashfs-tools` in `shared/packages/virt-base/` (for Incus) are unrelated to Snap and should be ignored.
