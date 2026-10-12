# Agent git commit signing and push transport

Recorded 2026-09-22 while publishing the AI policy contract consolidation to
`master` in both the Abird and Pvl repositories.

## Signed commits need the agent SSH socket

Both repositories set `commit.gpgsign=true` with `gpg.format=ssh` and an SSH
signing key. Agent shells can start without `SSH_AUTH_SOCK`, so `git commit`
fails with:

```text
error: Couldn't get agent socket?
fatal: failed to write commit object
```

The signing key lives in the user's gcr-ssh-agent socket. Export it for commit
and push commands:

```bash
export SSH_AUTH_SOCK=/run/user/1000/gcr/.ssh
```

Confirm the key is loaded with `ssh-add -L` before committing. A failed signed
commit leaves the index intact, so re-run `git commit` after exporting the
variable; do not re-stage or reset. Verify a real signature with
`git cat-file -p HEAD | grep ^gpgsig`.

## A long pre-push lint can outlive the GitHub SSH connection

`.githooks/pre-push` refuses dirty worktrees and runs a full local
`nix ... lint` before sending refs. That can take minutes, during which GitHub
may close the idle SSH connection
(`Connection to github.com closed by remote
host.`), aborting the push even
though lint passed. Set SSH keepalives and retry:

```bash
export GIT_SSH_COMMAND="ssh -o ServerAliveInterval=20 -o ServerAliveCountMax=100000"
```

The retry is fast because the lint store paths are already built. Always check
`git ls-remote origin refs/heads/master` after a push; a dropped connection is
not proof of success or failure.

## Pre-push tests fail under the lint wrapper's nested TMPDIR

`.githooks/pre-push` runs validation through `scripts/lint.sh`, whose
`run_manifest_command` exports a fresh `mktemp -d` as `TMPDIR` when the caller
has none. Package test checks then run `cargo test` on the host with that nested
`TMPDIR`, so `tempfile` paths gain a doubled prefix
(`/tmp/tmp.XXXXXXXXXX/.tmpYYYYYY/...`). `abird-host-manager` asserts an SSH
control path shorter than OpenSSH's 108-byte limit, and the extra prefix pushes
several `fleet_native_runtime` tests over it. The hook then fails at
`flake-check` with control-path-length errors plus dependent "No such file or
directory" panics from tests whose fake `ssh` never ran.

These failures are environmental, not regressions. Export a short `TMPDIR` so
the wrapper reuses it instead of nesting:

```bash
TMPDIR=/tmp git push origin master
```

A manual `nix run .#lint` from a shell without `TMPDIR` hits the same trap; set
`TMPDIR=/tmp` there too. Confirm one sub-project in isolation with
`nix run .#lint -- --project abird-host-manager`. Pvl's `fleet_native_runtime`
anchors its own temp roots under the short `/tmp/nb-*` prefix (see
[stale cargo target GC](./nixos-stale-cargo-target-gc-2026-09.md)), which raises
the nesting budget, but the wrapper export remains the deterministic path.

## Linked-worktree pushes leaked GIT_DIR into pre-push lint

Git exports the repository environment into hooks only when the push runs from a
linked worktree: `GIT_DIR` points at that worktree's git directory, while a push
from the main worktree exports none. Verified 2026-09-27 with a probe hook: a
push from a `git worktree add --detach` checkout exports
`GIT_DIR=<main>/.git/worktrees/<name>`, whereas a main-worktree push exports
only `GIT_EXEC_PATH` and `GIT_PREFIX`. The "push from a clean sibling worktree"
recipe below is therefore exactly the case that leaked.

Lint executes project tooling that creates its own temporary repositories, so an
inherited `GIT_DIR` redirected those commands into the pushing checkout.
`abird-host-manager`'s
`tests::cleanup_recovery_requires_the_exact_adoption_successor`
(`pkgs/tools/abird-host-manager/src/main.rs`) shelled out to raw `git` without
clearing the repository environment, unlike production code's
`clear_git_repository_environment`. Under the hook its `git init` and
`git config user.*` wrote through to the real repository: `core.bare = true`,
`user.name = Closeout Test`, `user.email = closeout@example.invalid` and
`commit.gpgsign = false` in the shared `.git/config`, after which `git status`
failed with `fatal: this operation must be run in a work tree`. It also left
throwaway `base`/`adoption`/`cleanup` commits on the disposable worktree's
detached HEAD.

`.githooks/pre-push` now runs lint through `run_diff_lint`, which strips the
repository environment (`GIT_DIR`, `GIT_WORK_TREE`, `GIT_COMMON_DIR`,
`GIT_INDEX_FILE` and the rest of `GIT_REPOSITORY_ENVIRONMENT` from
`pkgs/tools/abird-host-manager/src/programs/mod.rs`) before invoking
`nix run .#lint`. Both the linked-worktree and main-worktree paths then hand
lint the environment a plain shell would have. The fleet test helpers clear the
same selectors through `git_command()`, so a leaked `GIT_DIR` cannot write
through even when the hook is bypassed or an older hook revision is checked out.

If a push still corrupts the tree, repair the shared config and confirm it:

```bash
git config --local core.bare false
git config --local --remove-section user
git config --local --remove-section commit
git config --local --get-regexp '^(core\.|user\.|commit\.)'
```

Expect `core.bare false`, no local `[user]` or `[commit]` section, and identity
plus signing resolved from the global config. Junk commits live only on the
disposable worktree HEAD, so remove that worktree instead of pushing from it.

## Publishing while main holds unrelated uncommitted work

The pre-push clean-worktree check only inspects the worktree that invokes the
push. When `master` must keep unrelated uncommitted documentation for review,
commit and fast-forward the reviewed series in the main worktree, then push
`master` from the clean sibling worktree instead of stashing the main worktree.
That linked worktree is also the environment that used to leak `GIT_DIR` into
lint; `.githooks/pre-push` scrubs it now, so no extra environment step is
needed. Preserve any overlapping file with the three-way `git merge-file` recipe
in `git-worktree-stash-sync-2026-09.md`; do not use the shared stash list.
