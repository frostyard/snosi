# monorepo plan

```
                          base            <- stuff that makes debian + bootc
                            |
                -------------------------
                |                       |
              cayo*  (server stuff)   snow* (desktop/gnome)
                  |                     |
          ----------------------      ---------------------------
          [docker] [incus] [virt]     |                 |       |
                                      /snowspawn/       loaded*  snowfield* (surface)
                                      * nspawn version
                                      * for home bind
                                      * install anything

legend:
  * oci
  [sysext]
  /tar/ for nspawn
```

This system defines one base image named `base`, and (currently) two sysext images (docker, incus).
Profiles are added to the build command to layer configuration needed to build the desired output images.

## Composite Image Definitions

Images don't include kernel or modules, these get added with PROFILES

- base - everything that makes debian
- cayo - debian server
- cayo-bpo - cayo + backports kernel
- incus - sysext for base and above
- docker - sysext for base and above
- snow - gnome desktop + bp
- snowloaded - snow + bp + loaded profile
- snowfield - snow + surface profile

## Available Profiles

- stock: stable kernel + modules
- backports: backport kernel + modules
- bootc: nbc & bootc, things that make bootable container
- oci: output oci image
- tar: output image tar (for nspawn)
- sysext-only: don't output "main" image
- loaded: some gui packages that don't flatpak well
- surface: linux-surface kernel
- snow - gnome desktop

## Builds

All image builds must either have stock or backports profile -- that's the kernel & modules.

- cayo = base <-profiles (cayo + stock + oci + bootc)
- cayo-bpo = base <- profiles (cayo + backports + oci + bootc)
- snow = base <- profiles (snow + bpo + oci + bootc)
- snowloaded = base <- profiles (snow + bpo + oci + bootc + loaded)
- snowfield = base <- profiles (snow + bpo + oci + bootc + surface)
- incus = base << incus sysext
- docker = base << docker sysext

```bash
snow> mkosi --profile 10-image-snow --profile 20-kernel-backports --profile 80-finalize-bootc --profile 90-output-oci build
snowloaded> mkosi --profile 10-image-snow --profile 20-kernel-backports --profile 30-packages-loaded --profile 40-name-snowloaded --profile 80-finalize-bootc --profile 90-output-oci build
snowfield> mkosi --profile 10-image-snow --profile 20-kernel-surface --profile 40-name-snowfield --profile 80-finalize-bootc --profile 90-output-oci build
snowfieldloaded> mkosi --profile 10-image-snow --profile 20-kernel-surface --profile 30-packages-loaded --profile 40-name-snowfieldloaded --profile 80-finalize-bootc --profile 90-output-oci build

```

## Profiles

Profiles are grouped by precedence importance. Lower numbered profiles should be specified first on the command line.

### Image Profiles "10-image-XXX"

These define the core set of images we're delivering.

- 10-image-cayo: defines the cayo packages and build scripts
- 10-image-snow: defines the snow packages and build scripts

### Kernel and Modules "20-kernel-XXX"

These define the kernel and kernel modules added to the image.

- 20-kernel-backports: trixie backports kernel and modules
- 20-kernel-stock: trixie stable kernel and modules

### Extra Packages "30-packages-XXX"

These define extra packages to be added to image variants. The only current example is "30-packages-loaded" which adds Edge, VSCode and NordVPN. Images built with extra packages should have a different oci image name from those without. `snow` vs `snow-loaded`. Imagine `ucore`, `ucore-hci`, `ucore-zfs`, etc.

Stacking packages has not been tested, and might not work without extra config/processing, e.g.`hci` plus `zfs`. For now only add one profile from the `30-packages` group.

- 30-packages-loaded: adds edge, vscode, nordvpn for `snow-loaded` image

### Image Variants "40-name-XXX"

Use these profiles to change the name of the image being output. For example, when building snowfield, we add the `20-kernel-surface` profile and the `10-image-snow` profiles, but we want the image to be named `snowfield`.

These profiles override the output names from the `10-image-XXX` image profiles for image variants.

- 40-name-snowfield: change image name to snowfield
- 40-name-snowloaded: change image name to snowloaded
- 40-name-snowfieldloaded: change image name to snowfieldloaded

### Finalization "80-finalize-XXX"

These profiles define mostly scripts that need to be done to prepare for a specific image type. `bootc` and `nbc` require the kernel image and initrd to be located in specific places on the image.

- 80-finalize-bootc: builds initramfs and moves the kernel.

### Output "90-output-XXX"

These profiles configure the output type of the built image. The "main" image specifies `Output=none`, so an output profile is required to get any output image.

- 90-output-oci: builds the image as an oci-archive directory
- 90-output-sysext-only: sets the "main" image to no output so only the sysexts will be built
- 90-output-tar: sets the image to output as a .tar archive. Unused currently, intended for systemd-nspawn output to be used on images.

## Profile Order Matters

Configurations are overlayed in the order of profiles added on the command line.

Given this command line:

```bash
mkosi build --profile snow --profile backports --profile bootc
```

The configuration from the `main` image (everything in the root of the repo) is loaded,
then the `snow` configuration is overlayed, then `backports` on top of that, finally `bootc`.

The same applies for the scripts like `mkosi.postinst` or `mkosi.postoutput` etc.
They're applied in the same order they're listed on the command line.

An example of how this could break things:

1. The `loaded` profile installs a package with things that get installed to `opt`. As part of post-processing
   you need to move them to `/usr/something`.

2. The `bootc` profile removes `/opt` and creates an empty directory for mounting `/var/opt`.

If you specify the `bootc` profile before the `loaded` profile, you may not end up with `/opt` in the condition you expect after the image is built.

Because of this, profiles have been named with required precedence hints in the names.

## Warning

actions in this branch are not correct yet!

## TODO

- [x] rework image and OCI env vars
- [x] podman & friends as sysext, removed from all images by default
- [ ] snowfield cert into snow image for mokutil
- [x] remove incus from snow
- [x] remove docker from snow
- [ ] test and fix incus and docker extensions. Not expected to work as-is.
- [ ] investigate isolating sandbox keys/conf per image -- don't add nordvpn repo to images that don't need it, for example
