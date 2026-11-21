{statefulServicePlacementProgram}: {
  stateful-service-placement = {
    domains = ["serviceMoves"];
    program = statefulServicePlacementProgram;
    validateDocument = document:
      builtins.isAttrs document
      && builtins.attrNames document == ["moves" "placements" "predecessors" "schema_version"]
      && (document.schema_version or null) == 3
      && builtins.isAttrs (document.placements or null)
      && builtins.isAttrs (document.moves or null)
      # Schema 3 originally reserved predecessor mappings for the fleet
      # cutover. The cutover is complete; keep the stable wire shape while
      # requiring the retired mappings to remain empty.
      && (document.predecessors or null)
      == {
        "1".scope_aliases = {};
        "2".scope_aliases = {};
      };
  };
}
