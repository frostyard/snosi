# Security

If you believe you have found a security vulnerability in snosi, report it
privately.

## Supported versions

snosi publishes rolling images; there are no maintained release branches.

| Artifact | Gets security fixes |
| --- | --- |
| The `main` branch | Yes |
| The newest published `snow`, `snowfield`, `floe` and `sundog` images (`latest`) | Yes: a fix ships in the next published image |
| The newest published sysexts and the newest Firn installer ISO | Yes: a fix ships in the next published artifact |
| Older image digests, sysext revisions and ISOs | No: update to the newest image (`bootc-update-stage.timer` stages it) |

## Reporting a vulnerability

- Do **not** report security vulnerabilities through public GitHub issues.
- Use GitHub private vulnerability reporting for this repository:
  <https://github.com/frostyard/snosi/security> (the **Report a
  vulnerability** button on the Security tab).
- If that button is not available, email the project maintainer at
  [bketelsen@gmail.com](mailto:bketelsen@gmail.com). Use a subject such as
  `[snosi security] Brief description`.

The **New draft security advisory** page is a maintainer workflow and is not a
fallback reporting channel for people without repository write access.

## Guidelines

- Include the affected image, version or commit, impact, and complete
  reproduction steps when possible.
- Do not send credentials, private signing material, or executables.
- You may include scripts you wrote, but do not send scripts that download and
  run binaries.
- We prioritize reports that demonstrate realistic impact.
- We prefer communications in English.
- We do not offer financial rewards. We are happy to acknowledge your research
  publicly when possible.
