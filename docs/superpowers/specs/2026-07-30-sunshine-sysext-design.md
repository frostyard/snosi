# Sunshine Sysext Design

## Goal

Add LizardByte Sunshine as an independently updateable, desktop-only system
extension named `sunshine`. Build it from the official Debian Trixie amd64
package at version `2026.516.143833`, publish it through the existing sysext
pipeline, and expose Sunshine through its upstream desktop launcher without
starting it automatically for graphical users.

## Upstream Artifact

- URL: `https://github.com/LizardByte/Sunshine/releases/download/v2026.516.143833/sunshine-debian-trixie-amd64.deb`
- Package: `sunshine`
- Version: `2026.516.143833`
- Architecture: `amd64`
- SHA-256: `b9b65f2be93b3e30be0710a940a616b1381da5bc6d858dce33bc0094d7fd4131`

Record the artifact in `shared/download/sysext-checksums.json`. The build must
retrieve it through `verified_download()` and install it with `dpkg -i` so the
dpkg database remains the source of the package version used by the shared
post-output naming logic.

Add a GitHub-release update check for `LizardByte/Sunshine` to
`.github/workflows/check-dependencies.yml`. It must select the latest
non-draft, non-prerelease release, compare versions with the workflow's
downgrade guard, construct the release's Trixie amd64 asset URL, download it,
and refresh the checksum metadata.

## Sysext Build

Create `mkosi.images/sunshine/` using the standard overlay sysext structure:

- `ImageId=sunshine`
- `Output=sunshine`
- `Overlay=yes`
- `Format=sysext`
- `BaseTrees=%O/base`
- shared required-path and icon-cache finalize scripts
- shared sysext post-output script
- `KEYPACKAGE=sunshine`

The package installs natively under `/usr`; no `/opt` relocation or factory
`/etc` capture is required. The sysext configuration must explicitly install
the runtime dependencies declared by the upstream package because `dpkg -i`
cannot resolve them. Dependencies already supplied by `base` are harmless in
the merged build and do not need to be listed as required sysext-delta paths.

The package post-install script performs three relevant operations:

1. Loads `uhid` for virtual gamepad support.
2. Applies `cap_sys_admin,cap_sys_nice+p` to `/usr/bin/sunshine` for KMS capture
   and scheduling priority.
3. Reloads and triggers its udev rules for `/dev/uinput` and `/dev/uhid`.

Keep the upstream package installation behavior rather than maintaining a
downstream repack. The built sysext must retain the resulting file capability,
`usr/lib/modules-load.d/60-sunshine.conf`, and
`usr/lib/udev/rules.d/60-sunshine.rules`. EROFS preserves the capability in
the same way as the existing Azure VPN sysext. A real build is the acceptance
check for whether these maintainer-script operations work in mkosi's chroot;
fail the work rather than silently publishing a capability-free payload.

## Runtime Behavior

Sunshine remains opt-in at runtime. Preserve the upstream user unit
`app-dev.lizardbyte.app.Sunshine.service` and desktop entry, whose launcher
starts that unit. Do not add a user preset, static target link, or `Upholds=`
drop-in. Enabling the sysext makes Sunshine available but does not expose its
streaming service until a user launches it.

The package's modules-load and udev files provide virtual input support after
the extension is merged. The base image's existing sysext reload path runs
`systemd-tmpfiles`, `systemd-sysusers`, and `daemon-reload`; no `/etc` writes or
runtime `systemctl enable` operations are needed.

The package ships hicolor icons. Retain the shared
`sysext-strip-icon-cache.sh` finalize step so Sunshine and other merged sysext
icons remain discoverable.

## Required Payload Contract

Add `mkosi.images/sunshine/required-paths.txt` covering at least:

- `/usr/bin/sunshine`
- the upstream user service
- the modules-load file
- the udev rules
- the primary desktop entry
- the primary hicolor application icon
- `/usr/share/sunshine/apps.json`
- a representative web UI entry point

Separately verify the Sunshine binary's expected capability after a real build;
path existence alone cannot prove it survived packaging.

## Distribution Metadata

Create the systemd-sysupdate component under
`mkosi.images/base/mkosi.extra/usr/lib/sysupdate.sunshine.d/`:

- Feature name: `sunshine`
- Description: self-hosted game streaming host for Moonlight
- Documentation: `https://docs.lizardbyte.dev/projects/sunshine/`
- `Enabled=false`
- `X-Snosi-Products=snow,snowfield`
- Source: `https://repository.frostyard.org/ext/sunshine/`
- Target: `/var/lib/extensions.d/`
- Current symlink: `sunshine.raw`
- Existing compressed and uncompressed sysext match-pattern convention
- `Verify=false`, matching the repository's currently accepted native sysext
  publication risk

Add `sunshine` to the root dependency list so standard sysext builds produce
it. Add it to `check-profile-dependencies.sh` so OCI profile builds remain
isolated from every optional sysext, and to the native component topology test
so installed native images must advertise it as a distinct component.

## Documentation

Update the sysext counts and enumerations in `CLAUDE.md`, `README.md`, and
`yeti/OVERVIEW.md`. Add Sunshine to the human-facing image tables and document
its direct-download packaging, manual user-service startup, capabilities,
modules-load behavior, udev rules, and icon-cache requirement in
`yeti/sysexts.md`. Update any other exact sysext lists discovered during
implementation.

## Verification

The implementation is complete when all applicable checks pass:

1. The checksum metadata parses and the pinned URL hashes to the recorded
   SHA-256.
2. Shell scripts and edited workflow shell pass the repository's available
   static checks.
3. Static sysext/component tests include Sunshine and pass.
4. A real `sunshine` sysext build succeeds against the base image.
5. The built delta contains every required path and no hicolor icon cache.
6. The built `/usr/bin/sunshine` retains
   `cap_sys_admin,cap_sys_nice+p`.
7. The generated manifest reports package `sunshine` version
   `2026.516.143833`, and post-output naming follows the standard Sunshine
   versioned sysext convention.

If environment or privilege constraints prevent the real build, report that
verification gap explicitly; static validation alone is not sufficient to
claim the runtime capability contract is proven.

## Pull Request

Implement on a branch based on `main`, commit the complete source, tests, and
documentation changes, push the branch, and open a pull request targeting
`main`. The pull request must summarize the manual-start policy and list the
verification performed, including any environment-blocked build checks.
