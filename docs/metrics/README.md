# Snosi Delivery Metrics

This document defines the metrics snosi tracks about its own change-delivery
process, and — for each one — exactly how to collect it from data GitHub
already stores. It is the feedback-loop counterpart to the correctness gates
in `.github/workflows/validate.yml`: those gates say whether a change is
*safe*, these metrics say whether the way changes are proposed and reviewed is
actually *working*.

The primary metric is **PR acceptance rate**, because most changes to this
repository — human and agent alike — arrive as pull requests, and an accepted
PR is the only signal that a proposed change was judged correct, in scope, and
adequately validated.

Everything here is collected on demand with `gh` and `jq`. There is no
scheduled collector job, no stored time series, and no dashboard: snosi's
change volume is low enough that an on-demand query answers the question
honestly, and a stale committed metrics file would be worse than none. Treat
the queries below as the definition; treat any number you paste elsewhere as a
snapshot with a date attached.

## Prerequisites

```bash
gh auth status          # authenticated GitHub CLI
jq --version            # jq 1.7 or newer
```

All queries below are read-only and safe to run against the live repository.

## 1. PR acceptance rate

**Definition.** Of the pull requests *closed* in a window, the fraction that
were merged:

```text
acceptance rate = merged PRs / (merged PRs + closed-unmerged PRs)
```

Open PRs are excluded — they have no outcome yet. Closing a PR because it was
superseded, split, or folded into another PR counts as unmerged; that is
deliberate, because from a feedback-loop perspective the work still had to be
redone.

**Collection.** For the last 50 closed PRs:

```bash
gh pr list --repo frostyard/snosi --state closed --limit 50 \
  --json number,title,author,mergedAt,closedAt \
| jq '{
    merged:   [ .[] | select(.mergedAt != null) ] | length,
    unmerged: [ .[] | select(.mergedAt == null) ] | length
  } | . + { acceptance_rate: (.merged / (.merged + .unmerged)) }'
```

**Split by author type.** The number that matters most is whether
agent-authored PRs are accepted at a rate comparable to human-authored ones; a
widening gap means the agent guidance in `AGENTS.md` / `CLAUDE.md` is drifting
from what reviewers actually want:

```bash
gh pr list --repo frostyard/snosi --state closed --limit 100 \
  --json author,mergedAt \
| jq 'group_by(.author.login)
      | map({
          author: .[0].author.login,
          merged:   ([ .[] | select(.mergedAt != null) ] | length),
          unmerged: ([ .[] | select(.mergedAt == null) ] | length)
        })
      | sort_by(-(.merged + .unmerged))'
```

**Interpretation.** A rate at or near 1.0 is not automatically good: it can
mean review is rubber-stamping, or that rejected work is being closed as
"draft abandoned" outside the numbers. Read it alongside metric 2 (review
iterations) — high acceptance *and* high iteration count means changes land
only after substantial rework, which is the signal to fix upstream guidance
rather than to celebrate the acceptance rate.

## 2. Review iterations to merge

How many review rounds a PR needed before it merged. This is the earliest
detectable symptom of guidance drift: a change that lands after five review
cycles was technically accepted, but the first four cycles were avoidable
cost.

```bash
gh pr list --repo frostyard/snosi --state merged --limit 30 --json number \
| jq -r '.[].number' \
| while read -r pr; do
    reviews=$(gh pr view "$pr" --repo frostyard/snosi \
      --json reviews --jq '[.reviews[] | select(.state != "COMMENTED")] | length')
    printf '%s\t%s\n' "$pr" "$reviews"
  done
```

Look at the distribution, not the mean — a long tail of high-iteration PRs is
more actionable than an average.

## 3. Time to merge

Wall-clock hours from PR creation to merge, for merged PRs:

```bash
gh pr list --repo frostyard/snosi --state merged --limit 50 \
  --json number,createdAt,mergedAt \
| jq -r '.[] | [ .number,
                 (((.mergedAt | fromdateiso8601) - (.createdAt | fromdateiso8601)) / 3600
                  | floor) ] | @tsv'
```

This is a queue-health metric, not a quality metric. It is included because a
long time-to-merge inflates the cost of every rejected PR, and therefore makes
metric 1 more expensive to be wrong about.

## 4. CI first-pass rate

The fraction of PRs whose required checks passed on the first push, without a
fixup commit. `validate.yml` is the gate that most changes hit first, so its
first-pass rate is a direct measure of how well the documented local checks
(`shellcheck`, the `test/` fixture suites) match what CI enforces:

```bash
gh run list --repo frostyard/snosi --workflow validate.yml \
  --event pull_request --limit 100 --json conclusion \
| jq 'group_by(.conclusion)
      | map({ conclusion: .[0].conclusion, count: length })'
```

A falling first-pass rate usually means a check exists in CI that has no
documented local equivalent. The fix is to document or script the local
equivalent, not to relax the check.

## What is deliberately not measured

- **Lines changed / commit counts.** Snosi changes range from a one-line
  `Packages=` addition to a multi-thousand-line secure-boot pipeline; size
  carries no comparable signal here.
- **Issue close rate.** Many issues in this repository are long-lived tracking
  or gate items (for example the pending Surface hardware validation gate),
  and closing them is a scheduling decision, not a quality one.
- **Per-author leaderboards.** The author split in metric 1 exists to detect
  guidance drift between agent and human contributions, not to rank people.

## Acting on the numbers

When a metric moves in the wrong direction, the response is a documentation or
tooling change, not a process reminder:

| Signal | Likely cause | Where to fix |
|---|---|---|
| Acceptance rate falls for agent PRs | Agent guidance is stale or incomplete | `AGENTS.md`, `CLAUDE.md`, `yeti/` |
| Review iterations rise | Expectations are implicit, not written down | `.github/pull_request_template.md`, `docs/` |
| CI first-pass rate falls | A CI check has no documented local equivalent | `README.md` build/test sections, `test/` |
| The same correction recurs across PRs | A belief keeps being re-learned from scratch | Append to `.memory/corrections.jsonl`, then promote |

The last row is the one that closes the loop: `.memory/corrections.jsonl` is
the append-only record of beliefs that turned out to be wrong, and promoting a
recurring correction into `CLAUDE.md` or `yeti/` is what stops it from costing
a review cycle again.
