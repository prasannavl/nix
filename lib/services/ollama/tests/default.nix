{pkgs}: {
  helper =
    pkgs.runCommand "ollama-helper-test" {
      nativeBuildInputs = [
        pkgs.bash
        pkgs.coreutils
        pkgs.jq
        pkgs.python3
      ];
    } ''
      repo="$TMPDIR/repo"
      mkdir -p "$repo/lib/services"
      cp -R ${../.} "$repo/lib/services/ollama"
      chmod -R u+w "$repo"
      python -m unittest discover \
        --start-directory "$repo/lib/services/ollama/tests" \
        --pattern 'test_*.py'
      touch "$out"
    '';
}
