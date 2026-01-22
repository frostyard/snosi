# snosi

A bootable container image build system using [mkosi](https://github.com/systemd/mkosi) for creating Debian-based bootable containers and system extensions (sysexts).

## What This Project Does

snosi builds immutable, bootable OCI container images based on Debian Trixie. These images are designed for use with [bootc](https://containers.github.io/bootc/) / systemd-boot and can be deployed as atomic, updateable operating system images.

The project produces:

| Image               | Description                                        | Output Format |
| ------------------- | -------------------------------------------------- | ------------- |
| **snow**            | GNOME desktop with backports kernel                | OCI archive   |
| **snowloaded**      | snow + Edge browser + Incus virtualization         | OCI archive   |
| **snowfield**       | snow with linux-surface kernel for Surface devices | OCI archive   |
| **snowfieldloaded** | snowfield + Edge + Incus                           | OCI archive   |
| **docker**          | Docker CE container runtime                        | sysext        |
| **incus**           | Incus container/VM manager                         | sysext        |
| **podman**          | Podman + Distrobox                                 | sysext        |

## Architecture

```
                          base            ← Debian Trixie + bootc foundation
                            │
                ┌───────────┴───────────┐
                │                       │
             sysexts                  profiles
          ┌────┼────┐                   │
      docker  incus  podman           snow ────────────────────┐
                                        │                      │
                              ┌─────────┼─────────┐            │
                              │         │         │            │
                         snowloaded  snowfield  snowfieldloaded
```

### Base Image

The `base` image ([mkosi.images/base/mkosi.conf](mkosi.images/base/mkosi.conf)) provides the foundation for all derivatives:

- Debian Trixie (testing) with main, contrib, non-free, and non-free-firmware repositories
- systemd, systemd-boot, and boot infrastructure
- Network management (NetworkManager, iwd)
- Container tooling prerequisites (erofs-utils, skopeo)
- Firmware packages for common hardware
- Core utilities (fish, zsh, vim, git)

### System Extensions (sysexts)

Sysexts are overlay images that extend the base system without modifying it. They're built with `Format=sysext` and `Overlay=yes`:

| Sysext     | Contents                               | Config                                                           |
| ---------- | -------------------------------------- | ---------------------------------------------------------------- |
| **docker** | Docker CE, containerd, buildx, compose | [mkosi.images/docker/mkosi.conf](mkosi.images/docker/mkosi.conf) |
| **incus**  | Incus, QEMU/KVM, OVMF, virt-viewer     | [mkosi.images/incus/mkosi.conf](mkosi.images/incus/mkosi.conf)   |
| **podman** | Podman, Distrobox, buildah, crun       | [mkosi.images/podman/mkosi.conf](mkosi.images/podman/mkosi.conf) |

## How Profiles Work

Profiles in `mkosi.profiles/` define complete image variants by composing shared components. Each profile's `mkosi.conf` uses `Include=` directives to pull in reusable configuration fragments from the `shared/` directory.

### Profile Structure

```
mkosi.profiles/
├── snow/           ← GNOME desktop + backports kernel
├── snowfield/      ← GNOME desktop + Surface kernel
├── snowloaded/     ← snow + extra packages (Edge, Incus)
└── snowfieldloaded/← snowfield + extra packages
```

### Shared Components

The `shared/` directory contains reusable configuration fragments that profiles include:

```
shared/
├── kernel/
│   ├── backports/mkosi.conf   ← Trixie backports kernel + firmware
│   ├── surface/mkosi.conf     ← linux-surface kernel + iptsd
│   └── scripts/               ← dracut postinst scripts
├── outformat/
│   └── oci/
│       ├── mkosi.conf         ← Sets Format=oci
│       ├── finalize/          ← OCI finalization scripts
│       └── postoutput/        ← OCI tagging scripts
├── packages/
│   ├── snow/mkosi.conf        ← GNOME desktop packages (~490 lines)
│   ├── edge/mkosi.conf        ← Microsoft Edge browser
│   └── virt/mkosi.conf        ← Incus virtualization
└── snow/
    ├── tree/                  ← Extra files overlaid into image
    └── scripts/
        ├── build/             ← Build-time scripts (brew, surface-cert)
        └── postinstall/       ← Post-installation customizations
```

### Example: snow Profile

The [snow profile](mkosi.profiles/snow/mkosi.conf) composes a GNOME desktop image:

```ini
[Output]
ImageId=snow
Output=snow

[Content]
# Overlay additional files into the image
ExtraTrees=%D/shared/snow/tree

# Build-time scripts
BuildScripts=%D/shared/snow/scripts/build/brew.chroot
BuildScripts=%D/shared/snow/scripts/build/surface-cert.chroot

# Post-installation scripts (run after packages installed)
PostInstallationScripts=%D/shared/kernel/scripts/postinst/mkosi.postinst.chroot
PostInstallationScripts=%D/shared/snow/scripts/postinstall/snow.postinst.chroot

# Finalization (prepare for boot)
FinalizeScripts=%D/shared/outformat/oci/finalize/mkosi.finalize.chroot

# Post-output (tag OCI image)
PostOutputScripts=%D/shared/outformat/oci/postoutput/mkosi.postoutput

[Include]
# Package sets
Include=%D/shared/packages/snow/mkosi.conf   # GNOME desktop
Include=%D/shared/kernel/backports/mkosi.conf # Backports kernel
Include=%D/shared/outformat/oci/mkosi.conf    # OCI output format
```

### Profile Comparison

| Profile             | Kernel    | Extra Packages | Include Path                                         |
| ------------------- | --------- | -------------- | ---------------------------------------------------- |
| **snow**            | backports | —              | `kernel/backports`, `packages/snow`, `outformat/oci` |
| **snowfield**       | surface   | —              | `kernel/surface`, `packages/snow`, `outformat/oci`   |
| **snowloaded**      | backports | Edge, Incus    | + `packages/edge`, `packages/virt`                   |
| **snowfieldloaded** | surface   | Edge, Incus    | + `packages/edge`, `packages/virt`                   |

## Building Images

### Prerequisites

- [mkosi](https://github.com/systemd/mkosi) (v24+)
- [just](https://github.com/casey/just) task runner
- Root/sudo access (mkosi requires privileges for chroot operations)

### Build Commands

```bash
# List available build targets
just

# Build system extensions only (docker, incus, podman)
just sysexts

# Build snow desktop image
just snow

# Build snowfield (Surface devices)
just snowfield

# Build loaded variants
just snowloaded
just snowfieldloaded

# Clean build artifacts
just clean
```

### Build Process

1. **Base Build**: The `base` image is built first and cached in `output/base/`
2. **Profile Application**: Selected profile's `mkosi.conf` is loaded, which includes shared components
3. **Package Installation**: Packages from all included configs are installed
4. **Script Execution**: Build → PostInstall → Finalize → PostOutput scripts run in order
5. **Output Generation**: Final image written to `output/` in the configured format

### Output Artifacts

```
output/
├── base/                    # Base image directory (build cache)
├── snow/                    # OCI image directory
├── snow.manifest            # Package manifest (JSON)
├── snow.vmlinuz             # Extracted kernel for boot
├── docker.raw               # Docker sysext (erofs)
├── docker.manifest          # Package manifest
├── incus.raw                # Incus sysext
├── podman.raw               # Podman sysext
└── ...
```

## Repository Configuration

External repositories are configured in `mkosi.sandbox/etc/apt/` for packages not in Debian:

- **Docker**: docker.com official repository
- **Incus**: Zabbly repository
- **linux-surface**: Surface kernel packages
- **Frostyard**: Custom packages (nbc, chairlift, updex)

## Extending the Build

### Adding a New Package Set

1. Create `shared/packages/mypackages/mkosi.conf`:

   ```ini
   [Content]
   Packages=package1
            package2
   ```

2. Include it in a profile:
   ```ini
   [Include]
   Include=%D/shared/packages/mypackages/mkosi.conf
   ```

### Adding a New Profile

1. Create `mkosi.profiles/myprofile/mkosi.conf`
2. Set output name and include required components
3. Add a just target:
   ```just
   myprofile: clean
       mkosi --profile myprofile build
   ```

### Adding a New Sysext

1. Create `mkosi.images/mysysext/mkosi.conf`:

   ```ini
   [Output]
   ImageId=mysysext
   Overlay=yes
   Format=sysext

   [Content]
   Bootable=no
   BaseTrees=%O/base
   Packages=...
   ```

2. The sysext will be built automatically with `just sysexts`

## License

See individual package licenses. This build system configuration is provided as-is.
