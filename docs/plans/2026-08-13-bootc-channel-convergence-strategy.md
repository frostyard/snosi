# Bootc Channel Convergence Strategy

**Date:** 2026-08-13  
**Status:** Proposed  
**Decision horizon:** 6-12 months  
**Scope:** Converge Cayo, Snow, and Snowfield on bootc as the long-term
deployment format; retire the native A/B (`*-ab`, also referred to as DDI A/B)
images only after bootc reaches equivalent security, recovery, and operational
evidence.

## Executive decision

Bootc should be Snosi's long-term operating-system delivery path. Maintaining
bootc and native A/B as peer production formats duplicates build, installer,
update, signing, storage, recovery, publication, and test systems. That cost
slows security response and makes it harder for users to know which product to
install.

This is a convergence, not an immediate shutdown:

1. Establish `latest` and `stable` bootc channels backed by immutable digests.
2. Prove that the secure bootc path matches the native A/B security and
   recovery posture.
3. Move fresh installations to bootc `stable`, one product at a time.
4. Give native A/B users a tested backup-and-reinstall migration window.
5. Stop native A/B publication only after the exit gates in this document pass.

The current ordinary bootc live installer is not security-equivalent to the
published native A/B path. In particular, the repository currently describes
the separately gated bootc Secure Boot, MOK, TPM, and encrypted-storage path as
unsupported pending live and hardware evidence. Native A/B remains the
recommended secure-install path until that evidence exists.

## Target product and channel model

The long-term public products remain `cayo`, `snow`, and `snowfield` on GHCR.
Each product has immutable build tags and two moving channel aliases:

| Reference | Meaning | Intended user |
| --- | --- | --- |
| `<YYYYMMDDHHMMSS>` | Immutable build identity; never moved or rebuilt | CI, diagnosis, rollback, audit |
| `latest` | Newest daily candidate that passed the daily gates | Testers and early adopters |
| `stable` | Exact previously published daily digest that passed the stable gates | New installs and production use |

`latest` is a daily channel, not every-green-commit. Main-branch builds may
continue to publish immutable timestamp tags, but one scheduled daily run per
product owns advancement of `latest`. A failed daily leaves `latest` unchanged.
Channel advancement is independent by product so a Snowfield-specific failure
does not delay Cayo or Snow.

Both aliases move by copying an already published manifest digest. Promotion
must never rebuild or re-sign payload bytes. Installed systems and release
records must expose the immutable digest behind the alias.

## Definition of stable

`stable` means **the recommended, rollback-capable production bootc digest for
one product**, supported until a successor has itself passed the same gates.
It does not mean bug-free, permanently supported, or a separate build.

A stable digest has:

- passed installation, update, rollback, persistence, signature, and artifact
  checks on the exact bytes being promoted;
- completed the observation period without a release-blocking regression;
- met the product's hardware evidence requirement;
- retained its predecessor digest for rollback and incident response; and
- produced an auditable promotion record linking source commit, immutable tag,
  digest, tests, signatures, SBOM, provenance, approver, and timestamp.

The stable alias is product-specific. Partial fleet promotion is allowed, but
the installer and documentation must show the channel of each selected product
and must not silently fall back from `stable` to `latest`.

## Promotion criteria

### Immutable build to `latest`

The daily pipeline may advance `latest` only when all of the following pass for
that product:

1. The source is the protected default branch and the daily workflow is not a
   pull-request or feature-branch dispatch.
2. Build, publication guard, package policy, and secure artifact validation
   pass.
3. The immutable GHCR digest is Cosign-signed and independently pulled back and
   verified by digest and containers policy.
4. Signed SBOM and build provenance referrers are present and discoverable.
5. A clean install reaches the expected target with no failed units.
6. A boot smoke test completes for the product.
7. No open P0 security incident or P0 product regression is associated with
   the source commit or digest.

The pipeline records a machine-readable candidate receipt before atomically
moving `latest`. Missing evidence fails closed and leaves the existing alias in
place.

### `latest` digest to `stable`

A digest is eligible for stable promotion only when all daily gates passed and:

1. **Exact-digest update proof:** update from the current stable digest,
   reboot into the candidate, and verify the full `/etc` and `/var`
   persistence matrix.
2. **Rollback proof:** roll back to the current stable digest, retain `/var`,
   then return to the candidate without corrupting deployment state.
3. **Security proof:** verify signature policy rejection, Secure Boot chain,
   sealed command line, TPM enrollment/unlock, encrypted persistent storage,
   recovery credential use, and key-rotation compatibility on the exact
   candidate.
4. **Observation window:** wait at least 72 hours after publication with three
   consecutive green daily compliance runs. A newer `latest` does not reset
   the candidate's window.
5. **Hardware evidence:** Cayo and Snow pass on representative x86-64 hardware;
   Snowfield additionally passes on supported Surface hardware. QEMU-only
   evidence cannot promote Snowfield.
6. **Release health:** no unresolved P0 or P1 release blocker, known
   exploitable critical vulnerability, data-loss report, update failure, or
   installer/recovery regression affects the candidate.
7. **Independent approval:** a maintainer other than the build initiator
   approves the promotion receipt in the protected `stable-promotion`
   environment.

An emergency security promotion may shorten only the 72-hour observation
window. It still requires exact-digest install, update, rollback, security, and
signature evidence plus explicit two-maintainer approval. The promotion record
must identify the waived duration and incident.

If post-promotion evidence reveals a blocker, restore `stable` to the retained
predecessor digest, publish an incident notice, and keep the rejected immutable
digest for forensics. Never delete or overwrite it to disguise the rollback.

## Promotion pipeline

Use one reusable, product-parameterized workflow with four trust-separated
stages:

1. **Build:** publish immutable timestamp tag; sign digest; attach signed SBOM
   and provenance.
2. **Daily verification:** pull from GHCR, verify the served digest, install,
   boot, and emit a signed candidate receipt.
3. **Daily promotion:** verify the receipt in a protected environment and move
   `latest` to that digest.
4. **Stable qualification and promotion:** run the exact-digest update,
   rollback, security, observation, hardware, and blocker checks; require
   approval; move `stable`; publish a signed promotion receipt and GitHub
   release note.

Receipts should be OCI referrers or signed JSON artifacts with a documented
schema. Every gate consumes immutable digest references, never a moving alias.
The workflow must serialize promotions per product and re-read the destination
alias after mutation to prove that the registry serves the intended digest.

## Migration phases

### Phase 0: Measure and freeze scope

- Inventory active native A/B installations by opt-in, privacy-preserving
  update telemetry or a documented operator survey.
- Record current build minutes, runner dependencies, secret/key inventory,
  storage cost, failure rate, and maintainer effort for both formats.
- Freeze new native-only features. Continue security, data-loss, update, and
  recovery fixes.

**Exit:** baseline metrics and named owners for bootc security parity, channels,
installer, migration, and native retirement.

### Phase 1: Introduce bootc channels

- Preserve immutable timestamp tags.
- Change `latest` to one qualifying daily advancement per product.
- Add `stable` without changing installer defaults.
- Publish channel semantics, receipts, current digest, source, and promotion
  history.

**Exit:** 30 days of reliable daily promotion with no alias/digest mismatch and
at least two successful stable promotions for each product.

### Phase 2: Close security and recovery parity

- Complete the separately gated secure bootc installer and hardware evidence.
- Prove Secure Boot, MOK enrollment/restaging, TPM unlock, encrypted persistent
  storage, recovery without network access, key rotation, update, rollback,
  and failed-update recovery.
- Compare the results against the native A/B contract and record every accepted
  difference in an ADR.

**Exit:** all stable security gates pass on exact bootc digests for Cayo, Snow,
and Snowfield; documentation no longer describes the selected secure bootc
path as unsupported.

### Phase 3: Pilot and change new-install defaults

- Pilot Cayo first, then Snow, then Snowfield.
- Run each product on `stable` for at least 30 days and through two promoted
  updates, including one rollback and one recovery rehearsal.
- Change installer defaults to bootc `stable` only for the product whose pilot
  passed. Keep explicit native A/B selection during overlap.

**Exit:** all three products default to bootc `stable`; installer selection,
signature verification, digest pinning, and recovery instructions have passed
fresh-install testing.

### Phase 4: Migrate native A/B users

Native A/B and bootc use incompatible disk layouts, so migration is a
backup-and-reinstall operation rather than an in-place conversion.

- Publish a supported-data inventory and backup/restore tool or checklist for
  users, homes, containers, Flatpaks, sysext selection, network configuration,
  host identity, encryption recovery material, and deliberate `/etc` changes.
- Rehearse the process on Cayo, Snow, and Snowfield, including rollback to the
  pre-migration disk backup.
- Announce a retirement window of at least 90 days and two bootc stable
  promotion cycles after the final product changes default.

**Exit:** one successful migration rehearsal per product, no open migration
data-loss blocker, and the announced overlap has elapsed.

### Phase 5: Retire native A/B publication

- Stop moving native A/B update indexes and remove native A/B from fresh-install
  selection.
- Retain final signed metadata, verification keys, immutable artifacts,
  recovery documentation, and source for the announced retention period.
- Revoke publication credentials only after confirming they are not shared
  with bootc or sysext delivery.
- Remove native build and promotion capacity in a separate implementation plan.

**Exit:** retirement notice and archive are independently recoverable; on-call
and security documentation identify the final supported native version and
response boundary.

## Go/no-go decision

Retire native A/B only when every product has:

- two consecutive stable bootc promotions;
- 30 days of production-representative hardware operation;
- exact-digest install, update, rollback, security, and recovery evidence;
- a default installer path pinned to `stable`;
- a rehearsed native-to-bootc migration;
- no open P0/P1 migration or security-parity blocker; and
- completed the announced overlap window.

Any failed gate pauses only the affected product. Native A/B publication
continues for that product until the blocker is resolved or maintainers make a
separately documented decision to retain it.

## Success measures

- 100% of new recommended installs resolve through a recorded `stable` digest.
- 100% of `latest` and `stable` movements have a signed promotion receipt.
- Zero stable promotions rebuild candidate bytes.
- Stable promotion rollback can restore the predecessor alias within one hour.
- Native and bootc OS publication pipelines fall from two to one after
  retirement, with no loss of security or recovery evidence.
- Release documentation clearly identifies immutable, daily, and stable
  references for every product.

## Immediate roadmap

1. Approve the channel contract and promotion-receipt schema.
2. Implement daily `latest` without changing current installer defaults.
3. Pilot `stable` on Cayo while the secure bootc parity work remains gated.
4. Build the parity evidence matrix from the native A/B contracts and bootc
   secure operations runbook.
5. Revisit the retirement decision only after Phase 2, not on a calendar date.
