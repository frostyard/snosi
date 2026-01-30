# SNOSI Codebase Analysis

## Executive Summary

This document provides a technical analysis of the snosi codebase, identifying issues, potential improvements, and recommendations. The codebase is generally well-structured for its purpose—building immutable bootc-based Debian images with mkosi—but has accumulated some technical debt and documentation gaps that should be addressed.

---

## 1. Code Quality Issues

### 1.1 Script Error Handling Inconsistencies

**Location:** Various scripts in `shared/` and `mkosi.images/`

Most scripts use `set -e` for error handling, but inconsistencies exist:

- `shared/snow/scripts/build/brew.chroot` uses `set -euo pipefail` implicitly via bash behavior but could be more explicit
- `shared/packages/bitwarden/mkosi.postinst.d/bitwarden.chroot` has proper `set -euo pipefail`
- Some scripts only use `set -e` without `pipefail`, which can mask errors in pipelines

**Recommendation:** Standardize on `set -euo pipefail` for all bash scripts.

### 1.2 Code Duplication in Sysext Postoutput Scripts

**Location:** `mkosi.images/*/mkosi.postoutput`

All six sysext postoutput scripts (1password-cli, debdev, dev, docker, incus, podman) contain nearly identical code (~49 lines each). The only differences are:
- `KEYPACKAGE` variable (e.g., `docker-ce`, `incus`, `podman`, `debootstrap`, `build-essential`, `1password-cli`)
- Manifest filename pattern

**Current duplication:** ~294 lines of duplicated code across 6 files.

**Recommendation:** Create a shared script that accepts the key package name as a parameter:
```bash
#!/bin/bash
# shared/sysext-postoutput.sh
KEYPACKAGE="$1"
IMAGE_ID="${2:-$IMAGE_ID}"
# ... shared logic
```

### 1.3 Empty Placeholder Scripts

**Location:** `mkosi.images/docker/mkosi.postinst.d/`, `mkosi.images/podman/mkosi.postinst.d/`, `mkosi.images/incus/mkosi.postinst.d/`

These directories do not exist (confirmed via glob search), which is actually correct since these sysexts don't need post-installation scripts. However, the README mentions them in examples which could cause confusion.

---

## 2. Security Considerations

### 2.1 External Downloads Without Checksum Verification

Several scripts download files from external sources without verifying checksums:

#### Bitwarden Download
**Location:** `shared/packages/bitwarden/mkosi.postinst.d/bitwarden.chroot:15-16`
```bash
curl --location --fail --output debs/bitwarden.deb \
    "https://bitwarden.com/download/?app=desktop&platform=linux&variant=deb"
```
- No checksum verification
- Dynamic URL that could change content

#### Surface Certificate
**Location:** `shared/snow/scripts/build/surface-cert.chroot:5`
```bash
curl https://github.com/linux-surface/linux-surface/raw/refs/heads/master/pkg/keys/surface.cer -Lo /usr/share/linux-surface-secureboot/surface.cer
```
- Downloads directly from GitHub raw content
- No checksum verification
- Secure boot certificate—high trust requirement

**Recommendation:** Add SHA256 checksum verification for all external downloads, or pin to specific commits/versions.

### 2.2 Homebrew Install Script Execution

**Location:** `shared/snow/scripts/build/brew.chroot:10-12`
```bash
curl --retry 3 -fsSLo "/tmp/brew-install" "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
touch /.dockerenv
env --ignore-environment "PATH=/usr/bin:/bin:/usr/sbin:/sbin" "HOME=/home/linuxbrew" "NONINTERACTIVE=1" /usr/bin/bash /tmp/brew-install
```

- Executes a script fetched from the internet
- Uses `HEAD` reference which can change
- The `touch /.dockerenv` trick is clever but undocumented

**Risk:** While this runs at build time in a chroot (not on user systems), a compromised Homebrew install script could inject malicious code into the final image.

**Recommendation:** Consider pinning to a specific commit hash or maintaining a local copy of the install script.

---

## 3. Documentation Gaps

### 3.1 README Inaccuracies (Fixed)

The following inaccuracies were identified and corrected in README.md:

| Section | Issue | Status |
|---------|-------|--------|
| Product table | Missing 1password-cli, debdev, dev sysexts | Fixed |
| Product table | snowloaded description incomplete | Fixed |
| Architecture diagram | Missing 3 sysexts | Fixed |
| Shared components | Missing bitwarden, vscode packages | Fixed |
| Profile comparison | Incorrect "Extra Packages" column | Fixed |
| Missing sections | No CI/CD docs, no frostyard package explanation | Fixed |
| Example snow profile | Outdated script references | Fixed |

### 3.2 Missing Inline Comments in Scripts

Many scripts lack explanatory comments:

- `shared/snow/scripts/build/brew.chroot`: The `touch /.dockerenv` trick is undocumented
- `shared/outformat/oci/postoutput/mkosi.postoutput`: Complex OCI tagging logic could use more explanation
- Build scripts in general could benefit from explaining *why* certain operations are needed

### 3.3 No Architecture Decision Records

The project makes several non-obvious architectural decisions:

- Why relocate `/opt` contents to `/usr/lib`?
- Why use tmpfiles.d for `/etc` configuration injection?
- Why bundle Homebrew as a tarball?

These are partially explained in README but formal ADRs would help future maintainers.

---

## 4. Technical Debt

### 4.1 saved-unused/ Directory

**Location:** `saved-unused/10-image-cayo/`

Contains ~90+ files from an old image configuration ("cayo"). This includes:
- Complete mkosi.conf
- Extensive mkosi.extra tree with systemd units, tmpfiles, sysusers configs
- APT repository configurations

**Impact:** Adds ~100+ files to repository that aren't used in the current build.

**Recommendation:** Either:
1. Remove entirely if no longer needed
2. Move to a separate branch for reference
3. Document why it's kept (if intentional)

### 4.2 Inconsistent Manifest Handling

Sysexts and OCI images use different manifest processing:

- **Sysexts:** Each has its own `mkosi.postoutput` that creates versioned manifest files
- **OCI images:** Use `shared/manifest/postoutput/mkosi.postoutput` (referenced but not analyzed)

The duplication in sysext postoutput scripts (as noted in 1.2) also affects manifest processing.

### 4.3 Empty mkosi.postinst.d Directories

While searching, I confirmed that `mkosi.images/1password-cli/mkosi.postinst.d/` does not exist (the glob returned no results). This is fine since 1password-cli installs cleanly to standard paths, but it differs from the pattern used by bitwarden and edge in shared/packages.

---

## 5. Recommendations (Prioritized)

### High Priority

1. **Add checksum verification for external downloads**
   - Create a download helper script with built-in verification
   - Maintain a checksums file for pinned versions
   - Affects: bitwarden.chroot, surface-cert.chroot, brew.chroot

2. **Consolidate sysext postoutput scripts**
   - Create `shared/sysext-postoutput.sh` accepting package name as parameter
   - Reduces maintenance burden and potential for drift
   - Estimated: ~250 lines of code eliminated

3. **Clean up saved-unused/ directory**
   - Determine if "cayo" image is still needed
   - If not, remove or archive to reduce repository size

### Medium Priority

4. **Standardize script error handling**
   - Add `set -euo pipefail` to all bash scripts
   - Consider adding `trap` for cleanup on error

5. **Add inline documentation**
   - Document the `/.dockerenv` trick in brew.chroot
   - Explain the tmpfiles.d pattern for sysext config injection
   - Add header comments explaining each script's purpose

6. **Pin Homebrew install script**
   - Use specific commit hash instead of `HEAD`
   - Or vendor the script locally

### Low Priority

7. **Create Architecture Decision Records (ADRs)**
   - Document `/opt` to `/usr/lib` relocation rationale
   - Document sysext design patterns
   - Document CI/CD pipeline design choices

8. **Add script linting**
   - Integrate shellcheck into CI
   - Fix any warnings

9. **Consider shared manifest handling**
   - Unify manifest processing between sysexts and OCI images
   - Reduce code paths for version extraction logic

---

## Appendix: Files Reviewed

### Configuration Files
- `mkosi.conf` (root)
- `mkosi.profiles/*/mkosi.conf` (4 profiles)
- `mkosi.images/*/mkosi.conf` (7 images)
- `shared/packages/*/mkosi.conf` (5 package sets)

### Scripts
- `shared/snow/scripts/build/brew.chroot`
- `shared/snow/scripts/build/surface-cert.chroot`
- `shared/packages/bitwarden/mkosi.postinst.d/bitwarden.chroot`
- `mkosi.images/*/mkosi.postoutput` (6 sysexts)

### CI/CD
- `.github/workflows/build.yml`
- `.github/workflows/build-images.yml`

### Other
- `saved-unused/` directory contents (partial)
