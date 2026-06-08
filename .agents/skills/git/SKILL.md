---
name: git
description: "Abird: Git commit/sync/push workflow for this repository. Use for $git commit, push, cherry-pick, worktree sync/rebase, dry runs, and hook-driven lint fixes."
---

# Git

## Intent Parsing

Parse the user request before touching git state.

- `commit`: create small logical commits in the current worktree unless a target
  worktree is specified.
- `commit dry`: inspect and report the proposed commit units and commit
  messages; do not stage, commit, cherry-pick, rebase, or push.
- `commit single` or `commit whole`: force all intended changes in the target
  worktree into one commit instead of splitting logical units.
- `commit push`: commit the target worktree, then push only the target
  branch/upstream that the request implies.
- `commit push main`: commit the current or target worktree, cherry-pick
  eligible commits into the main worktree, then ask before pushing main unless
  the user already expressed push intent clearly.
- `sync <target-worktree>`: refresh/rebase all relevant worktrees against the
  target worktree or target branch and adapt conflicts.
- `sync <target-worktree> dry`: report which worktrees rebase cleanly, which
  would conflict, likely conflict files, and what adaptations would be needed;
  do not rebase or modify git state.

Treat `dry`, `single`, and `whole` as modes only when they are standalone words
or options. If they appear inside an actual worktree name, keep them as part of
the name.

If no worktree is specified, use the current worktree. If a worktree is
specified, resolve it with `git worktree list --porcelain` and inspect that
worktree directly.

## Execution Efficiency

Batch independent inspection work in one round whenever possible. Prefer
parallel tool calls for read-only commands such as worktree inventory, status
checks, branch/upstream checks, diffs, file reads, hook discovery, and
target-worktree inspection. Avoid serial back-and-forth when the needed facts
can be gathered safely at the same time.

Use subagents when the task has independent, high-context branches that would
otherwise require repeated model turns or large shared context, such as:

- Inspecting many worktrees for sync readiness or conflict risk.
- Reviewing unrelated commit units in parallel before final commit grouping.
- Forward-checking a PR branch and main worktree independently before
  cherry-pick or push handling.

Give subagents narrow prompts, raw paths/refs, and explicit safety constraints.
Have them return concise findings, proposed commands, conflict files, and
validation status. Do not delegate destructive git operations, commits, pushes,
or live-system changes unless the user explicitly approved that exact operation.

## Abird Repository Rules

Default to the current repository root when the request does not name another
worktree. Consult `.agents/docs/README.md` before repo-specific work and load
only the relevant notes, design patterns, playbooks, or language pattern files
needed for the commit/sync task.

For Nix validation, never use explicit `path:` flake refs. Use `.` from the repo
root, an absolute repo path without a `path:` prefix from outside the repo, or
an intentional `git+file:///...` ref for committed snapshots. If untracked files
seem required for flake validation, stop and make the state explicit before
validating.

Never read `.key` files under `data/secrets`. You may list secret filenames when
needed for context, but tell the user before listing them and infer only from
names and surrounding non-secret files.

Keep temporary files under the repository `tmp/` directory and clean them up
after a successful run. Preserve unrelated user changes and follow this repo
AGENTS rule: do not commit, push, auto-stage broadly, run destructive git
commands, or mutate live systems unless the user request or an approved playbook
authorizes it.

## Required First Checks

Run these from the relevant repository:

```bash
git worktree list --porcelain
git status --short --branch
git branch --show-current
git rev-parse --show-toplevel
```

For pushes, also inspect:

```bash
git status --short --branch
git remote -v
git rev-parse --abbrev-ref --symbolic-full-name @{upstream}
git config --get core.hooksPath
```

If push hooks may be configured, inspect the relevant hook path or hook manager
metadata enough to know whether pre-push validation exists. Do not read secrets
while inspecting hooks.

If the target is ambiguous, ask a concise question before making git changes.

## Commit Splitting

Commit as small logical units. Base units on both file ownership and design
concerns:

- Keep shared module/library/helper code in its own commit.
- Keep per-instance, per-host, or per-stack usage/configuration in separate
  commits from shared code that enables it.
- Keep tests/docs with the change they validate or explain unless they cover
  multiple commits; then place shared tests with shared code.
- Do not combine unrelated concerns just because they are in the same worktree.
- Preserve unrelated user changes. Do not revert or overwrite changes you did
  not make.

If the user specifies `single` or `whole`, override the normal splitting rule
and make one commit containing all intended changes in the target worktree.
Still inspect the diff first, exclude unrelated user changes when possible, and
report that shared module code and per-stack usage were intentionally combined
because the user requested a single commit.

Before committing, inspect diffs with enough context to understand ownership:

```bash
git diff --stat
git diff --name-status
git diff
```

Use `git add -p` or explicit pathspecs so each commit contains only its logical
unit. If staged changes already exist, inspect `git diff --staged` and preserve
them unless the user explicitly asked to include or rearrange them.

## Commit Messages

Use the `caveman-commit` skill if it is available. If it is not available, write
concise conventional commit messages:

```text
type(scope): short subject
```

Use a body only when the reason or sequencing is not obvious. Keep the subject
under 50 characters when possible.

For dry runs, report proposed messages and file groups without staging or
committing.

## Validation

Run validation that matches the risk and local repo conventions, but avoid
duplicate lint cycles.

When the user intends to push and a pre-push hook or hook manager is configured
to run lint/test/build checks, rely on the push hook as the first validation
pass. Do not run the repository's normal lint cycle before pushing merely to
discover the same first failure. Let the hook expose the initial failure, then
inspect and fix only what it reports. Run targeted follow-up lint/test/build
commands after a hook failure when they are needed to confirm the fix or narrow
the issue.

When there is no push intent, no relevant push hook, or the change is too risky
to leave until push, prefer the repository's documented lint/test/build
entrypoints. If validation needs network, privileged access, or long-running
deployment, ask or report that it was skipped.

For dry runs, describe the validation you would run after each commit or after
the full series.

## Push and Main Handling

Never push unless the user expressed push intent or explicitly approves after
being asked.

When in the main worktree on `main` or `master`:

- `commit`: create logical commits only.
- `commit push`: create logical commits, then ask whether to push if the user's
  wording does not already clearly authorize it.

When in a non-main worktree:

- `commit`: create logical commits in that worktree only, then ask whether the
  user wants the commits cherry-picked back to the main worktree.
- `commit push`: commit and push the current or specified branch to its
  upstream. Do not replace or update main unless the user specified `main`.
- `commit push main`: commit the worktree, cherry-pick the appropriate commits
  into the main worktree, then push main only when push intent is explicit or
  approved. If main has push hooks configured, use those hooks as the first
  validation pass instead of running a duplicate lint cycle before push.

When the worktree is a PR branch/worktree:

- Ask whether to push directly to the PR branch upstream if push intent is not
  explicit.
- If push intent is explicit, push to the PR branch upstream; do not update main
  unless the user specified main.

After making all intended commits and attempting a user-approved push, treat a
pre-push hook lint failure as part of the push workflow:

- Inspect the hook output and resulting worktree diff.
- If the hook or follow-up lint command produced mechanical lint/format fixes,
  commit those fixes as the final commit in the series, then retry the push.
- Keep the lint-fix commit narrow. Do not include unrelated changes or semantic
  edits unless they are required to satisfy lint and are clearly caused by the
  committed series.
- Use `caveman-commit` if available; otherwise prefer a concise message such as
  `style: fix lint`.
- If lint reports issues but does not modify files, make the minimal required
  fixes, validate again, commit them as the final commit, then retry the push.
- If the hook exposes a real design or test failure rather than lint/format
  cleanup, stop and report the failure instead of hiding it in a lint-fix
  commit.
- In dry mode, report that lint fixes caught by pre-push would become a final
  commit before push; do not run the push or create the final commit.

## Cherry-Pick to Main

Before cherry-picking, identify the main worktree and confirm its branch:

```bash
git worktree list --porcelain
git -C <main-worktree> branch --show-current
git -C <main-worktree> status --short --branch
```

If main has local changes, inspect them and avoid overwriting them. Ask before
proceeding if cherry-pick would mix with unrelated main changes.

Cherry-pick commits in dependency order. Shared code commits should come before
per-stack usage commits. Resolve conflicts by preserving the design shape that
fits the main tree unless the worktree change is clearly the intended newer
design.

## Sync Workflow

For `sync <target-worktree>`, refresh and rebase relevant worktrees against the
target worktree or its branch.

1. Inventory worktrees with `git worktree list --porcelain`.
2. Inspect each worktree's branch, upstream, status, and diff.
3. For each dirty worktree, preserve changes with an explicit stash or
   documented temporary state before rebasing.
4. Rebase each worktree onto the target in a controlled order.
5. Resolve conflicts by inspecting both sides, the commit being replayed, and
   the target tree.
6. Make adaptations needed for the worktree to remain coherent after target
   changes.
7. Validate each adapted worktree as appropriate.

For dry sync, do not run rebases that modify state. Use merge-base, diff, and
dry-run style inspection where possible, then report expected clean/conflict
status.

The sync summary must be comprehensive:

- List every worktree inspected.
- State whether it rebased cleanly, conflicted, was skipped, or only needed
  inspection.
- List every merge conflict file and summarize how each was or would be
  resolved.
- Summarize adaptations made in each worktree.
- Summarize adaptations made for each target/main commit when relevant.
- State whether the target/main tree or the worktree design should take
  priority, based on the context. If a target change is unrelated to the
  worktree concern, prefer the target/main shape.

## Safety Rules

- Do not run destructive git commands such as `git reset --hard`, branch
  deletion, or force push unless the user explicitly requested that operation.
- Do not auto-stage broad changes when narrower pathspecs or patch staging are
  needed.
- Do not read secrets or private key files while investigating diffs.
- Keep temporary files inside the repository `tmp/` directory when the
  repository has that convention, and clean them up after successful completion.
- Ask before any operation that could lose work, overwrite user changes, or
  change a live deployment state.
