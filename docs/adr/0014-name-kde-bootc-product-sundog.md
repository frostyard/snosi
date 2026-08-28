# 0014 — Name the KDE bootc product Sundog

- **Status:** Accepted
- **Date:** 2026-08-26

## Context

Snosi needs a KDE Plasma counterpart to the Snow GNOME desktop. The product
must fit Frostyard's frozen-weather naming family, remain distinct from
existing Frostyard repositories, and initially ship only through the
established bootc/OCI transport. The existing Frostyard project named Rime
makes that otherwise suitable name unavailable.

Snow's product opinions also need translation rather than a package-for-package
desktop swap: immutable host updates, Flatpak-first graphical applications,
Wayland, the shared workstation hardware/container baseline, Firn installation,
and exact signed-repository policy must remain recognizable in Plasma.

## Decision

The KDE product is named **Sundog**, with profile and image ID `sundog`.

Sundog is bootc-only. It composes the backports kernel, bootc runtime and secure
OCI policy, and a dedicated Plasma package/tree fragment. Plasma on Wayland is
the sole offered desktop session, SDDM and Breeze provide the login and boot
presentation, Discover exposes only its Flatpak backend, and Snow's tuned,
hardware, printing, container, Flathub, update-notification, Firn, and
desktop-sysext compatibility opinions carry over.

No `sundog-ab` profile or native A/B channel is created by this decision.

## Consequences

Sundog participates in the bootc mechanics and protected publication matrices,
has an exact `ghcr.io/frostyard/sundog` Cosign policy scope, and appears
in the Firn bootc catalog. Its package set must keep the complete
`gui-base` closure, and its build-time `/var` contents have a
dedicated fail-closed outcome map.

The KDE product can evolve without coupling Plasma choices to Snow's GNOME
payload. The cost is another full OCI matrix leg and another desktop closure
that must be checked whenever `gui-base` changes. Native A/B
installation, native Secure Boot evidence, and Surface-specific support are
explicitly out of scope until a later decision adds them.

## Alternatives considered

- **Rime:** rejected because Frostyard already has a repository with that name.
- **Reuse Snow with a desktop switch:** rejected because one image ID would no
  longer identify one deterministic desktop and update stream.
- **Add native A/B at the same time:** rejected because the request and current
  validation evidence cover only bootc; adding another transport would create
  unsupported publication and test obligations.

## References

- Shapes: [design/overview.md](../design/overview.md),
  [design/build-pipeline.md](../design/build-pipeline.md),
  [design/ci-cd.md](../design/ci-cd.md),
  [design/testing.md](../design/testing.md),
  [design/sysexts.md](../design/sysexts.md)
- Builds on:
  [ADR-0005](0005-profiles-as-transport-kernel-selectors.md),
  [ADR-0006](0006-name-triggered-publication-guards.md)
