{
  lib,
  pkgs,
}: let
  isNonEmptyString = value: builtins.isString value && builtins.match "[[:space:]]*" value == null;
  isHttpUrl = value: builtins.isString value && builtins.match "https?://.+" value != null;
  routeLabel = route: route.name or route.subject or "<unnamed>";
  validateRoute = route: let
    label = routeLabel route;
    transport = route.transport or {kind = "core";};
    transportKind = transport.kind or "core";
    positiveIfSet = name:
      if builtins.hasAttr name transport && builtins.getAttr name transport < 1
      then ["route ${label} transport.${name} must be at least 1"]
      else [];
  in
    []
    ++ lib.optional (!(isNonEmptyString (route.subject or null))) "route ${label} subject must not be empty"
    ++ lib.optional (!(route ? http)) "route ${label} must set http"
    ++ lib.optional (route ? http && !(isHttpUrl (route.http.url or null))) "route ${label} http.url must use http or https"
    ++ lib.optional (!(builtins.elem (route.mode or "push") ["push" "request-response"])) "route ${label} mode must be push or request-response"
    ++ lib.optional (!(builtins.elem transportKind ["core" "jetstream"])) "route ${label} transport.kind must be core or jetstream"
    ++ lib.optionals (transportKind == "jetstream") (
      []
      ++ lib.optional (!(isNonEmptyString (transport.stream or null))) "JetStream route ${label} must set transport.stream"
      ++ lib.optional (transport ? consumer && !(isNonEmptyString transport.consumer)) "JetStream route ${label} has an empty transport.consumer"
      ++ positiveIfSet "ack_wait_secs"
      ++ positiveIfSet "max_ack_pending"
      ++ positiveIfSet "max_deliver"
      ++ positiveIfSet "fetch_batch"
      ++ positiveIfSet "nak_delay_secs"
    );
  validateConfig = config: let
    errors =
      []
      ++ lib.optional (!(config ? routes) || !(builtins.isList config.routes) || config.routes == []) "config must include at least one routes entry"
      ++ lib.concatMap validateRoute (config.routes or []);
  in
    if errors == []
    then config
    else throw "invalid nats-http-bridge config:\n${lib.concatStringsSep "\n" (map (error: "- ${error}") errors)}";
in {
  mkConfigText = name: config: pkgs.writeText name (builtins.toJSON (validateConfig config));
  validateConfig = validateConfig;
}
