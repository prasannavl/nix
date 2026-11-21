{
  ab,
  pkgs,
  ...
}:
assert !(ab ? repo);
  pkgs.runCommand "ab-external-repo-base" {
    passthru = {
      repoVisible = ab ? repo;
      pkgOps = {
        path = "base";
        apps.fmt = {
          command = "echo base-fmt";
          envScript = "";
          runtimeInputs = [pkgs.hello];
        };
        checks = {};
      };
    };
  } ''
    mkdir -p "$out/bin"
    cat >"$out/bin/external-repo-base" <<'EOF'
    #!${pkgs.runtimeShell}
    echo external-repo-base
    EOF
    chmod +x "$out/bin/external-repo-base"
  ''
