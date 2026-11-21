{ab, ...}: {
  imports = [
    (ab.system.profiles.vm {
      nixPolicyModule = ./policy/nix.nix;
      localeModule = ./policy/locale.nix;
      networkPolicyModule = ./policy/network.nix;
      hostAgentModule = ab.services.abirdHostAgent.module;
    })
  ];
}
