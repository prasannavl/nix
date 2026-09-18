{pkgs}: {
  helper =
    pkgs.runCommand "llama-router-helper-test" {
      nativeBuildInputs = [
        pkgs.bash
        pkgs.coreutils
        pkgs.jq
        pkgs.python3
      ];
    } ''
      repo="$TMPDIR/repo"
      mkdir -p "$repo/lib/services"
      cp -R ${../.} "$repo/lib/services/llama-router"
      chmod -R u+w "$repo"
      python -m unittest discover \
        --start-directory "$repo/lib/services/llama-router/tests" \
        --pattern 'test_*.py'
      touch "$out"
    '';
  module = import ./module.nix {inherit pkgs;};
}
