# Graphical installer (`snosi-setup`) for the native installer ISO — Phase 2 plan

**Status:** planned (decisions settled 2026-07-17; implementation not started)
**Prerequisite:** Phase 1 merged (installer-owned system settings + deferred
first-boot provisioning, PR #419) — the CLI backend is feature-complete for
everything a graphical frontend needs to drive.
**Owner docs:** this plan; `docs/native-ab-contracts.md` §8 gains a short
"Graphical setup" note at implementation time. CLAUDE.md "snosi-install"
section describes the backend contract.

## Goal

A GTK4/libadwaita first-run experience on the network-installer ISO:
booting the ISO on a machine with a display launches a kiosk-mode setup app
(`snosi-setup`) that walks welcome → network → language/keyboard/timezone →
hostname → first user → sysext features → core flatpaks → disk selection +
typed confirmation → recovery-key display + acknowledgement → MOK password →
progress → done/reboot, and drives the existing `snosi-install` backend.
The serial console keeps the exact text-mode flow that exists today.

## Non-goals

- Not a live desktop and not a dakota/bootc replacement — this ISO still
  installs native A/B products only, still payload-free.
- No second implementation of install logic. The GUI performs **zero**
  privileged operations itself; every action goes through one
  `snosi-install --non-interactive` invocation. If the GUI can express
  something the CLI cannot, that is a CLI gap to fix first.
- Text mode remains the authoritative, always-available path (headless
  hardware, serial-only boards, recovery). Nothing about its behavior may
  change.

## Settled decisions

| # | Decision | Choice | Rationale |
|---|---|---|---|
| 1 | Compositor | **cage** (Wayland kiosk) | runs exactly one client, no session infra, tiny; crash → respawn, no display → getty as today |
| 2 | Toolkit | **GTK4 + libadwaita + Python/GI** | matches first-setup, whose language/keyboard/timezone views and localegen data port nearly verbatim |
| 3 | Frontend↔backend contract | GUI collects everything, then runs one `snosi-install --non-interactive … --json-progress` | single source of truth for validation + operations; progress rendered from a line-delimited JSON event stream |
| 4 | ISO budget | accept ~0.5 GB growth (~550 MB → ~1.1 GB) | user-approved; python3 is NOT currently on the ISO, so the stack is Mesa + cage + GTK4/libadwaita + python3(-gi) + fonts |
| 5 | Code location | **in-tree**: `shared/native-installer/setup-gui/` | frontend and backend flags stay atomically in sync while the surface stabilizes; can graduate to a package later |

## Architecture

### Backend additions (`snosi-install`)

- `--json-progress`: machine-readable line-delimited JSON on stdout
  (suppresses human-oriented log lines). Event grammar (frozen when
  implemented, versioned by a leading `{"event":"start","proto":1,...}`):
  - `{"event":"phase","id":"download|layout|var|tpm|seed|mok","title":...}`
  - `{"event":"progress","phase":"download","bytes":N,"total":N}`
  - `{"event":"log","message":...}` (rate-limited)
  - `{"event":"error","message":...}` then exit non-zero
  - `{"event":"done","summary":{...}}`
  Implementation note: `stream_download_verify` already counts bytes; the
  phases map 1:1 onto main()'s existing sections.
- `--print-defaults`: emit a JSON document of products, per-product
  defaults (hostname default, core-flatpaks policy, minimum disk bytes),
  and the validation regexes — so the GUI never hardcodes what the CLI
  already knows. Also used by GUI tests to detect drift.
- Disk enumeration for the GUI reuses `list_installable_disks` (a
  `--list-disks-json` flag wrapping the existing lsblk JSON + refusal
  filter).

### Frontend (`snosi-setup`, `shared/native-installer/setup-gui/`)

- Python/GI app, pages ported from first-setup's views (language, keyboard,
  timezone pickers + its `localegen` data files; welcome/conn-check shells).
  New pages: disk selection (from `--list-disks-json`, refusal reasons shown
  greyed-out), typed erase confirmation, recovery-key display with an
  explicit "I saved it" gate (mirrors `--acknowledge-recovery-saved`), MOK
  password (twice), progress (from `--json-progress`), done/reboot.
- Secrets handling: user password and MOK password written to 0600 tmpfiles
  under `XDG_RUNTIME_DIR` (the promote-runner lesson: never /tmp) passed via
  `--user-password-file`/`--mok-password-file`, deleted immediately after
  `snosi-install` exits.
- The app runs as root (the whole ISO environment is root); no polkit
  choreography needed.

### ISO/boot integration

- New packages in `shared/native-installer/mkosi.conf` (each explicit, per
  the forky-drift rule): `cage`, Mesa (llvmpipe fallback so virtio/simple
  framebuffer works), `gtk4`/`libadwaita`, `python3`, `python3-gi`,
  `fonts-cantarell` + a fallback font, XKB data (already present via
  keyboard deps — verify).
- `snosi-setup.service`: launches `cage -- snosi-setup` on tty1,
  `ConditionPathExistsGlob=/dev/dri/card*` (plus a `snosi.textmode=1`
  cmdline escape hatch); when the condition fails, getty@tty1 runs exactly
  as today. serial-getty@ttyS0 is untouched either way.
- Crash policy: `Restart=on-failure` with a small burst limit, then getty
  fallback — a wedged GUI must never brick the install path.

## Tasks

1. **T1 backend:** `--json-progress`, `--print-defaults`,
   `--list-disks-json`. Unit-testable without root (extend
   `test/snosi-install-test.sh`: event-stream shape on the fixture install,
   defaults document schema).
2. **T2 frontend:** app skeleton + pages, driven by `--print-defaults`;
   first-setup view ports. Logic/GTK separation so page state machines are
   plain-Python unit-testable.
3. **T3 ISO integration:** packages, `snosi-setup.service` + gating +
   fallback, boot-path verification (the three §8 boot-chain gotchas —
   grub prefix, fbx64, console= — must be re-verified after adding a GPU
   stack; `console=` interaction with a real GPU device is exactly the
   trap documented in CLAUDE.md).
4. **T4 tests:**
   - `test/native-installer-iso-test.sh` grows: package/tool presence for
     the GUI stack; `snosi-setup.service` gating logic.
   - `test/native-installer-e2e-test.sh --graphical` leg: boot with
     virtio-vga, assert `graphical` path taken (cage + snosi-setup
     processes up via SSH), then complete the install through the CLI as
     today — visual flow itself is validated manually (the 2026-07-16
     lesson: schedule a hands-on pass; automation can't see what a human
     sees).
   - Text-mode regression: e2e default leg byte-identical behavior.
5. **T5 docs:** contracts §8 note, CLAUDE.md, checklist §9 hands-on items,
   ISO size note in the publication runbook (bigger ISO = longer
   candidate upload/verify).

## Risks / open items

- **GPU coverage on real hardware:** cage+Mesa handles virtio and most
  laptops; weird firmware/hybrid-GPU cases fall back to text mode by
  design — acceptable, but the fallback must be *proven*, not assumed
  (T3/T4).
- **ISO size** doubles; publication/verify times grow accordingly.
- **Localization:** first-setup's `po/` exists; wire gettext from day one
  or accept English-only for v1 (decide at T2 start).
- **first-setup drift:** ported views are a fork-in-time. Acceptable
  in-tree; revisit sharing when the surface stabilizes (the upstream
  first-setup issue about Mode 2 retirement should mention it).

## Exit criteria

1. QEMU (virtio-vga): ISO boots to the GUI under enforced Secure Boot,
   a complete graphical install of snow-ab produces `install-info.json` /
   `first-boot.json` / created user **identical in content** to the same
   choices made through text mode.
2. QEMU (no display / `snosi.textmode=1`): text-mode flow byte-identical
   to today, e2e suite green.
3. A hands-on human pass on the GUI flow (the §9 canary rule) with no
   blocking UX defects.
