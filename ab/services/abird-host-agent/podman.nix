{
  config,
  lib,
  ...
}: let
  facts = config._ab.runtime.podman.facts;
  holdGate = import ./hold-gate.nix;

  hostAgentServices =
    lib.mapAttrs (
      _: fact: {
        units = [
          {
            scope = "user";
            user = fact.user;
            unit = fact.units.primary;
          }
        ];
        dataPaths = fact.resources.storage.dataPaths;
        gatedUserUnits.${fact.user} = fact.units.gated;
      }
    )
    facts;
in {
  imports = [
    ./options.nix
  ];

  config = {
    _ab.runtime.podman.runtimeGateFor = {serviceName}:
      if config.services.abird-host-agent.enable
      then {
        readinessUnit = holdGate.userReadinessUnit;
        conditionPathExists =
          holdGate.conditionsFor {
            stateDirectory = config.services.abird-host-agent.stateDirectory;
            resource = "service:${serviceName}";
          }
          ++ lib.optionals config.services.abird-host-agent.manageHostResource (
            holdGate.conditionsFor {
              stateDirectory = config.services.abird-host-agent.stateDirectory;
              resource = "host:${config.networking.hostName}";
              isHostResource = true;
            }
          );
      }
      else null;

    services.abird-host-agent.services = hostAgentServices;
  };
}
