# Native A/B update signing pubring

`import-pubring.gpg` is the binary (`gpg --export`) OpenPGP public keyring that
every native A/B image ships at `/usr/lib/systemd/import-pubring.gpg`, so
systemd-sysupdate can verify the detached `SHA256SUMS.gpg` on each downloaded
index. It carries the **production** update-signing public key and satisfies
`check-native-publication-guard.sh` / `docs/native-ab-contracts.md` §7/§15.

- **uid:** `snosi native OS updates <os-updates@frostyard.org>`
- **Fingerprint:** `F37282A35CB6BDFEBFC8FE775A2EAC5C8216FD68`
- **Generated:** 2026-07 (production key ceremony,
  `docs/native-ab-publication.md` §"Production key ceremony").
- **Private half:** offline only. It lives in the offline key-ceremony
  environment and, for CI, in the `native-promotion` GitHub environment as
  `NATIVE_UPDATE_SIGNING_KEY`. It is **never** committed, never an Actions
  artifact, and never placed in `.snosi-private/`; it is consumed only by
  `promote.sh --signing-key` inside the protected promotion environment.
- **Ships at:** `/usr/lib/systemd/import-pubring.gpg` on every native A/B
  image via a `file:target` `ExtraTrees=` pair in the generic
  `shared/outformat/ab-root/mkosi.conf` fragment (consumed by all native
  profiles, including the never-published `cayo-ab-raw` dev fixture).
- **QEMU tests are unaffected:** `test/native-ab-update-test.sh` and the
  other QEMU harnesses generate and inject their own ephemeral signing keys
  via `--definitions` overrides; they never rely on this key.

**Rotation** follows `docs/native-ab-contracts.md` §7 / the runbook's overlap
window: export both the outgoing and incoming public keys into this same
keyring (`gpg --export old new > import-pubring.gpg`) and rebuild every native
profile, keeping both until every supported client has booted an image carrying
the new pubring AND fetched at least one index signed by the new key; only then
drop the old key.

## MOK certificate

`mok-2026.crt` is a plain copy of the repository root's gitignored `mkosi.crt`
(the Secure Boot/MOK **public certificate** -- `openssl x509`, DER/PEM, no
private key material; the matching private key, `mkosi.key`, stays gitignored
and never enters this directory). Committing the certificate is safe by design:
a certificate is exactly the thing you hand out for verification, the same
reasoning that already applies to `import-pubring.gpg` above.

- **Subject:** `CN=snosi Secure Boot 2026, O=frostyard` (valid to 2036).
- **Ships at:** the version-neutral path `/usr/lib/snosi/mok.crt` on the
  network-installer ISO (`shared/native-installer/mkosi.conf` `ExtraTrees=`).
  The in-image path is deliberately version-neutral so a key rotation only
  changes the committed source filename and the one `ExtraTrees=` line, not
  `snosi-install`'s default or the ISO test.
- **Used by:** `snosi-install`'s MOK enrollment step (plan step 16-17) and
  `--restage-mok` recovery mode, both overridable with `--mok-cert <path>`
  for testing against a different signing key.
- **Private key custody:** the MOK private key (`mkosi.key`) signs
  systemd-boot, UKIs, and any Snosi-signed modules; it never leaves the
  protected signer. MOK rotation is a fleet-wide re-enrollment event -- see
  `docs/native-ab-contracts.md` §7 "MOK Rotation".
