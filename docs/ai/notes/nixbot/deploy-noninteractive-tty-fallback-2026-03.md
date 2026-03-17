# Nixbot Deploy Non-Interactive TTY Fallback (2026-03-11)

## Context

- Deploys that inject the host machine age identity use
  `ssh -tt ... <"${SSH_TTY_STDIN_PATH}"` so interactive runs can satisfy a
  remote `sudo` prompt when needed.
- In non-interactive contexts (for example the installed `nixbot`
  service/wrapper on the bastion host), `/dev/tty` may exist in the filesystem
  but still be unusable because the process has no controlling terminal.

## Issue

- `scripts/nixbot-deploy.sh` selected `/dev/tty` by probing it directly from the
  shell helper.
- In Bash, the `/dev/tty` open for a redirection happens before `2>/dev/null`
  can suppress the failure, so a non-interactive run still emits
  `/dev/tty: No such device or address` and aborts deploy during host age
  identity injection before activation starts.

## Decision

- Resolve the stdin source for `ssh -tt` at the point of use, not once during
  script initialization.
- The helper must not open `/dev/tty` during the probe.
- Treat the presence of any attached standard stream
  (`[ -t 0 ] || [ -t 1 ] ||
  [ -t 2 ]`) as the signal to use `/dev/tty`;
  otherwise fall back to `/dev/null`.

## Result

- Interactive runs still use the caller's terminal for `ssh -tt`.
- Non-interactive runs, including bastion-triggered deploy work that executes
  inside subshells, no longer fail on the redirection itself and continue with
  the existing non-interactive behavior.
