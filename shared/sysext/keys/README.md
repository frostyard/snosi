# systemd sysext verification keyrings

The generic base image ships the repository-only binary OpenPGP keyring from
`mkosi.sandbox/etc/apt/keyrings/frostyard.gpg` at both
`/usr/lib/systemd/import-pubring.gpg` (systemd 257) and
`/usr/lib/systemd/import-pubring.pgp` (systemd 261). It contains the Frostyard
repository key `432C452CD2B7F4FF1B5D23264DE6A2016E622F97`, which verifies the
`SHA256SUMS.gpg` that repogen publishes beside each sysext manifest.

Native A/B profiles overlay those paths with `import-pubring.gpg`, a combined
ring containing the repository key and native OS-update key
`F37282A35CB6BDFEBFC8FE775A2EAC5C8216FD68`. systemd-sysupdate supports one
vendor keyring for all transfers, so native images need both public keys while
bootc images should not trust the unrelated OS-update signer.

Regenerate the combined ring byte-for-byte from the two canonical public keys:

```sh
cat shared/native-ab/keys/import-pubring.gpg \
    mkosi.sandbox/etc/apt/keyrings/frostyard.gpg \
    > shared/sysext/keys/import-pubring.gpg
```

The native-only keyring remains the trust root used by native publication
verification scripts; the combined ring is only the native image's systemd
trust store. Never commit either private key.
