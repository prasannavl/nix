{lib}: let
  engine = (import ../ab).core.flake.devShells {inherit lib;};
  repoRoot = builtins.toString ../.;
  repoCompletionHook = ''
    if [ -n "''${BASH_VERSION:-}" ] && type complete >/dev/null 2>&1 && type compgen >/dev/null 2>&1; then
      completion_root="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s\n' ${repoRoot})"
      if [ -f "''${completion_root}/pkgs/support/bash-completions/load.bash" ]; then
        source "''${completion_root}/pkgs/support/bash-completions/load.bash"
      fi
      unset completion_root
    fi
  '';
  withHook = args:
    args
    // {
      shellHook =
        (args.shellHook or "")
        + repoCompletionHook;
    };
in {
  mkDefault = args: engine.mkDefault (withHook args);
  mkFull = args: engine.mkFull (withHook args);
  mkDevShells = args: engine.mkDevShells (withHook args);
}
