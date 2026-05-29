let
  targetPathBase = "/var/lib/abird";
  abirdIncusController = {
    controller_host = "abird-nest";
    remote = "local";
  };
  commonExcludes = [
    "!./compose/"
    "!./.podman-compose/"
    "!./tmp/"
  ];
  mkProfile = source_host: source_paths: {
    inherit source_host;
    incus = abirdIncusController;
    source_paths = source_paths ++ commonExcludes;
    target_path_base = targetPathBase;
  };
  mkEmptyProfile = source_host: {
    inherit source_host;
    incus = abirdIncusController;
    source_paths = [];
    target_path_base = targetPathBase;
  };
in {
  abird-ci = mkEmptyProfile "10.10.30.80";
  abird-corp = mkProfile "10.10.30.60" [
    "/var/lib/abird/excalidash"
    "/var/lib/abird/mirofish"
    "/var/lib/abird/open-webui"
    "/var/lib/abird/outline"
    "/var/lib/abird/stalwart"
    "/var/lib/abird/zulip"
  ];
  abird-data = mkProfile "10.10.30.50" [
    "/var/lib/abird/graphiti"
    "/var/lib/abird/nats"
    "/var/lib/abird/postgres"
  ];
  abird-dev = mkEmptyProfile "10.10.30.90";
  abird-edge = mkEmptyProfile "10.77.10.1";
  abird-id = mkProfile "10.10.30.30" [
    "/var/lib/abird/kanidm"
  ];
  abird-nest = mkEmptyProfile "abird-nest";
  abird-obs = mkProfile "10.10.30.40" [
    "/var/lib/abird/grafana"
    "/var/lib/abird/vector-hub"
    "/var/lib/abird/victorialogs"
    "/var/lib/abird/victoriametrics"
    "/var/lib/abird/victoriatraces"
  ];
  abird-proxy = mkEmptyProfile "10.10.30.20";
  abird-srv = mkProfile "10.10.30.70" [
    "/var/lib/abird/ollama"
  ];
}
