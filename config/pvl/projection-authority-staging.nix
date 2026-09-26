{
  lib,
  pkgs,
  projectionAdmission,
  ...
}: let
  serviceMoves = projectionAdmission.serviceMoves or null;
  emptyRegistry = pkgs.writeText "abird-host-agent-generation-admission-registry-staging.json" (builtins.toJSON {
    schema_version = 1;
    domains = [];
  });
in {
  assertions = [
    {
      assertion =
        builtins.isAttrs serviceMoves
        && builtins.isAttrs (serviceMoves.document or null)
        && (serviceMoves.document.schema_version or null) == 3;
      message = "projection authority staging requires the schema-3 serviceMoves authority document";
    }
  ];

  # Stage complete schema-3 authority before registering its validator. Remove
  # this module only after every deployable Pvl host has entered this generation.
  environment.etc."abird-host-agent/generation-admission-registry.json".source = lib.mkForce emptyRegistry;
}
