# firn-installer — the single installer ISO

Successor to `shared/native-installer` per firn's ADR-0010: **one**
installer ISO for all snosi image families, with
[firn](https://github.com/frostyard/firn)'s TUI as the kiosk frontend
(no cage/GTK/python — a single static Go binary on tty1 and ttyS0) and
a package payload satisfying firn's step-declared tool preflight for
both the bootc and native A/B install families.

## The firn binary is NOT committed

`tree/usr/bin/firn` is gitignored and provisioned at build time: the
`just firn-installer` / `just firn-installer-iso` recipes run
`_firn-binary` first, which builds it from a sibling firn checkout:

```sh
# FIRN_SRC defaults to ../firn relative to this repo's root;
# worktree users must point it at a real checkout:
FIRN_SRC=/path/to/firn just firn-installer
```

`_firn-binary` runs `CGO_ENABLED=0 go build ./cmd/firn-cli` with the
same ldflags version stamping as firn's own Makefile, so the binary on
the medium reports the source checkout's `git describe` version. The
image postinst fails the build loudly if the binary is missing, so a
bare `mkosi --profile firn-installer build` without the just recipe
cannot produce an installer-less ISO.

**TODO:** switch this local-build provisioning to installing the
`frostyard-firn` Debian package from the frostyard repository once firn
cuts a release — at that point `_firn-binary`, the gitignore entry, and
the postinst presence check move to a plain `Packages=` entry.

## Kiosk units

`tree/usr/lib/systemd/system/firn-kiosk.service` and
`firn-kiosk-serial@.service` are verbatim copies of firn's
`dist/` units (firn owns them; ADR-0010 repo boundary — re-copy on firn
changes, do not fork). They are enabled the same way native-installer
enables `snosi-setup.service`: static wants links in
`tree/usr/lib/systemd/system/multi-user.target.wants/` for
`firn-kiosk.service` (tty1) and `firn-kiosk-serial@ttyS0.service`
(serial, matching the ISO's `console=ttyS0` kernel argument).
