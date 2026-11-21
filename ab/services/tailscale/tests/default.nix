{pkgs}: let
  tailscale = import ../. {lib = pkgs.lib;};
  config = {
    age.secrets.tailscale-auth-key.path = "/run/agenix/tailscale-auth-key";
  };

  secretBacked = tailscale.mkSecretBackedClient {
    inherit config;
    authKeyFile = ./fixtures/test-client.key.age;
    port = 0;
    useRoutingFeatures = "both";
    advertiseTags = ["tag:test" "tag:ci"];
    owner = "tester";
    group = "tester";
    mode = "0440";
  };

  optionalPresent = tailscale.mkOptionalAuthKeyClient {
    inherit config;
    keyName = "test-client";
    secretsDir = ./fixtures;
    port = 0;
    advertiseTags = ["tag:test"];
  };

  optionalMissing = tailscale.mkOptionalAuthKeyClient {
    inherit config;
    keyName = "missing-client";
    secretsDir = ./fixtures;
  };
in
  assert secretBacked.age.secrets.tailscale-auth-key.owner == "tester";
  assert secretBacked.age.secrets.tailscale-auth-key.group == "tester";
  assert secretBacked.age.secrets.tailscale-auth-key.mode == "0440";
  assert secretBacked.services.tailscale.enable;
  assert secretBacked.services.tailscale.authKeyFile == "/run/agenix/tailscale-auth-key";
  assert secretBacked.services.tailscale.port == 0;
  assert secretBacked.services.tailscale.useRoutingFeatures == "both";
  assert secretBacked.services.tailscale.extraUpFlags == ["--advertise-tags=tag:test,tag:ci"];
  assert optionalPresent.services.tailscale.enable;
  assert optionalPresent.services.tailscale.port == 0;
  assert optionalPresent.services.tailscale.extraUpFlags == ["--advertise-tags=tag:test"];
  assert pkgs.lib.hasSuffix "test-client.key.age" (toString optionalPresent.age.secrets.tailscale-auth-key.file);
  assert optionalMissing == {};
    pkgs.runCommand "tailscale-service-helper-test" {} ''
      touch "$out"
    ''
