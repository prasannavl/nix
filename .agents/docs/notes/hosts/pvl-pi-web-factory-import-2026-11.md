# Pvl Pi Web factory import regression

## Failure

- Source: `7d66306223690cf8ee87ea4b4cb72266e301bde9`.
- Retained diagnostics:
  `/var/tmp/nixbot/diag-1b25159118394271ab134de2bed20552/commands/`.
- `pvl-a1` and `pvl-l5` failed build-plan evaluation with
  `function 'anonymous lambda' called with unexpected argument 'system'` at
  `ab/services/pi-web/nixos.nix`.
- Migration relocated the host imports but missed the new factory contract.
  NixOS supplied module arguments to a function accepting only `defaultPackage`
  and `defaultUser`; the previous repository-specific defaults were also absent.
- The other five retained build-plan status files report `ok`. System builds and
  deployment had not started.

## Correction

- Both host wrappers construct `ab.services.piWeb.nixos` explicitly.
- Inject the existing `nix/ext/pi/pi-web` package and `pvl` user as defaults,
  preserving normal NixOS option overrides.
- Keep MCP disabled, tailnet exposure on port 30141, hostname allowlists and
  service PATH behavior unchanged. No shared `ab/` change.

## Verification

- Canonical `pvl-a1` toplevel derivation evaluation reproduced the failure.
- New `pvl-pi-web` check imports both real host wrappers into small NixOS
  fixtures; checks package/user defaults and overrides, ExecStart, home, PATH,
  MCP policy, allowed hosts and the tailnet firewall rule.
- Regression failed before the caller fix; `pvl-pi-web` and shared `lib-pi-web`
  passed afterward. Four changed Nix files passed formatting, parsing, Statix
  and strict Deadnix.
- Full `pvl-a1` and `pvl-l5` toplevel derivation evaluations passed sequentially
  in the isolated fix worktree. Both select Pi Web 0.17.0 as `pvl`, with MCP
  disabled and their existing tailnet allowlists.
- Earlier convergence coverage evaluated `pvl-x2`, which lacks these wrappers;
  shared Pi Web tests correctly constructed the factory and missed this
  repository integration error.
- No fleet operation, NixOS system build, deployment or VM run. The fix must
  enter a commit before the default committed-source deployment uses it.
