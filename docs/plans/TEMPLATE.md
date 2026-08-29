# Plan: Name (e.g. "Roadmap", "Migration to X")

**Status:** Proposed  
**Last verified:** YYYY-MM-DD

<!--
Plans are updated as work lands: check off what shipped, renumber what moved.
Every phase MUST have a "Done when" — a demonstrable outcome, not an activity.

Every file in docs/plans/ MUST carry a `**Status:**` line immediately after the
H1, using exactly one of these words, optionally followed by " — " and a short
justification naming the paths that prove it:

  Proposed     Written up, not agreed to schedule it.
  Planned      Agreed and scheduled; implementation has not started.
  In progress  Some phases have landed; others are still open.
  Shipped      Every phase landed. Say where the code lives.
  Superseded   Replaced by another doc. Link it.
  Abandoned    Deliberately dropped. Say why.

`**Last verified:**` is the date a human or agent last checked the status
against the tree. A plan whose status has not been re-verified in a long time
is a signal, not a fact.
-->

One paragraph: what this plan delivers and its relationship to other plans.

## Phase 1 — Name (size estimate)

- Work item, linking the [spec](../specs/….md) or [design doc](../design/….md)
  it implements.
- Work item.
- **Done when:** a single observable outcome ("`hello.example.com` renders the
  visitor's login name").

## Phase 2 — Name

- …
- **Done when:** …

## Later / ideas

Unscheduled candidates. Move items up into a phase rather than letting this
section become a second backlog.

## Open questions

- **Question:** what decides it, and by when (usually "by Phase N"). When one
  is resolved, record the answer as an [ADR](../adr/TEMPLATE.md) if it changed
  the architecture, then delete it here.

## References

<!-- Required. Link the design docs and specs this plan implements. -->

- Implements: [design/…](../design/….md), [specs/…](../specs/….md)
