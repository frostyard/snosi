# Remove Snap Support

## Summary

Remove all Snap/snapd integration from the snow desktop images. Snap support is confined to 4 files under the snow profile — no sysexts, scripts, or CI workflows are affected.

## Changes

### 1. Delete `shared/snow/tree/usr/lib/systemd/system/snap.mount`

Systemd mount unit that bind-mounts `/var/lib/snapd/snap` to `/snap`. With snapd removed, this unit has no purpose.

### 2. Delete `shared/snow/tree/usr/lib/tmpfiles.d/snapd.conf`

Tmpfiles rule that creates `/var/lib/snapd/snap` at boot. No longer needed without snapd.

### 3. Edit `shared/packages/snow/mkosi.conf`

Remove the Snap package group (lines 144-146):

```diff
-# Snap
-Packages=snapd
-         squashfs-tools
```

`squashfs-tools` is only present as a snap dependency. If another package needs it, apt will pull it automatically.

### 4. Edit `shared/snow/tree/usr/share/glib-2.0/schemas/zz0-01-snowlinux-desktop.gschema.override`

Remove `snap-store_snap-store.desktop` from the AppStores folder. Keep the folder with `bbrew.desktop` as the sole entry.

```diff
-apps=['bbrew.desktop', 'snap-store_snap-store.desktop']
+apps=['bbrew.desktop']
```

## Scope

- **Affected profiles:** snow, snowloaded, snowfield, snowfieldloaded (all inherit from the snow package set)
- **Not affected:** base image, all 8 sysexts, CI workflows, build scripts
- **No migration needed:** snap packages installed at runtime by users are stored in `/var/lib/snapd/`, which is user-writable state outside the image. Users who had snaps installed will need to reinstall those applications via flatpak or apt after updating.
