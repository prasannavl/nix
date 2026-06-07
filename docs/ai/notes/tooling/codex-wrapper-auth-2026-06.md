# Codex Wrapper Auth Slots

The local `codex-wrapper` package installs `cr` and `cra` while leaving the
upstream `codex` command available.

Supported local shortcuts:

- `cr -u ...` expands to upstream
  `--dangerously-bypass-approvals-and-sandbox`.
- `cra ...` is equivalent to `cr -u ...`.
- `cr ...` or `cra ...` without auth-slot flags leaves `$CODEX_HOME/auth.json`
  untouched and uses Codex's normal credentials.
- `cr --help` and `cr -h` print the wrapper options first, then pass the help
  request through so Codex prints its upstream help.
- `cr -x0 ...`, `cr -x1 ...`, etc. run Codex under a private
  `bubblewrap` mount namespace with the selected `auth.<num>.json` bind-mounted
  over `$CODEX_HOME/auth.json`. If `auth.json` does not exist, the wrapper
  creates an empty file first as the bind-mount target. Codex token refreshes
  and login writes therefore persist to the numbered slot while the host's
  regular `auth.json` stays unchanged.
- `cr -xswap 1` permanently swaps `$CODEX_HOME/auth.json` with
  `auth.1.json`, recording the active slot in `auth.current`. If only
  `auth.json` exists and no numbered slot files are present, that current
  `auth.json` is treated as slot `0`.

If a requested numbered slot file does not exist, the wrapper creates it as an
empty file before use. The permanent `-xswap` path uses same-directory,
no-clobber renames and refuses to overwrite existing numbered
`auth.<num>.json` files.
