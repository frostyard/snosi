# 0028 — First login runs chairlift's first-run mode

- **Status:** Accepted; its retirement and lab-gate consequences are amended by [ADR-0031](0031-first-setup-retired-without-a-soak.md)
- **Date:** 2026-11-04

## Context

SNOW First Setup (frostyard/first-setup, deb `snow-first-setup`) was the
first-login app of Snow and Snowfield. Its deb installed
`/etc/xdg/autostart/org.frostyard.FirstSetup.autostart.desktop`
(`Exec=snow-first-setup --autostart`), which ran at every graphical login and
exited when `${XDG_CONFIG_HOME:-~/.config}/snow-first-setup.done` existed. It
showed welcome, connectivity, light/dark style, an optional user Flatpak
picker, and appended Homebrew `shellenv` lines to `~/.bashrc`. Sundog and Floe
had no first-login app.

Plan T843 (Brian, 2026-11-04) moves that flow into chairlift, which already
ships on Snow, Snowfield and Sundog, and retires first-setup. chairlift
v0.13.0 (chairlift ADR-0014) adds:

- `/usr/bin/chairlift-first-run`, a pure-Go gate in the `frostyard-chairlift`
  deb. It exits 0, with no GTK loaded, when
  `${XDG_CONFIG_HOME:-~/.config}/chairlift/first-run.done` **or** the legacy
  `snow-first-setup.done` exists, or when UID is 0. Otherwise it execs
  `chairlift --first-run` (application ID `org.frostyard.ChairLift.FirstRun`).
- Completion, and `chairlift-first-run --mark-done`, write both markers and
  remove the legacy per-user first-setup autostart copy.
- A `first_run` config page whose default list is
  `/usr/share/snow/first-run/apps.json`; a missing or malformed list hides the
  Apps step, and the user can still finish.
- No autostart entry in any chairlift deb, so chairlift users on other
  distributions see no change.

Brian's decisions: the first run is on Snow and Snowfield only (T843b), it
keeps the app picker with the list in snosi (T843c), and its strings are
translated in chairlift (T843a).

## Decision

1. **The image owns the trigger.** The Snow tree
   (`shared/snow/tree`, so Snow and Snowfield) ships
   `/etc/xdg/autostart/org.frostyard.ChairLift.FirstRun.desktop` with exactly
   `Exec=/usr/bin/chairlift-first-run`. GNOME runs XDG autostart entries at
   session start; no systemd unit or preset is added. chairlift owns the
   flow and the done markers.
2. **One trigger, in one build.** The same change removes `snow-first-setup`
   from `shared/packages/snow/mkosi.conf`. Snow and Snowfield ship exactly one
   enabled first-login entry; Sundog and Floe ship none.
   `shared/composition/first-login.finalize` (rules in
   `shared/composition/first-login-check.py`) fails the build of any OCI
   product that breaks this, or when `/usr/bin/chairlift-first-run` is not a
   file every user can execute (a stale chairlift from APT), or when the
   entry's `Exec` is anything else. An entry counts as a trigger only when
   GNOME starts it (`Type=Application`, not hidden or disabled, not excluded
   by `OnlyShowIn`/`NotShowIn`); `Exec` programs are compared after
   desktop-entry quoting. The canonical entry may carry only keys the guard
   validates, so no `TryExec` or other launch condition can silence it.
3. **The image owns the app list.** `/usr/share/snow/first-run/apps.json`
   (first-setup's list and shape, category → `[{name, id, active?}]`) ships in
   the Snow tree. snosi ships no chairlift configuration: chairlift's default
   config names that path. The finalize and
   `test/first-login-trigger-test.sh` fail on every fault chairlift's loader
   rejects (it would hide the Apps step), plus a duplicate JSON key or an
   empty category key.
4. **The image owns the Homebrew shell environment.** Base ships
   `/etc/profile.d/snosi-brew.sh`: for a non-root user, when
   `/home/linuxbrew/.linuxbrew/bin/brew` is executable, it evaluates
   `brew shellenv`. It replaces first-setup's `~/.bashrc` append on every
   image and every user. The Fish equivalent stays
   `/usr/share/fish/vendor_conf.d/ublue-brew.fish`.
5. **Both markers count as done.** A host where first-setup finished does not
   run the chairlift first run (chairlift reads the legacy marker forever).
   chairlift also writes the legacy marker during the transition, so a bootc
   rollback to a first-setup image does not start first-setup again
   (chairlift ADR-0014 dates the end of that write).

## Consequences

- A user who never finished first-setup gets the chairlift first run once
  after the update. A user who finished it gets nothing.
- Offline users can finish the first run; the Apps step needs internet and
  is skipped offline (first-setup blocked until online).
- `/etc/xdg/autostart` is deployment-managed `/etc`: bootc's three-way merge
  adds the new entry on update and removes first-setup's packaged entry,
  unless a host changed those files locally.
- `brew shellenv` now applies to every non-root login shell, and so to the
  GNOME session environment (gnome-session starts through a login shell),
  not only to interactive bash. Root never puts the UID-1000-owned brew
  prefix in its `PATH`. Old `~/.bashrc` lines stay; a second evaluation
  does no harm.
- A chairlift release without `chairlift-first-run` fails the Snow and
  Snowfield builds instead of shipping an image with no first-login app.
- frostyard/lab's report-only first-login probe (lab#182) proves "once" on
  fresh installs and "none" after an upgrade from a first-setup image whose
  marker exists. It gates the lane after 3 green main runs. frostyard/testsuite
  adds smoke scenarios after these images publish.
- first-setup, its APT package and its frostyard.org pages retire after a
  soak of 14 days and 3 green main builds (plan T843 tasks t5–t7). Reverting
  this change restores first-setup while its deb stays in APT.

## Alternatives considered

- **Ship the autostart entry in the chairlift deb:** every distribution that
  installs chairlift would get a first-login wizard. The trigger is image
  policy.
- **A systemd user unit:** needs a preset and adds a second mechanism; XDG
  autostart is what GNOME runs and what first-setup used.
- **Run the first run on Sundog too:** needs a KDE style writer and shows the
  wizard once to every existing Sundog user (Brian chose parity, T843b).
- **Keep appending to `~/.bashrc`:** not idempotent, and only for the user who
  ran the wizard; a profile.d file covers every user and shell.
- **Guard `snosi-brew.sh` to interactive shells:** Debian's
  `/etc/bash.bashrc` does not read `/etc/profile.d`, so non-login terminals
  would lose brew for new users.

## References

- Plan T843 "chairlift takes over first-setup, first-setup retires" (desk,
  approved rev 234c6d8).
- chairlift [ADR-0014 first-run mode](https://github.com/frostyard/chairlift/blob/main/docs/adr/0014-first-run-mode.md).
- Shapes: [integration-contracts.md](../integration-contracts.md),
  [design/overview.md](../design/overview.md).
- Builds on: [ADR-0016](0016-name-kde-bootc-product-sundog.md) (Sundog
  product), [ADR-0018](0018-remove-native-ab-and-nbc-lanes.md) (no live
  desktop, so no live-session check).
