# AGENTS.md

<!-- BEGIN common -->

## Shared conventions

These are byte-identical across all abird repositories. Repo-specific rules
follow the markers below.

- **Source of truth.** Live source, tests and executed results outrank dated
  prose. Start at `.agents/plans/README.md` (overview + spec), then work from
  `.agents/plans/TODO.md` (the queue).
- **XDG paths.** Where the project owns user config, data, cache or state,
  resolve it under `$XDG_*_HOME/abird/<project>` — an absolute XDG base, falling
  back to `HOME` when unset. No legacy or alternate root.
- **Shared `.gitignore`.** The block at the top of `.gitignore` is identical
  across repos; repo-specific entries follow it. Keep it mechanical.
- **Preserve other work.** Never revert or overwrite changes you did not make.
  Stage explicit paths, not broad globs, and leave other agents' staged or
  uncommitted work untouched.
- **Terse writing.** Keep code comments and docs succinct. Comments need not be
  full sentences; prefer symbols and fragments unless the user asked for an
  explanation or the topic is design-level or otherwise complex. Prefer bullets
  and engineering focus over prose in other docs.
- **Git safety.** Commits are signed; never disable signing. Never push,
  force-push, tag, publish, deploy, or run destructive operations — history
  rewrite, `reset --hard`, branch deletion, or touching another agent's staged
  or uncommitted work — without explicit user confirmation for each action. A
  request to "commit" or "apply" is not authorization to push.

<!-- END common -->

<!-- BEGIN monorepo -->

## Plans and parallel work

- Durable plan: `.agents/plans/<plan-id>.md`. Priority: the
  `.agents/plans/queue/p<priority>-<plan-id>.md` symlink (P2 normal; P0 needs
  explicit human promotion and a named incident coordinator). Live state:
  `.agents/plans/work/<plan-id>/README.md` with append-only `events/` as the
  authoritative record. Closeout moves to `.agents/plans/archive/` and
  `.agents/plans/done/`, removes the queue symlink and keeps the raw events.
- Plan IDs use `<creation-year>-w<creation-iso-week>-<kebab-name>` and stay
  stable across queue moves, work, closeout, archival and reopening.
- Start at `.agents/plans/README.md` (overview + spec) and work from
  `.agents/plans/TODO.md` (the queue).
- **Docs.** Before loading context, list `.agents/docs/` 2-3 levels deep as
  needed and read the relevant subtree; there is no docs index file to maintain.
- Scan `.agents/docs/lang-patterns/<language>.md` before editing a language, and
  `.agents/docs/design-patterns/` for architecture rules.
- Record reusable, user-approved processes in `.agents/docs/playbooks/` and
  task-specific memory in `.agents/docs/notes/`; keep notes scoped to one task.
- Treat `.agents/docs` updates as a closeout gate for non-trivial work.
- Use `.agents/runs/<session>/` for temporary parallel work (and
  `.agents/runs/locks` for cross-agent locks); use `worktrees/<session>` for
  multi-file edits; clean up on success.
- Keep temporary files in `tmp/` at the repo root and clean them up, or ask
  before keeping them for debugging.

## Safety

- This monorepo requires an explicit instruction before any commit or push, not
  only before destructive operations.
- Do not use `path:` flake refs for validation or builds. From the repo root use
  `.`; from outside use the absolute repo path; for committed snapshots use
  `git+file://`.
- Never read `data/secrets/**/*.key` (or equivalent). You may list filenames,
  but never read their contents, directly or indirectly.
- Do not commit `.terraform/`, `*.tfstate` or `*.tfstate.*`.

## Gates

`nix fmt` and `nix run .#lint`; the `pre-push` hook runs the diff-based lint,
and `nix flake check` runs the full reproducible build and lint.

<!-- END monorepo -->

<!-- BEGIN repo-specific -->

## Repository

Open-source (MIT); the `nix` lineage.

<!-- END repo-specific -->
