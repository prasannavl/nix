{
  ab,
  config,
  hostName,
  ...
}: let
  tailscaleClient = ab.services.tailscale.mkOptionalAuthKeyClient {
    inherit config;
    keyName = hostName;
    secretsDir = ../../data/secrets/globals/tailscale;
    authKeyStoreName = "tailscale-${hostName}-auth-key.age";
    port = 0;
    advertiseTags = ["tag:vm"];
  };
in {
  imports = [
    (ab.system.profiles.incusGuest {
      inherit hostName tailscaleClient;
      runtimeProfile = ab.runtime.incus.profiles.vm;
      machineIdModule = ab.services.machineId.module;
      hostAgentModule = ab.services.abirdHostAgent.module;
      fail2banModule = ab.services.fail2banHelper.module;
      nixPolicyModule = ./policy/nix.nix;
      localeModule = ./policy/locale.nix;
    })
  ];
}
