# Snosi Roadmap

This roadmap describes the outcomes Snosi is pursuing and the decisions needed
to make its bootable images and system extensions easier to evaluate, adopt,
and maintain. It is directional rather than a support warranty. The
[installation guide](docs/installing.md), security documentation, and
profile-specific contracts remain authoritative for current behavior.

## Product direction

Snosi's differentiator is a Debian-first, mkosi-based system that delivers both
bootable OCI images and independently updateable system extensions, with
signed artifacts and explicit publication contracts. The roadmap prioritizes
making those capabilities consumable by operators before expanding the number
of output formats or profiles.

Work is guided by four principles:

1. Promote immutable artifacts only after their security and update contracts
   pass.
2. Make supported, candidate, and experimental behavior obvious before
   installation.
3. Prefer upstream mkosi, systemd, and bootc contracts over local compatibility
   adapters when equivalent stable interfaces exist.
4. Grow the profile and system-extension ecosystem without weakening ownership
   or maintenance expectations.

## Product tracks

| Track | Current focus | Next maturity gate |
| --- | --- | --- |
| Bootable OCI images | Debian desktop and server profiles, signed images, SBOMs, provenance, and digest-first promotion | Publish a concise support matrix and close the documented secure fresh-install proof gaps |
| Native A/B images | Secure Boot, measured UKIs, dm-verity roots, systemd-sysupdate, rollback, and recovery | Complete hardware soak evidence and production key-management readiness |
| System extensions | Independently versioned application and platform components | Define contributor ownership, compatibility, and retirement policy |
| Build and release platform | Reproducible mkosi inputs and fail-closed publication guards | Separate continuous artifacts from intentional product release signals |

## Near term: adoption clarity

Target horizon: the next 90 days.

- Publish one support and compatibility matrix covering every distributed
  profile, installation path, update mechanism, and known proof gap.
- Define `continuous`, `candidate`, and `stable` channels, including promotion,
  retention, rollback, and withdrawal expectations.
- Make GitHub Releases emphasize promoted user-facing releases rather than
  presenting every successful build as an equivalent product milestone.
- Consolidate the shortest safe path from download through signature
  verification, installation, update, rollback, and recovery.
- Complete and publish the remaining native A/B hardware-soak and key-ceremony
  evidence.
- Seed a contributor funnel with templates and scoped starter work for profiles
  and system extensions.

**Exit signal:** a new evaluator can identify the recommended artifact, its
support level, its verification steps, and its upgrade contract from one
navigation path.

## Mid term: ecosystem durability

Target horizon: three to nine months.

- Track upstream bootc and mkosi interfaces and retire local compatibility
  boundaries when stable upstream replacements are available.
- Establish ownership and maintenance expectations for contributed profiles
  and system extensions, including deprecation criteria.
- Publish tested hardware and deployment scenarios for desktop, server,
  Surface, and recovery workflows.
- Add release notes organized around operator impact: install, update,
  compatibility, security, and required action.
- Collect opt-in adopter reports and convert recurring deployment patterns into
  documented reference configurations.

**Exit signal:** at least two non-maintainer contributors own maintained
extensions or profiles, and supported deployment scenarios have repeatable
evidence outside the primary development environment.

## Long term: operational scale

Target horizon: nine months and beyond.

- Define fleet-safe staged rollout and failure-domain guidance without coupling
  Snosi to a single fleet manager.
- Evaluate additional architectures or hardware classes only when automated
  boot, update, rollback, and recovery coverage can accompany them.
- Publish a compatibility policy for major Debian, systemd, mkosi, and bootc
  transitions.
- Measure adoption through verified installations, maintained external
  contributions, successful update paths, and recovery outcomes rather than
  artifact volume alone.

**Exit signal:** Snosi has a documented lifecycle for introducing, promoting,
supporting, deprecating, and retiring every distributed product track.

## Roadmap governance

- Roadmap changes should link to an issue that states the adoption or
  operational outcome.
- A milestone is complete only when its user-facing documentation and evidence
  are published.
- Security or recovery blockers take precedence over profile expansion.
- Experimental work must remain visibly separated from supported installation
  paths.
- Review this document quarterly and record meaningful priority changes in the
  relevant issue or decision record.

Detailed implementation plans and architecture decisions live under
[`docs/plans/`](docs/plans/) and [`docs/adr/`](docs/adr/).

