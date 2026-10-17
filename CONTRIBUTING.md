# Contributing to Nix

Welcome — we're building Nix in the open and would love to build it with you.
This guide covers the best ways to contribute, the development and lint
workflow, how work is planned, and the engineering principles we hold to. For
how we use AI, see the AI disclosure in the [README](README.md#ai-disclosure).

## Best ways to contribute

- **Design and architecture.** Open an issue describing the problem,
  alternatives, correctness constraints, and expected impact. For nontrivial
  work, propose a plan under `.agents/plans/` (see
  [How work is planned](#how-work-is-planned)).
- **Contained implementation.** Send a focused PR with source references, tests,
  and measured results where applicable, working from the plan checklist.
- **Research and verification.** Contribute reproducible analysis, failing
  cases, counterexamples, or simpler architectural options. Keep reproduced
  evidence separate from hypotheses.
- **Documentation fixes.** Small PRs are welcome; a typo or broken link needs no
  plan.

## Development and linting

```sh
./scripts/git-install-hooks.sh   # once, before pushing upstream
nix fmt                          # format the repo
nix run .#lint                   # standard lint and check flow
nix run .#lint -- fix            # apply safe auto-fixes, then re-run lint
```

The Git hook is intentionally on `pre-push`, not `pre-commit`: commit-time
iteration stays fast, and the full lint flow does not run on every local commit.
The `pre-push` hook is diff-based — it computes the push base and only runs the
root diff checks and package checks for what changed, using the same
`nix run .#lint -- --diff --base <base>` flow that CI and manual local usage
rely on.

Full lint workflow details and package-level commands live in
[`docs/linting.md`](docs/linting.md).

## How work is planned

Read [.agents/plans/TODO-SPEC.md](.agents/plans/TODO-SPEC.md) for the shared
checklist vocabulary and [.agents/plans/README.md](.agents/plans/README.md) for
the full planning model — the queue, work capsules, append-only events, and the
done/archive lifecycle.

## Engineering principles

Keep the monorepo small-module and nix-native: each package owns its own flake
and is aggregated into the top-level outputs, never break pinned flake outputs,
and prefer composing existing modules over new infrastructure.

Prefer minimal, composable changes over new infrastructure, and never label
planned support as implemented or unverified results as equivalent. Run
`nix fmt` and `nix run .#lint` before committing and keep them green.

## AI-assisted contributions

Implementations are AI-assisted by default, so they need no special marking.
Plans record their authorship instead:

- **Human-led:** `Author: Prasanna Loganathar` and
  `Co-authors: GPT-6.1-Sol, GPT-6-Astra, DeepSeek v4.1 Flash`.
- **AI-led:** `Author: GPT-6.1-Sol, GPT-6-Astra, DeepSeek v4.1 Flash`.

Reviewers — human and AI — can then see at a glance how a plan was produced and
weigh its design accordingly.

See the README's [AI disclosure](README.md#ai-disclosure) for how the project
itself is built.

Thank you for helping make Nix better.
