{
  lib,
  document ? null,
}: let
  validation = import ../validation;
  inherit (validation.mk "invalid runtime projection closeouts") require requireOnly;
  isDigest = value:
    builtins.isString value
    && builtins.match "[0-9a-f]{64}" value != null;
  loaded =
    if document == null
    then {
      schema_version = 1;
      closeouts = {};
      controller_reconcile_exclusions = [];
    }
    else document;
  validateCloseout = transaction: closeout:
    assert require (builtins.isString transaction && transaction != "") "closeout transaction must be non-empty";
    assert require (builtins.isAttrs closeout) "closeout ${transaction} must be an object";
    assert requireOnly ["affected_hosts" "controller_reconcile" "decision" "projection_sha256"] closeout "closeout ${transaction}";
    assert require (builtins.isList (closeout.affected_hosts or null) && closeout.affected_hosts != [] && lib.all (host: builtins.isString host && host != "") closeout.affected_hosts) "closeout ${transaction} affected_hosts must be a non-empty string list";
    assert require (builtins.length closeout.affected_hosts == builtins.length (lib.unique closeout.affected_hosts)) "closeout ${transaction} affected_hosts must be unique";
    assert require (builtins.isBool (closeout.controller_reconcile or true)) "closeout ${transaction} controller_reconcile must be Boolean";
    assert require (builtins.elem (closeout.decision or null) ["complete" "rollback"]) "closeout ${transaction} decision is unsupported";
    assert require (isDigest (closeout.projection_sha256 or null)) "closeout ${transaction} projection_sha256 must be lowercase SHA-256";
      closeout // {controller_reconcile = closeout.controller_reconcile or true;};
  validated = assert require (builtins.isAttrs loaded) "document must be an object";
  assert requireOnly ["schema_version" "closeouts" "controller_reconcile_exclusions"] loaded "document";
  assert require ((loaded.schema_version or null) == 1) "schema_version must be 1";
  assert require (builtins.isAttrs (loaded.closeouts or null)) "closeouts must be an attribute set";
  assert require (builtins.isList (loaded.controller_reconcile_exclusions or null)) "controller_reconcile_exclusions must be a list";
  assert require (lib.all (projection: builtins.isString projection && projection != "") loaded.controller_reconcile_exclusions) "controller_reconcile_exclusions must contain non-empty strings";
  assert require (builtins.length loaded.controller_reconcile_exclusions == builtins.length (lib.unique loaded.controller_reconcile_exclusions)) "controller_reconcile_exclusions must be unique";
    loaded
    // {closeouts = builtins.mapAttrs validateCloseout loaded.closeouts;};
in
  builtins.deepSeq validated validated
