{pkgs}: let
  kanidm = import ../. {
    pkgs = pkgs;
    lib = pkgs.lib;
  };
  fixtureLib = import ../. {
    lib = pkgs.lib;
    pkgs =
      pkgs
      // {
        writeText = _name: text: builtins.fromJSON text;
        writeShellApplication = args: args;
      };
  };
  metadataFor = state:
    (fixtureLib.mkApplyScript {
      url = "https://example.test";
      kanidmPackage.version = "fixture";
      inherit state;
    }).runtimeEnv.KANIDM_DECLARATIVE_METADATA;
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
  normalization = assert !(builtins.tryEval (metadataFor {oauth2 = {};}).state).success;
  assert !(builtins.tryEval (metadataFor {unknownField = true;}).state).success;
  assert !(builtins.tryEval (metadataFor {serviceAccounts.anonymous = {};}).state).success;
  assert !(builtins.tryEval (metadataFor {users.admin = {};}).state).success;
  assert !(builtins.tryEval (metadataFor {serviceAccounts."admin@example.test" = {};}).state).success;
  assert (metadataFor {groupMembers.team = ["alice@example.test"];}).state.groupMembers
  == [
    {
      name = "team";
      members = ["alice"];
    }
  ];
  assert (builtins.tryEval (app {}).drvPath).success;
  assert !(builtins.tryEval (app {pkce = false;}).drvPath).success;
  assert !(builtins.tryEval (app {type = "confidential";}).drvPath).success;
    pkgs.runCommand "kanidm-oauth-normalization-test" {} ''
      touch "$out"
    '';
  helper =
    pkgs.runCommand "kanidm-helper-test" {
      nativeBuildInputs = [pkgs.bash pkgs.jq pkgs.nodejs pkgs.python3];
    } ''
      cp -R ${../.} kanidm
      python kanidm/tests/test_helper.py
      touch "$out"
    '';
}
