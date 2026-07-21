# A Snosi Update/Sysext API Daemon — The Daemon Question

Date: 2026-07-20
Status: Proposed (design only; not scheduled)
Related: `docs/integration-contracts.md` (the contract map this design reasons from)

## Problem

`docs/integration-contracts.md` maps every integration point between the
Frostyard tools that ship in (or produce) snosi images. Reading it holistically
raises an architectural question:

> Would it make sense to have a snosi-level API daemon that handles all of
> this, making updex, pilothouse, chairlift & friends all clients of a daemon
> that delivers known schemas?

This document answers that question. The short version: **yes for one narrow
domain, no for "all of this."** The map shows the fragility clusters in a
single place, and a schema-owning daemon there pays off; extending it to
"everything becomes a client" fights the grain of tools that are already
domain authorities.

## What the contract map actually shows

Three facts from the map drive the decision.

### 1. Fragility clusters; it is not evenly spread

Almost every 🔴/🟡 rating in the map lives in one domain: *"what
updates/sysexts exist, what is their state, and stage/enable/disable them."*
Concretely:

- `updex features check/update --json` returning `null` vs `[]` (§3.1).
- pilothouse re-emitting `updates:null` over its broker (§3.2).
- `snosi-firstboot` parsing `updex features list` as a **text table** (§4.3).
- `systemd-sysupdate` `check-new`/`pending` stdout/exit quirks (§4.5).
- `/run/snosi/update-check` / `update-staged` `key=value` files with the
  unenforced `digest=`/`version=` invariant (§5.1, §5.2).

The 🟢 boundaries — `bootc status` JSON, `core.json`, `features.json`,
`snosi-install`'s GUI JSON, the APT/sysext repo layout — are already fine. A
daemon adds nothing to them.

### 2. The real problem is multiple transports, not the absence of a daemon

updex has **three** client transports today, and they disagree on empty-value
semantics:

| Consumer | Transport | Outcome |
|---|---|---|
| chairlift | in-process Go SDK | type-safe, immune (🟢) |
| pilothouse | subprocess emitting `--json` | hit the `null` bug (🔴→🟡) |
| snosi-firstboot | subprocess emitting a **text table** | most fragile (🔴) |

The pilothouse bug did not happen because there is no daemon. It happened
because the CLI-JSON path has different nil-slice semantics than the Go SDK
path. A daemon helps *precisely by collapsing three transports into one wire
schema* that every consumer hits identically.

### 3. updex is already the domain authority

updex already does component discovery, manifest fetching, enable/disable
drop-in writing, and `systemd-sysext refresh`. chairlift links it as a library.
A daemon must **not** be a new snosi component that reimplements this. The
correct shape is updex *gaining a daemon mode with a versioned wire API*, plus
absorbing the bootc/native/nbc update-status aggregation that currently lives
scattered across snosi shell scripts.

## Decision

Adopt the **narrow** scope. Do not adopt the broad "everything is a client"
scope.

### Do (narrow scope)

**A. Give updex an optional daemon mode + a versioned schema on a Unix
socket.** Reuse the `proto: N` versioning convention snosi already established
in `features.json` and `snosi-install --json-progress`. The CLI becomes a thin
client of the *same* schema, so the CLI-vs-SDK divergence that caused the bug
structurally cannot recur. Empty lists are `[]` in exactly one place.

**B. Fold the update-status aggregation into it.** `snosi-update-status`,
`bootc-update-stage`, `snosi-sysupdate-stage`, and the `/run/snosi/*` files
already unify bootc/native/nbc into a common vocabulary (`outcome=`,
`digest=`/`version=`). That unification is snosi-specific (bootc vs native A/B
vs nbc), and it is the one place a *snosi-authored* contribution is genuinely
warranted — exposed as schema, not as `key=value` files parsed by `sed` in five
consumers. This can live behind the same socket (updex plugin/backend) or as a
thin snosi service that composes updex's schema with transport detection.

**C. Migrate the fragile consumers; keep the good ones.**
- pilothouse already runs a broker daemon — it calls the socket instead of
  shelling out to `updex --json`.
- `snosi-firstboot` drops `awk 'NR>1'` for a schema call (or, minimally, for
  `updex --silent features list --json`, which is already `[]`-safe).
- chairlift **keeps its in-process Go SDK** (it is already 🟢/immune) or
  optionally moves to the socket — no forced change.
- The CLI stays for humans and scripts; it just shares the schema.

### Do not (broad scope — explicit non-goals)

- **A brand-new snosi daemon that proxies updex/bootc/nbc/flatpak/etc.** That
  is a second authority layer over tools that are already authorities. It
  *doubles* the schema surface (updex's contract *and* the daemon's contract)
  instead of reducing it.
- **Forcing chairlift off its type-safe Go SDK.** That is a regression from 🟢
  to 🟡 for no benefit.
- **Pulling igloo / intuneme / first-setup / repogen "under" the daemon.** The
  map confirms these have zero update/sysext coupling. "& friends" is exactly
  where this idea over-reaches.

## Why the daemon is strategic, not urgent

The bug that prompted all of this was one `make([]T, 0)` in updex
(`docs/integration-contracts.md` §8 recommendation #1). **Ship that fix now,
independent of this design.** It is the urgent answer.

A daemon is a large investment: socket lifecycle, authentication and privilege
separation (pilothouse's broker shows how much PAM/CSRF/root-broker plumbing
that is), schema versioning, and CLI backward-compatibility. It is justified
**only if** the update/sysext surface keeps gaining consumers. The map suggests
it might:

- there are already **3** updex consumers with 3 different transports;
- pilothouse's Fleet page is stubbed (mock data) — a real fleet/remote
  management surface would be a 4th consumer needing a stable wire contract;
- native A/B has **no** management GUI yet;
- chairlift and pilothouse duplicate "list features / check updates / stage"
  logic that a shared schema would collapse.

If those consumers materialize, the daemon is the right answer. If they do not,
the `make([]T, 0)` fix plus the "producers emit `[]`, consumers accept both"
convention (map §8 #3) is sufficient and a daemon would be premature.

## Recommended sequencing

1. **Now, unconditionally:** land map §8 #1 (updex `make([]T, 0)`) and #2
   (pilothouse broker output normalization). Removes the live fragility
   regardless of whether the daemon is ever built.
2. **Now, unconditionally:** adopt map §8 #3 as an ecosystem convention
   (producers `[]` never `null`; consumers accept both) and #4 (migrate
   `snosi-firstboot` off text-table parsing).
3. **When a 4th consumer appears** (fleet UI, native-A/B GUI, remote mgmt):
   design updex daemon-mode + `proto:1` socket schema (scope A), then fold in
   the update-status aggregation (scope B), then migrate pilothouse and
   `snosi-firstboot` to the socket (scope C). chairlift stays on the SDK.

## Where this work would live

- **Scope A** (daemon mode, wire schema): the `updex` repository. updex owns
  the sysext/feature domain; the daemon is an evolution of it, not a new snosi
  component.
- **Scope B** (bootc/native/nbc status aggregation): snosi, because the
  transport unification is snosi-specific. Either an updex backend contributed
  upstream or a thin snosi service composing updex's schema.
- **Scope C** (consumer migration): pilothouse and snosi respectively.

This split keeps each contract owned by the repo that is already the authority
for its domain — the same principle that makes the current 🟢 boundaries
robust.
