# pvl Podman Compose systemd quoting fix

## Context

- User reported all `services.podmanCompose` generated user units failed with:
  - `Loaded: bad-setting`
  - `Unbalanced quoting` on `ExecStartPre` in
    `/etc/systemd/user/<service>.service`.

## Root cause

- `ExecStartPre` and `ExecStopPost` were generated as:
  - `bash -eu -c ${escapeShellArg <multiline script body>}`
- The escaped argument contained literal newlines, which made the rendered unit
  line parse as unbalanced quoting in systemd.
- There was also an extra stray single quote on the `printf` line in
  `linkCmdsBody` that worsened quoting behavior.

## Change

- File updated: `lib/podman.nix`
- Removed the stray trailing single quote in the
  `printf '%s\\n' ... >> "$tmp_manifest"` command generated inside
  `linkCmdsBody`.
- Replaced inline `bash -c '<multiline>'` unit fields with generated store
  scripts:
  - `linkScript = pkgs.writeShellScript ...`
  - `cleanupScript = pkgs.writeShellScript ...`
  - `ExecStartPre = "${linkScript}"`
  - `ExecStopPost = "${cleanupScript}"`

## Verification

- Ran:
  - `nix eval --raw .#nixosConfigurations.pvl-x2.config.systemd.user.services.pvl-docmost.serviceConfig.ExecStartPre`
  - `nix eval --raw .#nixosConfigurations.pvl-x2.config.systemd.user.services.pvl-docmost.serviceConfig.ExecStopPost`
- Result now returns direct script paths in `/nix/store/...` (no multiline
  quoted shell payload in unit fields).

## Expected outcome

- Generated `systemd --user` units for `services.podmanCompose` should load
  normally (no `bad-setting` from unbalanced quoting).

## Follow-up (2026-02-27)

- After quoting fixes, services could still fail with `status=200/CHDIR` on
  first start.
- Cause: `serviceConfig.WorkingDirectory` is applied before `ExecStartPre`, so
  if the compose directory does not exist yet, systemd fails before pre-start
  scripts can create it.
- Fix: changed working directory to an optional one using systemd syntax:
  - `WorkingDirectory = "-${resolvedWorkingDir}";`
- This allows first-run pre-start scripts to create the directory, while
  subsequent starts still run in the intended directory.

## Follow-up (tmpfiles)

- Added stack-level tmpfiles provisioning in `lib/podman.nix`:
  - `systemd.tmpfiles.rules = [ "d ${stack.workingDir} 0750 ${stack.user} ${stack.user} -" ]`
- This ensures root creates stack roots like `/var/lib/podman-pvl` during
  activation, which user services cannot create themselves under `/var/lib`.
