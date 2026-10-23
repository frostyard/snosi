# 0019 — Ship no build-time private keys in images

- **Status:** Accepted
- **Date:** 2026-10-23

## Context

Published images are public and every install of one image carries the same
bytes. Package maintainer scripts generate keys while mkosi installs packages:
`ssl-cert`'s postinst runs `make-ssl-cert generate-default-snakeoil`, writing
`/etc/ssl/private/ssl-cert-snakeoil.key`. `cups-daemon` depends on `ssl-cert`,
so Snow, Snowfield and Sundog shipped a snakeoil key (a different one per
image, shared by every install of that image) until this change. Floe and the
sysexts did not: Floe has no `cups-daemon`, and sysexts pack only `/usr` and
`/opt`. SSH host keys were already removed in finalize. Nothing in the images
uses the snakeoil pair: CUPS keeps its own credentials in `/etc/cups/ssl`,
`gnome-user-share`'s Apache config has no TLS, and no shipped unit or config
references the pair.

## Decision

- `shared/outformat/image/finalize/mkosi.finalize.chroot` removes the snakeoil
  key, certificate and its `/etc/ssl/certs` hash link. Images do not
  regenerate the pair at boot, because nothing needs it. An administrator who
  needs it runs `make-ssl-cert generate-default-snakeoil`.
- `shared/security/no-private-keys.finalize` runs after the image finalize in
  every OCI composition. Through `shared/sysext/finalize/sysext-no-private-keys.sh`
  it also runs on `/usr` and `/opt` in every sysext. It fails the build for
  any file under `/etc/ssl/private/`, any `/etc/ssh/ssh_host_*_key`, and any
  text file with a PEM, OpenSSH or PGP private-key header on a line of its
  own. Files a package installed (listed in dpkg's `*.list`) are exempt
  because package payload is public and identical on every install, for
  example ovmf's `PkKek-1-snakeoil.key` or npm test fixtures in vendor debs.
  When the package ships md5sums, the file must still match them. Owned files
  with no md5sums entry are logged as unverified. Overlay sysexts have no dpkg
  database at finalize, because mkosi removes it when dpkg is not in the upper
  layer. So public keys in sysexts, such as code-server's httpolyglot test
  fixture, are exempted only by an exact path and sha256 entry in the reviewed
  `shared/security/private-key-allowlist.txt`.
- `test/no-private-keys-test.sh` holds rejection fixtures and checks the wiring.
- The guard fails closed. If find cannot traverse a directory, grep cannot
  read a file, or a dpkg or allowlist input cannot be read, the build fails
  instead of reporting clean.

On 2026-10-13, no other private key matched in the verified vendor debs
(`shared/download/sysext-checksums.json`) or in the published Snow image.

## Consequences

- Any new package or build script that generates a key fails the build until
  finalize removes the key and, if a service needs one, a per-machine
  first-boot generator is added. Such a generator is a `/var` run-once marker
  or `ConditionPathExists=!` unit; ADR-0003 forbids runtime `/etc` deletion.
- On upgrade, bootc's three-way `/etc` merge drops the unmodified snakeoil
  files from existing installs. A key an administrator changed stays. Keys
  that already shipped stay public; nothing used them.
- An upstream bump that changes an allowlisted fixture fails the sysext build
  until a reviewer re-pins it.
- A package that overwrites one of its own md5sums-less files with a fresh
  key in its postinst would pass. That is the accepted residual risk of
  exempting vendor debs without md5sums.
- The content scan uses `grep -I`, so DER or other binary keys outside
  `/etc/ssl/private` are not detected. Archives such as
  `/usr/share/homebrew.tar.zst` are not unpacked.

## Alternatives considered

- **Generate the snakeoil pair per machine on first boot:** rejected because
  no shipped service uses it, and generating unused key material adds a unit
  for no benefit.
- **Purge `ssl-cert`:** `cups-daemon` hard-depends on it.

## References

- Shapes: [design/build-pipeline.md](../design/build-pipeline.md)
- Builds on: [ADR-0003](0003-runtime-etc-mutation-ban.md), [ADR-0004](0004-sysext-authoring-rules.md)
