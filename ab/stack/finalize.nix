{validation}: {
  stack,
  projection ? {},
  placements ? stack.topology.placements or null,
  withServiceRoles ? stack.withServiceRoles,
}: let
  inherit (validation.mk "stack assembly") mergeUniqueAttrs require;
  namespaces = ["network" "topology" "infra"];
  topology = mergeUniqueAttrs "topology" [
    (builtins.removeAttrs (stack.topology or {}) ["placements"])
    (projection.topology or {})
  ];
in
  assert require (!(projection ? withServiceRoles)) "projection may not replace withServiceRoles";
  assert require (!(projection ? topology.placements)) "placements belong to the stack constructor, not its projection";
    (mergeUniqueAttrs "fields" [
      (builtins.removeAttrs stack (namespaces ++ ["withServiceRoles"]))
      (builtins.removeAttrs projection namespaces)
    ])
    // {withServiceRoles = withServiceRoles;}
    // (
      if stack ? network || projection ? network
      then {
        network = mergeUniqueAttrs "network" [(stack.network or {}) (projection.network or {})];
      }
      else {}
    )
    // (
      if stack ? infra || projection ? infra
      then {
        infra = mergeUniqueAttrs "infra" [(stack.infra or {}) (projection.infra or {})];
      }
      else {}
    )
    // (
      if stack ? topology || projection ? topology || placements != null
      then {
        topology =
          topology
          // (
            if placements == null
            then {}
            else {placements = placements;}
          );
      }
      else {}
    )
