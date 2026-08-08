# systemd import keyring

`import-pubring.gpg` is the binary OpenPGP keyring shipped at both
`/usr/lib/systemd/import-pubring.gpg` (systemd 257) and
`/usr/lib/systemd/import-pubring.pgp` (systemd 261). It contains:

- Native OS update key: `F37282A35CB6BDFEBFC8FE775A2EAC5C8216FD68`
- Frostyard repository key: `432C452CD2B7F4FF1B5D23264DE6A2016E622F97`

The repository key verifies the `SHA256SUMS.gpg` that repogen publishes beside
each sysext manifest. The native key verifies signed native A/B OS manifests.
systemd-sysupdate supports one vendor keyring for all transfers, so native
images need both public keys in their runtime ring.

Regenerate the combined ring byte-for-byte from the two canonical public keys:

```sh
cat shared/native-ab/keys/import-pubring.gpg \
    mkosi.sandbox/etc/apt/keyrings/frostyard.gpg \
    > shared/sysext/keys/import-pubring.gpg
```

The native-only keyring remains the trust root used by native publication
verification scripts; this combined ring is only the in-image systemd trust
store. Never commit either private key.
