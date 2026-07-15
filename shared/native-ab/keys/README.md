# Native A/B update signing pubring (DEV)

`import-pubring.gpg` is a **DEV-only** OpenPGP public keyring (binary
`gpg --export` format, ed25519 signing key, no passphrase). It exists so the
three production native profiles (`cayo-ab`, `snow-ab`, `snowfield-ab`) can
carry a real, non-empty `/usr/lib/systemd/import-pubring.gpg` and satisfy
`check-native-publication-guard.sh` / `docs/native-ab-contracts.md` §7/§15
before the protected signing pipeline exists.

- **uid:** `snosi native OS updates (DEV — rotate before production)
  <os-updates@frostyard.org>`
- **Private half:** `.snosi-private/os-update-signing.key` (gitignored,
  never committed, never printed). Nothing in this repo needs it yet —
  dev/local `SHA256SUMS` are unsigned/unpublished (`docs/native-ab-
  contracts.md` §7 key table).
- **Ships at:** `/usr/lib/systemd/import-pubring.gpg` on every native A/B
  image via a `file:target` `ExtraTrees=` pair in the generic
  `shared/outformat/ab-root/mkosi.conf` fragment (consumed by all native
  profiles, including the never-published `cayo-ab-raw` dev fixture).
- **QEMU tests are unaffected:** `test/native-ab-update-test.sh` and the
  other QEMU harnesses generate and inject their own ephemeral signing keys
  via `--definitions` overrides; they never rely on this dev key.

**This key MUST be rotated before first production publication.** The real
key ceremony is `docs/native-ab-contracts.md` §7 ("Protected signing
architecture"): the production private key lives only in the protected
promotion environment, never in this repository or in `.snosi-private`, and
rotation follows the overlap-window procedure in §7 (both old and new public
keys ship simultaneously until every supported client has fetched an
index signed by the new key). Do not treat this DEV key as adequate custody
for anything published to `repository.frostyard.org`.

## MOK certificate (DEV)

`mok-dev.crt` is a plain copy of the repository root's gitignored
`mkosi.crt` (the Secure Boot/MOK **public certificate** -- `openssl x509`,
DER/PEM, no private key material; the matching private key, `mkosi.key`,
stays gitignored and is never copied here). Committing the certificate is
safe by design: a certificate is exactly the thing you hand out for
verification, the same reasoning that already applies to
`import-pubring.gpg` above.

- **Ships at:** `/usr/lib/snosi/mok-dev.crt` on the network-installer ISO
  (`shared/native-installer/mkosi.conf` `ExtraTrees=`), and effectively
  public already inside every secure native profile's own MOK-signed
  boot chain (`cayo-ab`, `snow-ab`, `snowfield-ab`) -- this file just gives
  `snosi-install` (and `--restage-mok`) a copy to `mokutil --import` without
  depending on gitignored dev material being present on the machine running
  the installer build.
- **Used by:** `snosi-install`'s MOK enrollment step (plan step 16-17) and
  `--restage-mok` recovery mode, both overridable with `--mok-cert <path>`
  for testing against a different signing key.
- **This is DEV-only material.** Production MOK certificate custody follows
  `docs/native-ab-contracts.md` §7 "MOK Rotation": the production
  certificate is committed the same way (certificates are public), but the
  private key that signs UKIs/systemd-boot/modules never leaves the
  protected signer.
