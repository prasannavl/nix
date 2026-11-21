let
  isServiceRegistry = registry:
    builtins.isAttrs registry
    && builtins.isAttrs (registry.roles or null)
    && builtins.isAttrs (registry.services or null);
in {
  isServiceRegistry = isServiceRegistry;
  isServiceStack = stack:
    builtins.isAttrs stack
    && isServiceRegistry (stack.serviceRegistry or null);

  # withServiceRoles rebuilds only the selected scope's service-registry
  # layer. Preserve the topology, infra, and static placement views
  # already projected under topology. Named scopes are transformed
  # independently and materialized back into their parent stack by the
  # repository fold.
  applyServiceRoleOverrides = stack: roleOverrides:
    if roleOverrides == {}
    then stack
    else stack // stack.withServiceRoles roleOverrides;
}
