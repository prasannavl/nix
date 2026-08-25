{lib}: let
  fail = message: throw "invalid phase projection: ${message}";
  require = condition: message:
    if condition
    then true
    else fail message;
  requireOnly = allowed: value: context: let
    unknown = builtins.filter (name: !builtins.elem name allowed) (builtins.attrNames value);
  in
    require (unknown == []) "${context} has unknown fields: ${lib.concatStringsSep ", " unknown}";
  isDigest = value:
    builtins.isString value
    && builtins.match "[0-9a-f]{64}" value != null;
  validStates = ["held" "active" "inactive" "unheld"];
  validateResource = resource:
    assert require (builtins.isAttrs resource) "resources must contain objects";
    assert requireOnly ["id" "role" "kind" "name" "endpoint"] resource "resource";
    assert require (builtins.isString resource.id && resource.id != "") "resource entry id must be non-empty";
    assert require (builtins.isString resource.role && resource.role != "") "resource role must be non-empty";
    assert require (builtins.elem resource.kind ["host" "service" "resource" "instance"]) "resource kind is unsupported";
    assert require (builtins.isString resource.name && resource.name != "") "resource name must be non-empty";
    assert require (builtins.isAttrs resource.endpoint) "resource endpoint must be an object"; let
      endpoint = resource.endpoint;
    in
      assert requireOnly ["host" "host_resource" "resource" "hold_epoch" "transaction_id" "activation_job_id" "desired_state"] endpoint "resource endpoint";
      assert require (builtins.isString endpoint.host && endpoint.host != "") "endpoint host must be non-empty";
      assert require (builtins.isString endpoint.host_resource && lib.hasPrefix "host:" endpoint.host_resource) "host_resource must be canonical";
      assert require (builtins.isString endpoint.resource && endpoint.resource != "") "resource must be non-empty";
      assert require (builtins.elem endpoint.desired_state validStates) "desired_state is unsupported";
      assert require (endpoint.hold_epoch == null || (builtins.isString endpoint.hold_epoch && endpoint.hold_epoch != "")) "hold_epoch must be null or non-empty";
      assert require (endpoint.transaction_id == null || (builtins.isString endpoint.transaction_id && endpoint.transaction_id != "")) "transaction_id must be null or non-empty";
      assert require ((endpoint.hold_epoch == null) == (endpoint.transaction_id == null)) "hold_epoch and transaction_id must be declared together";
      assert require (endpoint.activation_job_id == null || (builtins.isString endpoint.activation_job_id && endpoint.activation_job_id != "")) "activation_job_id must be null or non-empty";
      assert require ((endpoint.desired_state == "active" && endpoint.hold_epoch != null) == (endpoint.activation_job_id != null)) "exactly active held resources require activation_job_id";
      assert require (endpoint.desired_state == "active" || endpoint.hold_epoch != null) "held, inactive, and unheld resources require a hold_epoch";
        resource
        // {endpoint = endpoint;};
in {
  localDesiredResourceStates = {
    hostResource,
    projection,
  }:
    assert require (builtins.isString hostResource && lib.hasPrefix "host:" hostResource) "hostResource must be canonical";
    assert require (builtins.isAttrs projection) "projection must be an object";
    assert requireOnly ["schema_version" "projection_id" "intent_kind" "phase" "generation" "intent" "intent_sha256" "resources" "effects" "activation_requirement" "previous_projection_sha256" "previous_repository_revision" "projection_sha256"] projection "projection document";
    assert require (projection.schema_version == 1) "schema_version must be 1";
    assert require (builtins.isString projection.projection_id && projection.projection_id != "") "projection_id must be non-empty";
    assert require (builtins.isString projection.intent_kind && projection.intent_kind != "") "intent_kind must be non-empty";
    assert require (isDigest projection.intent_sha256) "intent_sha256 must be a lowercase SHA-256 digest";
    assert require (builtins.isString projection.phase && projection.phase != "") "phase must be non-empty";
    assert require (builtins.isInt projection.generation && projection.generation > 0) "generation must be positive";
    assert require (isDigest projection.projection_sha256) "projection_sha256 must be a lowercase SHA-256 digest";
    assert require (projection.activation_requirement == null || builtins.isAttrs projection.activation_requirement) "activation_requirement must be null or an object";
    assert require (projection.activation_requirement == null || requireOnly ["kind" "requirement_sha256"] projection.activation_requirement "activation requirement") "activation requirement fields must be canonical";
    assert require (projection.activation_requirement == null || (builtins.isString projection.activation_requirement.kind && projection.activation_requirement.kind != "")) "activation requirement kind must be non-empty";
    assert require (projection.activation_requirement == null || isDigest projection.activation_requirement.requirement_sha256) "activation requirement must be a lowercase SHA-256 digest";
    assert require (builtins.isList projection.resources) "resources must be a list";
    assert require (builtins.isList projection.effects) "effects must be a list";
    assert require (builtins.hashString "sha256" (builtins.toJSON projection.intent) == projection.intent_sha256) "intent_sha256 does not match intent";
    assert require (builtins.hashString "sha256" (builtins.toJSON (builtins.removeAttrs projection ["projection_sha256"])) == projection.projection_sha256) "projection_sha256 does not match canonical content"; let
      resources = map validateResource projection.resources;
      localResources = builtins.filter (resource: resource.endpoint.host_resource == hostResource) resources;
      resourceIds = map (resource: resource.endpoint.resource) localResources;
      activation = projection.activation_requirement;
    in
      assert require (lib.length resourceIds == lib.length (lib.unique resourceIds)) "one host projection cannot declare a resource more than once";
        lib.listToAttrs (
          map
          (resource: let
            endpoint = resource.endpoint;
            activationRequired = endpoint.hold_epoch != null && activation != null;
          in
            lib.nameValuePair endpoint.resource {
              state = endpoint.desired_state;
              projectionId = projection.projection_id;
              intentDigest = projection.intent_sha256;
              phase = projection.phase;
              projectionDigest = projection.projection_sha256;
              generation = projection.generation;
              holdEpoch = endpoint.hold_epoch;
              transactionId = endpoint.transaction_id;
              activationJobId = endpoint.activation_job_id;
              activationRequirementKind =
                if activationRequired
                then activation.kind
                else null;
              activationRequirementDigest =
                if activationRequired
                then activation.requirement_sha256
                else null;
            })
          localResources
        );
}
