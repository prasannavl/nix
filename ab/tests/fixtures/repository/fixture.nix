{
  ab,
  pkgs,
  ...
}:
assert !(ab ? repo);
  pkgs.runCommand "ab-repo-fixture" {
    passthru = {
      repoVisible = ab ? repo;
      pkgOps = {
        path = "fixture";
        apps.fmt = {
          command = "echo fixture-fmt";
          envScript = "";
          runtimeInputs = [pkgs.hello];
        };
        checks = {};
      };
    };
  } ''
    touch "$out"
  ''
