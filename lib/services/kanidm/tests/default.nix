{pkgs}: let
  kanidm = import ../. {
    pkgs = pkgs;
    lib = pkgs.lib;
  };
  app = options:
    kanidm.mkApplyScript {
      url = "https://localhost:18443";
      state.oauthApps.agent =
        {
          origin = "https://localhost:18443";
          type = "public";
          allowLocalhostRedirects = true;
        }
        // options;
    };
in {
  normalization = assert (builtins.tryEval (app {}).drvPath).success;
  assert !(builtins.tryEval (app {pkce = false;}).drvPath).success;
  assert !(builtins.tryEval (app {type = "confidential";}).drvPath).success;
    pkgs.runCommand "kanidm-oauth-normalization-test" {} ''
      touch "$out"
    '';
  helper =
    pkgs.runCommand "kanidm-helper-test" {
      nativeBuildInputs = [pkgs.bash pkgs.jq pkgs.python3];
    } ''
      cp -R ${../.} kanidm
      python kanidm/tests/test_helper.py
      touch "$out"
    '';
}
