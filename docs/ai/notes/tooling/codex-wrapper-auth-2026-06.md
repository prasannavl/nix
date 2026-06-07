# Codex Wrapper Auth Slots

The local `codex-wrapper` package installs `cr` and `cra` while leaving the
upstream `codex` command available.

Supported local shortcuts:

- `cr -u ...` expands to upstream
  `--dangerously-bypass-approvals-and-sandbox`.
- `cra ...` is equivalent to `cr -u ...`.
- `cr ...` or `cra ...` without auth-slot flags leaves `$CODEX_HOME/auth.json`
  untouched and uses Codex's normal credentials.
- `cr -x0 ...`, `cr -x1 ...`, `cr -xx0 ...`, etc. run Codex under a private
  `bubblewrap` mount namespace with a temporary `$CODEX_HOME`. The wrapper
  bind-mounts the selected `auth.<num>.json` as that namespace's `auth.json`
  and bind-mounts the other existing Codex-home entries around it. Codex token
  refreshes and login writes therefore persist to the numbered slot while the
  host's regular `auth.json` stays unchanged.
- `cr --switch 1` permanently swaps `$CODEX_HOME/auth.json` with
  `auth.1.json`, recording the active slot in `auth.current`. If only
  `auth.json` exists and no numbered slot files are present, that current
  `auth.json` is treated as slot `0`.

If a requested numbered slot file does not exist, the wrapper creates it as an
empty file before use. The permanent `--switch` path uses same-directory,
no-clobber renames and refuses to overwrite existing numbered
`auth.<num>.json` files.
