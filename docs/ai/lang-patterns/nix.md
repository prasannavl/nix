# Nix

## Scope

- Apply these rules when editing `*.nix` files in this repo.

## Formatting

- The repo uses `alejandra` as the Nix formatter. Do not fight it — if alejandra
  reformats your code, accept the result.
- The formatter is authoritative for indentation, spacing, and brace placement.

## `inherit` conventions

- Do **not** use simple `inherit x;` for a single binding. Write `x = x;`
  instead. This repo prefers the more explicit and developer-intuitive form for
  single bindings, so `statix` `manual_inherit` (W03) is disabled.
- `inherit (source) x;` is also optional rather than required. This repo
  disables `manual_inherit_from` (W04) because we prefer whichever form is more
  intuitive in context: use `inherit (source) ...;` when it improves
  readability, and use `x = source.x;` when that is clearer.
- When two or more adjacent bindings are all self-assignments, combine them into
  a single `inherit`:

  ```nix
  # good — multiple self-assignments grouped
  inherit apps lint packages;

  # good — single self-assignment stays explicit
  build = build;
  wrangler-deploy = deployWrangler;

  # bad — single inherit adds noise
  inherit build;
  ```

- `inherit (source) x y;` is always fine — keep using it for destructuring from
  a source expression.

## `let` bindings

- Prefer `let ... in` for local bindings over deeply nested inline expressions.
- Avoid empty `let in` blocks — statix flags these (W02).
- Collapsible nested `let` blocks should be merged into one (W06).

## Function arguments

- Use `{ arg1, arg2, ... }:` destructuring for module and function arguments.
- Include `...` in module arguments to allow future extension without breakage.
- Do **not** use `_:` for NixOS module signatures. Use `{...}:` instead, even
  when the module does not reference any arguments. The linter (`statix`) has
  `empty_pattern` (W10) disabled to allow this. Reserve `_:` for lambda
  arguments that are genuinely unused, like `lib.mapAttrsToList (_: v: ...)`.
- Do not use `@` pattern binds (`args@{ ... }:`) unless you genuinely need the
  whole attrset. Prefer naming specific arguments.

## Module conventions

- NixOS modules follow the standard `{ config, lib, pkgs, ... }:` signature.
- Use `lib.mkEnableOption` for boolean service toggles.
- Use `lib.mkOption` with explicit `type`, `default`, and `description` for
  other options.
- Gate all side effects behind `lib.mkIf cfg.enable`.
- Prefer `lib.mkDefault` for defaults that hosts should be able to override
  without `lib.mkForce`.
- Boot activation must never be blocked by repo-owned module logic.
- Do not put network pulls, long waits, reconciliation loops, cleanup that can
  fail, or service-manager restarts on the boot activation path.
- If a module needs boot-time reconciliation or healing, run it later as a
  normal systemd unit after the machine reaches its normal userspace targets,
  not from `system.activationScripts` during `NIXOS_ACTION=boot`.
- `dry-activate` must stay non-mutating. If preview is useful, log what would
  happen without changing live service state or persistent stamps.
- Never use `exit` to “skip” a `system.activationScripts` snippet. Activation
  snippets are inlined into the top-level `/activate` shell script, so `exit 0`
  terminates the entire activation run, not just the current snippet. To skip a
  snippet, gate the snippet body with `case` / `if` and fall through normally.
- Use `exit 1` from activation snippets only when you intentionally want to fail
  the full activation. For local helper control flow inside a snippet, use shell
  conditionals or helper functions with `return`, not top-level `exit`.
- Prefer structuring non-trivial activation snippets as a shell function plus a
  single top-level call. That keeps control flow local, makes `return` usable,
  and avoids accidental termination of the full `/activate` script.

## Attrset style

- Use `rec { ... }` sparingly — it makes all bindings mutually recursive and can
  cause subtle infinite recursion. Prefer `let ... in { ... }` when only a few
  bindings need to reference each other.
- For overlays and package sets, `rec` is acceptable when the pattern is
  well-established in the repo.

## Path references

- Use relative paths (`./foo/bar.nix`) for imports within the repo.
- Use `lib.path.append` or string interpolation for computed paths.
- Do not use `<nixpkgs>` or other angle-bracket paths — the repo is flake-based.

## String interpolation

- Prefer `"${variable}"` over `("" + variable)`.
- Use multi-line strings (`'' ... ''`) for shell scripts and long text.
- Escape `${` inside multi-line strings with `''${` when you need a literal
  dollar-brace.

## Lists and attrsets

- Nix lists use spaces, not commas: `[ a b c ]`, not `[a, b, c]`.
- Attrset keys do not need quotes unless they contain special characters:
  `{ foo = 1; }`, not `{ "foo" = 1; }`.
- Use `//` for attrset merging. The right side wins on conflict.

## Conditionals

- Prefer `lib.mkIf` in module configs over inline `if ... then ... else`.
- Use `lib.optionalAttrs`, `lib.optionals`, and `lib.optionalString` for
  conditional attrset entries, list elements, and strings respectively.
- Avoid `if x == true` or `if x == false` — statix flags these (W01). Use `if x`
  or `if !x`.

## Common pitfalls

- `builtins.toJSON` on a derivation gives the store path, not the derivation
  attributes.
- Nix is lazy — unused attributes are never evaluated. Do not add defensive
  checks for attributes that may not exist unless they are actually accessed.
- `lib.mkForce` should be a last resort. If you find yourself using it, check
  whether the default should be `lib.mkDefault` instead.
- `with pkgs;` pollutes the scope and makes it hard to tell where a name comes
  from. Prefer explicit `pkgs.foo` or `let inherit (pkgs) foo bar; in ...`.

## Packaging conventions

- Every package `default.nix` is the canonical build definition. It must work
  with both `callPackage` (root flake) and `nix-build` (standalone).
- Set `meta.description` and `meta.mainProgram` on every package that produces a
  binary. `meta.mainProgram` is the standard Nix way to declare which binary a
  package provides — `lib.getExe` uses it.
- Sub-flake `flake.nix` files use `lib.getExe` (or `pkgs.lib.getExe`) to build
  app entries from the package, keeping the binary name in one place:

  ```nix
  # in the sub-flake
  apps.default = {
    type = "app";
    program = pkgs.lib.getExe build;
  };
  ```

- The root flake's `lib/flake/apps.nix` uses a `mkApp` helper that reads
  `meta.mainProgram` and `meta` from the package:

  ```nix
  mkApp = pkg: {
    type = "app";
    program = "${pkg}/bin/${pkg.meta.mainProgram}";
    inherit (pkg) meta;
  };
  ```

- Do **not** duplicate binary paths or descriptions across layers. The
  `default.nix` package is the single source of truth — sub-flakes and root apps
  derive from it.

## Flake conventions

- The repo uses a single root `flake.nix` with sub-flakes under `pkgs/`.
- Sub-flake `flake.nix` files can export `packages`, `apps`, `checks`, and
  `nixosModules`.
- Use `.` for root-flake `nix build` and `nix run` examples (e.g.,
  `nix run .#lint`).
- Lock files are committed. Run `nix flake update` or `scripts/update-flakes.sh`
  to refresh them.
