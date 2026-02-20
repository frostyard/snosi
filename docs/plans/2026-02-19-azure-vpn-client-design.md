# Azure VPN Client Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add Microsoft Azure VPN Client to the snowloaded and snowfieldloaded desktop profiles with /opt relocation and patchelf RUNPATH fixes.

**Architecture:** New shared package definition at `shared/packages/azure-vpn-client/` following the Bitwarden/Edge pattern. The .deb is fetched via verified download, installed with dpkg, relocated from `/opt/microsoft/microsoft-azurevpnclient/` to `/usr/lib/microsoft-azurevpnclient/`, and 3 ELF binaries are patched with patchelf to use `$ORIGIN`-relative RUNPATH.

**Tech Stack:** mkosi, patchelf, dpkg, bash, verified-download.sh

---

## Decisions

- **Delivery:** Desktop profile package (shared/packages/), not a standalone sysext
- **RUNPATH fix:** patchelf --set-rpath (not LD_LIBRARY_PATH wrapper)
- **Package source:** Verified download of .deb (not APT repo)
- **Polkit:** Update rule path via sed (not symlink compatibility)
- **rsyslog config:** Skip (logs go to journal)
- **Wrapper script:** None needed (patchelf makes binary directly relocatable)

## Reference Data

**.deb URL:** `https://packages.microsoft.com/ubuntu/22.04/prod/pool/main/m/microsoft-azurevpnclient/microsoft-azurevpnclient_3.0.0_amd64.deb`
**SHA256:** `9e5d360433d1d374d9a1051bb29a65103e81ca74ebeaa35155d1f0e9fc94577b`
**Version:** `3.0.0`

**.desktop file** (original):
```ini
[Desktop Entry]
Version=1.0
Name=Azure VPN Client
GenericName=Azure VPN Client
Comment=Azure VPN client
Path=/opt/microsoft/microsoft-azurevpnclient/
TryExec=/opt/microsoft/microsoft-azurevpnclient/microsoft-azurevpnclient
Exec=/opt/microsoft/microsoft-azurevpnclient/microsoft-azurevpnclient
Icon=/usr/share/icons/microsoft-azurevpnclient.png
Terminal=false
Type=Application
Categories=Utility
StartupWMClass=AzureVpnClient
```

**polkit rules** (original):
```javascript
polkit.addAdminRule(function (action, subject) {
    if ((action.id == "org.freedesktop.resolve1.set-dns-servers" || action.id == "org.freedesktop.resolve1.set-domains") && action.lookup("program") == "/opt/microsoft/microsoft-azurevpnclient") {
        polkit.log("action=" + action);
        polkit.log("subject=" + subject);
        return polkit.Result.YES;
    }
});
```

**Binaries needing RUNPATH patch:**
| Binary | Current RUNPATH | New RUNPATH |
|--------|----------------|-------------|
| `microsoft-azurevpnclient` | `/opt/microsoft/microsoft-azurevpnclient/lib/` | `$ORIGIN/lib` |
| `lib/libLinuxCore.so` | `/opt/microsoft/microsoft-azurevpnclient/lib/` | `$ORIGIN` |
| `lib/libXplatSharedLibrary.so` | `/opt/microsoft/microsoft-azurevpnclient/lib/` | `$ORIGIN` |

---

### Task 1: Add checksums.json entry

**Files:**
- Modify: `shared/download/checksums.json`

**Step 1: Add the azure-vpn-client entry**

Add a new entry to the JSON object in `shared/download/checksums.json`:

```json
"azure-vpn-client": {
  "url": "https://packages.microsoft.com/ubuntu/22.04/prod/pool/main/m/microsoft-azurevpnclient/microsoft-azurevpnclient_3.0.0_amd64.deb",
  "sha256": "9e5d360433d1d374d9a1051bb29a65103e81ca74ebeaa35155d1f0e9fc94577b",
  "version": "3.0.0"
}
```

Insert alphabetically (after `azure-vpn-client` sorts before `bitwarden`).

**Step 2: Validate JSON**

Run: `jq . shared/download/checksums.json`
Expected: Valid JSON output with the new entry.

**Step 3: Commit**

```bash
git add shared/download/checksums.json
git commit -m "chore: add azure-vpn-client to verified downloads"
```

---

### Task 2: Create mkosi.conf for azure-vpn-client package

**Files:**
- Create: `shared/packages/azure-vpn-client/mkosi.conf`

**Step 1: Create the config file**

```ini
[Content]
Packages=patchelf
```

This adds patchelf as a build dependency. The Azure VPN Client itself is installed via verified download in the postinstall script, not via apt Packages=.

Reference pattern: `shared/packages/bitwarden/mkosi.conf` (which declares `Packages=libxss1` as a runtime dep for Bitwarden).

**Step 2: Commit**

```bash
git add shared/packages/azure-vpn-client/mkosi.conf
git commit -m "chore: add azure-vpn-client package config"
```

---

### Task 3: Create postinstall script

**Files:**
- Create: `shared/packages/azure-vpn-client/mkosi.postinst.d/azure-vpn-client.chroot`

**Step 1: Create the postinstall script**

```bash
#!/bin/bash
set -euo pipefail

if [[ "${DEBUG_BUILD:-0}" == "1" ]]; then
    set -x
fi
if [[ "${UID}" == "0" ]]; then
    SUDO=""
else
    SUDO="sudo"
fi

source "$SRCDIR/shared/download/verified-download.sh"
mkdir -p debs
verified_download "azure-vpn-client" "debs/azure-vpn-client.deb"

dpkg -i debs/azure-vpn-client.deb
rm -rf debs

# Relocate from /opt to /usr/lib
${SUDO} mv /opt/microsoft/microsoft-azurevpnclient /usr/lib/microsoft-azurevpnclient
${SUDO} rm -rf /opt/microsoft

# Patch RUNPATH in binaries that hardcode /opt paths
${SUDO} patchelf --set-rpath '$ORIGIN/lib' /usr/lib/microsoft-azurevpnclient/microsoft-azurevpnclient
${SUDO} patchelf --set-rpath '$ORIGIN' /usr/lib/microsoft-azurevpnclient/lib/libLinuxCore.so
${SUDO} patchelf --set-rpath '$ORIGIN' /usr/lib/microsoft-azurevpnclient/lib/libXplatSharedLibrary.so

# Create symlink in /usr/bin
${SUDO} mkdir -p /usr/bin
${SUDO} ln -sf /usr/lib/microsoft-azurevpnclient/microsoft-azurevpnclient /usr/bin/microsoft-azurevpnclient

# Fix .desktop file paths
${SUDO} sed -i 's|Path=/opt/microsoft/microsoft-azurevpnclient/|Path=/usr/lib/microsoft-azurevpnclient/|g' /usr/share/applications/microsoft-azurevpnclient.desktop
${SUDO} sed -i 's|TryExec=/opt/microsoft/microsoft-azurevpnclient/microsoft-azurevpnclient|TryExec=/usr/bin/microsoft-azurevpnclient|g' /usr/share/applications/microsoft-azurevpnclient.desktop
${SUDO} sed -i 's|Exec=/opt/microsoft/microsoft-azurevpnclient/microsoft-azurevpnclient|Exec=/usr/bin/microsoft-azurevpnclient|g' /usr/share/applications/microsoft-azurevpnclient.desktop

# Fix polkit rules to reference new path
${SUDO} sed -i 's|/opt/microsoft/microsoft-azurevpnclient|/usr/lib/microsoft-azurevpnclient/microsoft-azurevpnclient|g' /usr/share/polkit-1/rules.d/microsoft-azurevpnclient.rules
```

**Step 2: Make it executable**

```bash
chmod +x shared/packages/azure-vpn-client/mkosi.postinst.d/azure-vpn-client.chroot
```

**Step 3: Commit**

```bash
git add shared/packages/azure-vpn-client/mkosi.postinst.d/azure-vpn-client.chroot
git commit -m "feat: add azure-vpn-client postinstall with /opt relocation and patchelf"
```

---

### Task 4: Add azure-vpn-client to snowloaded profile

**Files:**
- Modify: `mkosi.profiles/snowloaded/mkosi.conf`

**Step 1: Add Include directive**

In the `[Include]` section, add after the Bitwarden line:

```ini
# Azure VPN Client
Include=%D/shared/packages/azure-vpn-client/mkosi.conf
```

**Step 2: Add PostInstallationScripts directive**

In the `[Content]` section, add after the Bitwarden PostInstallationScripts line:

```ini
# Azure VPN Client Postinstallation
PostInstallationScripts=%D/shared/packages/azure-vpn-client/mkosi.postinst.d/azure-vpn-client.chroot
```

**Step 3: Commit**

```bash
git add mkosi.profiles/snowloaded/mkosi.conf
git commit -m "feat: add azure-vpn-client to snowloaded profile"
```

---

### Task 5: Add azure-vpn-client to snowfieldloaded profile

**Files:**
- Modify: `mkosi.profiles/snowfieldloaded/mkosi.conf`

**Step 1: Add Include directive**

In the `[Include]` section, add after the Bitwarden line:

```ini
# Azure VPN Client
Include=%D/shared/packages/azure-vpn-client/mkosi.conf
```

**Step 2: Add PostInstallationScripts directive**

In the `[Content]` section, add after the Bitwarden PostInstallationScripts line:

```ini
# Azure VPN Client Postinstallation
PostInstallationScripts=%D/shared/packages/azure-vpn-client/mkosi.postinst.d/azure-vpn-client.chroot
```

**Step 3: Commit**

```bash
git add mkosi.profiles/snowfieldloaded/mkosi.conf
git commit -m "feat: add azure-vpn-client to snowfieldloaded profile"
```
