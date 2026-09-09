# Microsoft Entra ID login with the himmelblau sysext

[Himmelblau](https://himmelblau-idm.org) lets a Linux machine authenticate
users against Microsoft Entra ID (Azure AD): console and GDM logins, SSH with
MFA, Windows Hello style PIN, a TPM-bound device identity, Intune compliance
checks, Kerberos tickets for Azure resources, and browser single sign-on.
snosi ships it as the `himmelblau` sysext. This page is the operator guide;
the authoring details live in
[docs/design/sysexts.md](design/sysexts.md#himmelblau).

On a mutable Debian host you would run the upstream bootstrapper
(`curl -fsSL https://himmelblau-idm.org/install | sh`), which adds an APT
repository, installs packages, asks for your domain, writes
`/etc/himmelblau/himmelblau.conf` and enables the services. On snosi the
packages arrive as a sysext, activation is image-defined, and runtime
`systemctl enable` is forbidden, so only the configuration step remains. That
step is `snosi-himmelblau-setup`.

## What the sysext contains

| Package | Role |
| --- | --- |
| `himmelblau` | `himmelblaud` (authentication daemon, TPM-backed HSM PIN), `himmelblaud_tasks` (home directories, groups, Kerberos cache), `aad-tool` |
| `nss-himmelblau`, `pam-himmelblau` | name-service and PAM modules; the PAM profile is enabled with `pam-auth-update` |
| `himmelblau-sshd-config` | `KbdInteractiveAuthentication yes` drop-in so SSH logins can complete MFA prompts |
| `himmelblau-broker`, `himmelblau-sso`, `himmelblau-sso-policies` | user-session identity broker and the browser SSO native-messaging host (Firefox, Chromium, Chrome) |
| `o365` | Office 365 web-app launchers (Outlook, Teams, Word, ...) |
| `krb5-user` | `kinit`/`klist` for the Kerberos ticket cache Himmelblau maintains |

Not included: `himmelblau-qr-greeter` (the GDM QR-code prompt for phone
sign-in; it hard-depends on `gnome-shell`) and `himmelblau-apparmor` (Trixie
keeps the relevant AppArmor profile in complain mode).

## Enable and configure

1. Enable the `himmelblau` feature with Updex (or drop the `.raw` into
   `/var/lib/extensions.d/` and `systemd-sysext refresh`). The boot-time
   integration runs as soon as the extension is merged; `himmelblaud` itself
   is skipped (condition not met) until `/etc/himmelblau` holds configuration,
   because the 4.0.2 daemon exits when no domain is set.
2. Run the setup tool as root:

   ```bash
   sudo snosi-himmelblau-setup --domain example.com
   ```

   Run it with no arguments on a terminal for interactive prompts. Common
   additions:

   ```bash
   sudo snosi-himmelblau-setup --domain example.com \
     --map bjk=brian@example.com \
     --join-type register \
     --set enable_experimental_mfa=true
   ```

   | Option | Effect |
   | --- | --- |
   | `--domain DOMAIN` | Entra ID sign-in domain |
   | `--map LOCAL=UPN` | make an existing local account authenticate through Entra ID under its current username (repeatable; maintains `/etc/himmelblau/user-map`). Required for browser SSO from that account, see troubleshooting |
   | `--join-type join\|register` | device registration mode |
   | `--hsm-type TYPE` | `tpm_bound_soft_if_possible` (default), `tpm` (require the TPM), `tpm_if_possible`; pick this before the first login, see troubleshooting |
   | `--allow-groups LIST` | restrict sign-in to these group object IDs / UPNs |
   | `--sudo-groups LIST` | grant local sudo to members of these groups |
   | `--enable-hello` / `--disable-hello` | Windows Hello PIN enrollment |
   | `--apply-policy` / `--no-apply-policy` | Intune enrollment and compliance checks. Default on, as in the upstream installer: `apply_policy` gates both the device's Intune enrollment (done during the next login or screen unlock) and `himmelblau-compliance-check.timer`. Off, a tenant that requires a compliant device answers every token request with `AADSTS530003` and browsers loop on "register your device" |
   | `--set KEY=VALUE`, `--unset KEY` | any other option from `himmelblau.conf(5)` |
   | `--show` | print the current configuration and exit |
   | `--no-restart` | write configuration only |

   The tool writes `/etc/himmelblau/himmelblau.conf.d/50-snosi-setup.conf`,
   merges the user map, replays the `/etc` integration (see below), restarts
   `himmelblaud`, and prints `aad-tool status`. Re-running it keeps earlier
   settings unless you override them, so you can add a `--map` later without
   repeating `--domain`.

3. Sign in. At the GDM screen choose **Not listed?** and enter the UPN
   (`user@example.com`). Over SSH:

   ```bash
   ssh 'user@example.com'@host
   ```

   and complete the MFA prompt. Mapped local accounts keep their username;
   their local password no longer applies.

## Why a drop-in, not `/etc/himmelblau/himmelblau.conf`

`himmelblau.conf(5)` reads only the highest-priority *main* file that exists
(`/etc` over `/run` over `/usr/lib`). Creating `/etc/himmelblau/himmelblau.conf`
therefore hides the deb's `/usr/lib/himmelblau/himmelblau.conf`, and with it
the Debian-required defaults it carries (`local_groups = users`,
`home_attr`/`home_alias = CN`, `use_etc_skel = true`). The upstream installer
works around that by re-emitting those lines. The snosi tool instead writes a
drop-in, which layers on top of the main file. Put any hand-maintained
overrides in their own `/etc/himmelblau/himmelblau.conf.d/*.conf`; the tool
only ever rewrites `50-snosi-setup.conf`.

## What happens at boot

`himmelblau-sysext-setup.service` runs after the sysext merge and before
`himmelblaud`, GDM and sshd. It replays, idempotently, what the deb maintainer
scripts do on a mutable host: adds `himmelblau` to the `passwd`, `group` and
`shadow` databases in `/etc/nsswitch.conf`, enables the PAM profile with
`pam-auth-update` (once), lets GDM's `pam_gnome_keyring` reuse the Hello PIN
to unlock the login keyring, and makes sure `/etc/krb5.conf` includes
`/etc/krb5.conf.d`. It only adds to files under `/etc`; it never deletes and
never enables units, so bootc's `/etc` merge on update is unaffected. The
sshd and browser SSO files the debs install under `/etc` are placed from
`/usr/share/factory` by systemd-tmpfiles, copy-if-absent, so local edits
survive.

On first start `himmelblau-hsm-pin-init.service` generates the HSM PIN and
seals it with `systemd-creds`, TPM-bound when a TPM and its storage root key
are available (secure bootc and native installs provision the SRK through
`systemd-tpm2-setup`; the init script self-provisions on other systems).

## Checking and troubleshooting

```bash
sudo aad-tool status            # daemon reachable and online
sudo aad-tool tpm               # is the HSM PIN TPM-bound
sudo aad-tool auth-test user@example.com
sudo snosi-himmelblau-setup --show
journalctl -u himmelblaud -u himmelblaud-tasks -u himmelblau-sysext-setup -b
klist                           # Kerberos ticket after an Entra login
```

- `systemctl status himmelblaud` says "condition not met": run the setup
  tool; the daemon is deliberately skipped until a domain is configured.
- Browser SSO loops through Hello PIN / FIDO prompts and never loads the
  page, and `journalctl --user -u himmelblau-broker` repeats "Silent PRT SSO
  cookie unavailable; attempting interactive re-auth": you are logged in as a
  plain local account. himmelblaud keys the Primary Refresh Token by Unix
  account, and a local user has no Entra identity to cache it under, so
  every request re-authenticates (himmelblaud logs "Broker method failed for
  uid N: Unable to find account"). Map the account
  (`snosi-himmelblau-setup --map LOCAL=UPN`), run `aad-tool cache-clear` so
  the UPN resolves to the local uid, then log out and back in through Entra
  (root-caused live 2026-09-09).
- Browsers say the device must be registered / managed, and `journalctl -u
  himmelblaud` shows `AADSTS530003` on "Failed to exchange PRT for access
  token": the tenant requires an Intune-compliant device and this one is not
  enrolled. Make sure the drop-in has `apply_policy = true` (the wizard's
  default; `--no-apply-policy` removes it), then lock and unlock the screen
  or log in again so the enrollment runs inside an authentication
  (`himmelblaud-tasks` logs `apply_intune_policy ... intune_device_id`), and
  confirm with `aad-tool compliance-check` from your session. The Ubuntu
  reference host enrolled on its first login because the upstream installer
  writes `apply_policy = true`.
- Changing `--hsm-type` after the daemon has already started (for example
  moving from the default soft HSM to `tpm`) makes himmelblaud fail with
  "Unable to load machine root key ... IncorrectKeyType": the machine key
  was created by the previous HSM. Stop `himmelblaud`, delete
  `/var/cache/private/himmelblaud/himmelblau.cache.db`, start it again.
  That forgets the device registration and any enrolled Hello PIN; the
  device re-registers on the next sign-in. Decide the HSM type before the
  first login to avoid this (verified live 2026-09-09).
- Logins fail with "user unknown": confirm `getent passwd user@example.com`
  resolves; if not, `/etc/nsswitch.conf` lacks `himmelblau` -- run
  `sudo /usr/lib/himmelblau/himmelblau-sysext-setup` and check its journal.
- SSH never prompts for MFA: `sshd -T | grep -i kbdinteractive` must say
  `yes`; the drop-in is `/etc/ssh/sshd_config.d/30-himmelblau.conf`.
- Browser SSO: the user-session broker is D-Bus activated on first use
  (`systemctl --user status himmelblau-broker`); log out and back in after
  the first merge so the session bus sees the new service file. Firefox
  needs the linux-entra-sso extension; Chromium/Chrome get it through the
  managed policy in `/etc/chromium/policies/managed/himmelblau.json`.
- `snosi-etc-diff` will list `nsswitch.conf`, `pam.d/common-*` and, on
  desktops, `pam.d/gdm-password` as modified. That drift is the integration
  and is expected.

## Removing

Disable the feature in Updex (or remove the `.raw`) and reboot. The NSS and
PAM entries stay in `/etc` but reference modules that no longer exist, which
glibc and PAM ignore (`pam_himmelblau` lines are `default=ignore`); use
`snosi-etc-diff --restore /etc/nsswitch.conf` and
`sudo pam-auth-update --remove himmelblau` to clean them up. Device state
lives in `/var/lib/private/himmelblaud` and `/var/cache/himmelblaud`.
