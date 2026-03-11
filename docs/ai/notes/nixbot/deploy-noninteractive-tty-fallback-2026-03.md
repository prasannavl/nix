# Nixbot Deploy Non-Interactive TTY Fallback (2026-03-11)

## Context

- Deploys that inject the host machine age identity use `ssh -tt ... <"${SSH_TTY_STDIN_PATH}"` so interactive runs can satisfy a remote `sudo` prompt when needed.
- In non-interactive contexts (for example the installed `nixbot` service/wrapper on `pvl-x2`), `/dev/tty` may exist in the filesystem but still be unusable because the process has no controlling terminal.

## Issue

- `scripts/nixbot-deploy.sh` previously selected `/dev/tty` with `[ -r /dev/tty ]`.
- That check is insufficient: the later redirection can still fail with `/dev/tty: No such device or address`, aborting deploy during host age identity injection before activation starts.

## Decision

- Resolve the stdin source for `ssh -tt` at the point of use, not once during
  script initialization.
- The helper probes `/dev/tty` by actually opening it: `: </dev/tty 2>/dev/null`.
- If the open fails in the current execution context, fall back to `/dev/null`.

## Result

- Interactive runs still use the caller's terminal for `ssh -tt`.
- Non-interactive runs, including bastion-triggered deploy work that executes
  inside subshells, no longer fail on the redirection itself and continue with
  the existing non-interactive behavior.
