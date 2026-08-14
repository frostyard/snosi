---
name: Profile or sysext proposal
about: Propose a supported image profile or system extension
title: "[profile/sysext] "
labels: "enhancement"
assignees: ""
---

## Contribution type

- [ ] Profile (a supported transport and kernel combination)
- [ ] System extension (an optional `/usr` overlay)
- [ ] Maintenance or deprecation of an existing profile or sysext

## User need

Who needs this, and what supported use case does it enable?

## Proposed shape

- Profile, product, or sysext name:
- Closest existing example:
- Upstream package/source and release channel:
- Expected files and services:
- Hardware or runtime requirements:

For a profile, identify the existing shared composition, kernel, and transport
fragments it will select. For a sysext, explain any `/opt` relocation, factory
`/etc` defaults, service activation, or direct download.

## Update and validation plan

- How will upstream releases be detected and verified?
- Which targeted build and fixture/static checks will prove the change?
- Does validation require hardware, virtualization, credentials, or network
  access not available in pull-request CI?

## Stewardship

- Maintenance contact (GitHub handle):
- Expected response/update cadence:
- Handoff plan if you can no longer maintain it:

Maintainers retain final review, security-response, and removal authority.
Stewardship is shared responsibility, not exclusive ownership.

## Acceptance checklist

- [ ] I read the
  [profile and sysext contribution guide](https://github.com/frostyard/snosi/blob/main/docs/design/contributing-profiles-and-sysexts.md).
- [ ] The contribution fits the supported profile or sysext shape.
- [ ] Redistribution, licensing, and update sources are identified.
- [ ] The proposal has a named maintenance contact and handoff plan.
- [ ] No credentials, private keys, or vulnerability details are included.

Report security vulnerabilities privately through the
[security policy](https://github.com/frostyard/snosi/security/policy), not in
this issue.
