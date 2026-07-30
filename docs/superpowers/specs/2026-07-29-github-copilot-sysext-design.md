# GitHub Copilot Sysext Design

## Goal

Add the GitHub Copilot desktop app as an independently updateable Snosi system
extension named `github-copilot`. The component must work on the graphical
`snow` and `snowfield` products without modifying their immutable base images or
requiring AppImage/FUSE support at runtime.

GitHub authentication and account provisioning are outside this change. The
acceptance check stops after proving that the application launches correctly.

## Upstream Artifact

Use GitHub's official x86-64 Debian package rather than unpacking the AppImage.
Both artifacts are published in each `github/app` release, but the Debian
package is the better sysext input:

- It is smaller than the corresponding AppImage.
- It installs its complete payload under `/usr`, the filesystem namespace this
  sysext may provide.
- It carries package name and version metadata for the existing sysext output
  naming machinery.
- It declares its host-library dependencies explicitly.
- It avoids AppImage extraction, FUSE, launcher rewriting, and synthetic
  package metadata.

The initial pin is GitHub Copilot v1.1.2:

- Package: `github`
- Version: `1.1.2`
- Artifact: `GitHub-Copilot-linux-x64.deb`
- SHA-256: `df80379b8e624eaf751c33758534f111bed7faf09b8d988e59ac7e0ab3dc9ff4`

The inspected package has no maintainer scripts. Its payload includes
`/usr/bin/github`, `/usr/bin/git-credential-copilot`, application support files
under `/usr/lib/GitHub Copilot`, a desktop entry, hicolor icons, and URL-handler
registrations. The upstream `/usr/bin/github` name does not collide with the
GitHub CLI's conventional `/usr/bin/gh` command.

## Packaging Architecture

Create `mkosi.images/github-copilot/` as an overlay sysext based on `base`.
Its configuration follows the existing direct-download desktop application
pattern:

1. Install runtime dependencies through mkosi `Packages=` before the direct
   package installation:
   - `libayatana-appindicator3-1`
   - `libwebkit2gtk-4.1-0`
   - `libgtk-3-0`
2. Run a chroot post-install script that obtains the pinned Debian package with
   `verified_download("github-copilot", ...)` and installs it with `dpkg -i`.
3. Do not relocate or rewrite package files. The upstream package already uses
   sysext-compatible `/usr` paths and its desktop entry executes `github %u`.
4. Run the shared required-path and icon-cache stripping finalizers. The latter
   prevents the sysext from masking icons supplied by this or other extensions.
5. Set `KEYPACKAGE=github`, allowing the shared post-output script to derive
   the sysext version from dpkg metadata.

The required-path list must cover, at minimum:

- `/usr/bin/github`
- `/usr/bin/git-credential-copilot`
- `/usr/lib/GitHub Copilot`
- `/usr/share/applications/GitHub Copilot.desktop`
- `/usr/share/icons/hicolor/128x128/apps/github.png`

No system service, preset, sysusers entry, tmpfiles rule, or `/etc` factory
capture is needed. User settings, credentials, repositories, sessions, and
worktrees remain in the application's normal per-user writable locations.

## Distribution And Feature Policy

Add a dedicated component directory at
`mkosi.images/base/mkosi.extra/usr/lib/sysupdate.github-copilot.d/`.

The transfer follows the established sysext naming and repository convention:

- Source: `https://repository.frostyard.org/ext/github-copilot/`
- Target: `/var/lib/extensions.d/`
- Current symlink: `github-copilot.raw`
- Feature name: `github-copilot`

The feature is disabled by default and carries
`X-Snosi-Products=snow,snowfield`. It must not be offered on the headless
`cayo` product.

Add `github-copilot` to the root mkosi dependency list so the standard sysext
build and publication workflow includes it. Update any tests or inventories
that enumerate the complete component set.

## Dependency Updates

Add a `github-copilot` entry to
`shared/download/sysext-checksums.json` containing the immutable release URL,
SHA-256, and version.

Extend the `check-sysext-updates` job in
`.github/workflows/check-dependencies.yml` to:

1. Query `github/app` releases through the existing authenticated GitHub API
   helper.
2. Select the latest non-draft, non-prerelease release.
3. Normalize the leading `v` from the tag and require it to sort strictly newer
   than the pinned version.
4. Construct the immutable
   `GitHub-Copilot-linux-x64.deb` release URL.
5. Download the artifact, calculate its SHA-256, update the checksum metadata,
   and let the existing workflow open the normal update pull request.

All external release values continue to pass through environment variables
rather than direct expression interpolation in shell code.

## Failure Handling

The build fails closed when:

- The downloaded artifact does not match the pinned SHA-256.
- The Debian package cannot be installed with its declared runtime
  dependencies.
- Any required application, helper, desktop integration, or icon path is
  missing from the sysext delta.
- Static component metadata does not match the sysext name or publication
  paths.

The build must not fall back to a moving `latest` URL, the AppImage, or an
unverified artifact.

## Validation

Automated validation covers:

- JSON and workflow syntax after metadata changes.
- Existing profile/dependency, native component, and publication guards.
- mkosi configuration resolution for the new image.
- A real `github-copilot` sysext build, including checksum verification, dpkg
  installation, post-output version extraction, and required-path checks.

A graphical acceptance smoke test on Snow or Snowfield covers:

1. Install or merge the built `github-copilot` sysext.
2. Confirm the GitHub Copilot launcher and icon appear in the desktop shell.
3. Start the application from the launcher.
4. Run `xdg-open` on one of the desktop entry's registered URL schemes
   (`github-app`, `ghapp`, or `gh`) and confirm it routes to the running
   application.
5. Confirm the process and window remain running without dynamic-loader or
   startup errors.

The smoke test does not sign in, create a session, mutate a repository, or
require GitHub credentials. No new general-purpose GUI automation framework is
introduced; structural regressions remain enforced by the repeatable build and
required-path checks.

## Documentation

Update the source-of-truth inventories and architecture notes in:

- `CLAUDE.md`
- `README.md`
- `yeti/sysexts.md`
- Other existing count-based or complete sysext inventories found during
  implementation

The documentation must identify the component as an official pinned `.deb`,
not an extracted AppImage, and record that it is a Tauri desktop application
with no runtime service.
