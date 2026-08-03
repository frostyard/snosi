# Pilothouse Backend Configuration and Dependency Guard Design

## Goal

Keep Pilothouse's Updex, Podman, Docker, and Incus integrations available on
Cayo after Pilothouse changes those optional backends to default-off. At the
same time, make the direct-DEB sysext build fail before installation if a
future Pilothouse release declares a dependency that the merged buildroot does
not already satisfy.

The user-approved Pilothouse 0.7.0 URL, checksum, and version pin co-lands
with this change. The focused fixture enforces a Debian version floor of 0.7.0
so a later accidental downgrade fails clearly.

## Root Cause

The Snosi Pilothouse sysext currently ships the package's
`pilothoused.service` unchanged. The pinned v0.6.0 command configures only the
broker socket, socket group, and Debian administrator group. Newer Pilothouse
releases require explicit flags before probing Updex, Podman, Docker, or Incus,
so an unmodified service silently loses those capabilities after the pin bump.

The sysext build also relies on `dpkg -i` after a verified direct download.
Its comments assume the DEB has no dependencies and both binaries are static.
Newer packages declare Debian runtime dependencies and `pilothoused` uses
dynamic PAM and systemd libraries. That stale assumption should become an
enforced build contract rather than another comment.

## Service Override

Add this vendor drop-in beneath the Pilothouse sysext payload:

`/usr/lib/systemd/system/pilothoused.service.d/10-snosi-backends.conf`

The drop-in clears the package's `ExecStart` and supplies one replacement. The
replacement retains these Debian package arguments exactly once:

- `--socket /run/pilothouse/broker.sock`
- `--socket-group pilothouse`
- `--admin-group sudo`

It also supplies each optional backend configuration exactly once:

- `--updex /usr/bin/updex`
- `--podman-socket /run/podman/podman.sock`
- `--docker unix:///var/run/docker.sock`
- `--incus`

These flags permit probes; they do not create systemd dependencies on the
configured endpoints. Pilothouse remains responsible for bounded reachability
checks. A missing executable or unavailable socket leaves that capability and
its routes unregistered without preventing broker startup.

Add the drop-in path to `mkosi.images/pilothouse/required-paths.txt` so a sysext
build cannot omit it silently.

## Dependency Guard

Add `shared/download/deb-dependencies.sh`, a small shared shell helper for
direct-DEB consumers. Given a DEB path, it reads the package's `Depends` field
with `dpkg-deb` and, when nonempty, passes the complete expression to
`dpkg-checkbuilddeps -d`. This delegates versions, alternatives, architecture
qualifiers, and virtual-package handling to Debian's own dependency parser.

The Pilothouse post-install script invokes the helper after verified download
and before `dpkg -i`. An unsatisfied expression fails before the package mutates
the buildroot and reports that the missing runtime dependency must be declared
through the image's `Packages=` composition. The helper accepts an empty
`Depends` field, preserving compatibility with older direct-DEB artifacts.

The guard deliberately does not run APT or install dependencies automatically.
That would let a new upstream dependency silently enter the sysext delta rather
than forcing Snosi to make the package-placement decision explicitly.

## Regression Coverage

Add an always-runnable fixture test to `validate.yml` that proves:

- the required-path manifest names the service drop-in;
- the drop-in clears and replaces `ExecStart`;
- the effective command preserves each packaged argument exactly once;
- the effective command configures each optional backend exactly once;
- `systemd-analyze verify` accepts a fixture package unit combined with the
  drop-in;
- the dependency helper accepts an empty dependency field;
- the helper accepts a synthetic DEB whose versioned/alternative dependency is
  satisfied by the test host; and
- the helper rejects a synthetic DEB with a deliberately nonexistent
  dependency.

The structural service test protects Snosi's delivery contract without
duplicating Pilothouse's own endpoint-probe implementation tests. A real sysext
build remains the artifact-level proof that the drop-in is included.

## Documentation

Update `README.md`, `CLAUDE.md`, and `yeti/sysexts.md` to record:

- the four explicitly configured optional backends;
- unavailable endpoints remain capability-gated and nonfatal;
- direct-DEB dependencies must already be satisfied by the merged buildroot;
  and
- the build-time guard enforces that dependency contract before installation.

Do not claim runtime capability advertisement was tested on Cayo unless a live
Cayo validation is actually run.

## Scope

This design resolves Snosi issues #479 and #469 together. It does not change
Pilothouse's probe implementation, add endpoint ordering dependencies, or
install new runtime packages implicitly.
