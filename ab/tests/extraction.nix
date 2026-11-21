{pkgs}: let
  lib = pkgs.lib;
  isolate = name:
    builtins.path {
      path = ../. + "/${name}";
      name = "ab-${name}-extraction-test";
    };
  core = import (isolate "core");
  stack = import (isolate "stack") {inherit core;};
  services = import (isolate "services") {inherit core;};
  system = import (isolate "system") {inherit core;};
  adapter = services.modules.abirdHostAgentNixosAdapter {
    inherit lib;
    config._ab.nixos.registeredUnits = [];
  };
  family = stack.config.family {
    accountData = {
      rawUserdata = {};
      rawGroupData = {};
    };
    defaults = {
      org = "test";
      identitySuffix = "example.test";
      fabric.addressBases.ipv4 = "10.10";
      secrets.directory = "/fixture/secrets";
      secrets.labelRoot = "fixture/secrets";
    };
    stackDefinitions = {};
    registryFor = _: {};
  };
  fabric = stack.fabric.projection {
    inherit lib;
    projection = {
      access.web = {
        from.fabric = "test";
        to = {
          fabric = "test";
          endpoint = "web";
        };
        tcp = [80];
      };
      addressBases.ipv4 = "10.10";
      endpoints.web = 10;
      fabrics.test = 1;
    };
  };
  phase = stack.phase.projection {inherit lib;};
  persistence = profile: profiles:
    system.installer.persistence {
      installerName = "probe";
      repoSource = ./.;
      installerUsers.alice = {
        enable = true;
        inherit profile;
      };
      userProfiles = profiles;
    } {
      inherit lib pkgs;
      inputs.home-manager.nixosModules.home-manager = {};
      utils.escapeSystemdPath = value: value;
    };
  validProfile = {users.users.alice.description = "profile-selected";};
  rejects = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
in
  assert builtins.deepSeq adapter.imports true;
  assert adapter.config.services.abird-host-agent.services == {};
  assert family.stacks == {};
  assert fabric.forwardRules
  == [
    {
      from = "test";
      to = "test";
      destination = "10.10.1.10";
      tcpPorts = [80];
    }
  ];
  assert phase.documents == [];
  assert builtins.elem validProfile (persistence "core" {alice.core = validProfile;}).imports;
  assert rejects (persistence "typo" {alice.core = validProfile;}).imports;
  assert builtins.length (persistence null {alice.core = validProfile;}).imports == 2;
  assert builtins.length (persistence "core" {}).imports == 2;
    pkgs.runCommand "ab-component-extraction-test" {} ''
      touch "$out"
    ''
