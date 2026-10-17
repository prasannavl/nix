# TODO spec — shared checklist vocabulary

The full planning model lives in [`.agents/plans/README.md`](README.md) — the
queue, work capsules, append-only events, and the done/archive lifecycle. This
file fixes only the shared vocabulary every plan uses, so agents and
contributors read the same names across repositories.

## Authorship

Open the canonical plan `.agents/plans/<plan-id>.md` (and its work capsule
`README.md`) with the plan's authorship:

- **Human-led:** `Author: <user>` and
  `Co-authors: <comma-separated AI models used>`.
- **AI-led:** `Author: <the AI models only>`.

## Plan details

The plan states what it is and why it exists, plus, as needed, **Design**,
**Decisions**, and **References** sections. Keep them in one file while it stays
readable; split a section into `DESIGN.md`, `DECISIONS.md`, or `REFERENCES.md`
beside the plan when it grows large, and link back.

## Status

Plan and work-capsule status is commit-grouped: completed work under the commit
that landed it, open work under `## Uncommitted`. This maps onto the queue/work
states described in `.agents/plans/README.md`.

## Tests and verification

Every plan lists every test and gate under a `## Tests and verification` section,
each with the command or evidence that proves it. A plan is not done while any of
these is open; all must be `[x]` on the closing commit. This maps onto the
work-capsule validation area.
