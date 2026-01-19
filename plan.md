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

## Images

Images don't include kernel or modules, these get added with PROFILES

- base - everything that makes debian
- cayo - debian server
- cayo-bpo - cayo + backports kernel
- incus - sysext for base and above
- docker - sysext for base and above
- snow - gnome desktop + bp
- snowloaded - snow + bp + loaded profile
- snowfield - snow + surface profile

## Profiles

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

```
snowloaded> mkosi build --profile backports --profile bootc --profile snow --profile loaded
snow> mkosi build --profile backports --profile bootc --profile snow
cayo> mkosi build --profile bootc --profile stock --profile cayo
```

actions in this branch are not correct yet!
