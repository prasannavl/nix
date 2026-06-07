{lib}: let
  repoRoot = builtins.toString ../..;
  repoCompletionHook = ''
    if [ -n "''${BASH_VERSION:-}" ] && type complete >/dev/null 2>&1 && type compgen >/dev/null 2>&1; then
      completion_root="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s\n' ${repoRoot})"
      if [ -f "''${completion_root}/pkgs/support/bash-completions/load.bash" ]; then
        source "''${completion_root}/pkgs/support/bash-completions/load.bash"
      fi
      unset completion_root
    fi
  '';
in rec {
  # Build the lean default devShell. Holds repo-wide authoring tools only
  # (nix, formatter, deploy helpers). Keep this small — it is evaluated on
  # every `direnv allow` at the repo root and must stay fast.
  mkDefault = {
    pkgs,
    rootPackages ? [],
  }:
    pkgs.mkShell {
      name = "nix-repo";
      packages = rootPackages;
      shellHook = repoCompletionHook;
    };

  # Build the aggregate devShell. Walks the provided package attrset, pulls
  # every `passthru.devShell` it finds, and composes them with the root tool
  # set via `inputsFrom`. Opt-in: enter with `nix develop .#full`.
  #
  # To drop the full shell later, delete this function and its call site in
  # flake.nix. The default shell is unaffected.
  mkFull = {
    pkgs,
    rootPackages ? [],
    childPackages ? {},
  }: let
    childShells = lib.pipe childPackages [
      builtins.attrValues
      (builtins.filter (p: (p.passthru or {}) ? devShell))
      (map (p: p.passthru.devShell))
    ];
  in
    pkgs.mkShell {
      name = "nix-repo-full";
      packages = rootPackages;
      inputsFrom = childShells;
      shellHook = repoCompletionHook;
    };

  mkDevShells = args: {
    default = mkDefault (builtins.removeAttrs args ["childPackages"]);
    full = mkFull args;
  };
}
