{
  pkgs ? import <nixpkgs> {},
  stack ? import ../../../lib/flake/stack/package.nix,
}: let
  s = stack;
  pkg = s.pkg;
  srv = s.srv;
  lib = pkgs.lib;

  mkStreamSetInternal = {
    serviceName,
    clientServiceName,
    envPrefix,
    packageDescription,
    streams,
    serviceParts,
    bindModule,
  }: let
    ensureStreams =
      lib.concatMapStringsSep "\n" (stream: ''
        ensure_stream ${lib.escapeShellArg stream.stream} ${lib.escapeShellArg stream.subject}
      '')
      streams;
    ensureStreamsScript = pkgs.writeShellScript "${s.stackName}-${serviceName}" ''
      set -euo pipefail

      nats_url="$1"
      nats_ca_cert_path="$2"
      nats_client_cert_path="$3"
      nats_client_key_path="$4"

      nats_args=(
        --server "$nats_url"
        --tlsca "$nats_ca_cert_path"
        --tlscert "$nats_client_cert_path"
        --tlskey "$nats_client_key_path"
        --tlsfirst
        --timeout 10s
      )

      wait_for_nats() {
        local attempts=60
        local attempt=1

        while (( attempt <= attempts )); do
          if ${lib.getExe pkgs.natscli} "''${nats_args[@]}" server check connection >/dev/null 2>&1; then
            return 0
          fi

          echo "waiting for NATS readiness ($attempt/$attempts): $nats_url" >&2
          sleep 1
          ((attempt++))
        done

        echo "NATS did not become ready after $attempts seconds: $nats_url" >&2
        return 1
      }

      ensure_stream() {
        local stream="$1"
        local subject="$2"
        local info_json
        local streams_json

        if ! streams_json="$(${lib.getExe pkgs.natscli} "''${nats_args[@]}" stream ls --json 2>&1)"; then
          echo "stream listing failed while checking: $stream" >&2
          printf '%s\n' "$streams_json" >&2
          echo "refusing to create a stream whose absence was not established" >&2
          return 1
        fi

        if ! ${lib.getExe pkgs.jq} -e '
          . == null or (type == "array" and all(.[]; type == "string"))
        ' <<<"$streams_json" >/dev/null; then
          echo "stream listing returned an unexpected JSON shape while checking: $stream" >&2
          printf '%s\n' "$streams_json" >&2
          echo "refusing to create a stream whose absence was not established" >&2
          return 1
        fi

        if ${lib.getExe pkgs.jq} -e --arg stream "$stream" '(. // []) | index($stream) != null' <<<"$streams_json" >/dev/null; then
          if ! info_json="$(${lib.getExe pkgs.natscli} "''${nats_args[@]}" stream info "$stream" --json 2>&1)"; then
            echo "stream info failed after listing: $stream" >&2
            printf '%s\n' "$info_json" >&2
            echo "refusing to mutate or recreate a stream with unknown configuration" >&2
            return 1
          fi

          if ${lib.getExe pkgs.jq} -e --arg subject "$subject" '
            .config.subjects == [$subject]
            and .config.storage == "file"
            and .config.retention == "workqueue"
            and .config.max_consumers == 1
          ' <<<"$info_json" >/dev/null; then
            echo "stream already converged: $stream ($subject)"
            return 0
          fi

          echo "stream configuration drift: $stream" >&2
          ${lib.getExe pkgs.jq} -c '{
            subjects: .config.subjects,
            storage: .config.storage,
            retention: .config.retention,
            max_consumers: .config.max_consumers
          }' <<<"$info_json" >&2
          echo "refusing to mutate an existing stream; reconcile it explicitly" >&2
          return 1
        fi

        ${lib.getExe pkgs.natscli} "''${nats_args[@]}" stream add "$stream" \
          --subjects "$subject" \
          --storage file \
          --retention work \
          --ack \
          --max-consumers 1 \
          --defaults
      }

      wait_for_nats

      ${ensureStreams}
    '';
    build =
      (pkgs.writeShellApplication {
        name = serviceName;
        text = ''
          exec ${ensureStreamsScript} "$@"
        '';
        meta = {
          description = packageDescription;
          mainProgram = serviceName;
        };
      })
      .overrideAttrs (_: {
        pname = "nats-streams";
        version = "0.1.0";
      });
    nixosModule = srv.mkServicesModule {
      package =
        if bindModule
        then build
        else null;
      sourcePath = ./default.nix;
      name = serviceName;
      envPrefix = envPrefix;
      restart = "no";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      services =
        [
          (srv.mkServiceIdentity {
            serviceName = clientServiceName;
          })
          (srv.mkNatsClientService {
            requireLocalNats = true;
          })
        ]
        ++ serviceParts;
      extraServiceConfig = cfg: {
        ExecStart = ''
          ${lib.getExe cfg.package} \
            ${lib.escapeShellArg cfg.natsUrl} \
            ${lib.escapeShellArg cfg.natsCaCertPath} \
            ${lib.escapeShellArg cfg.serviceCertPath} \
            ${lib.escapeShellArg cfg.serviceKeyPath}
        '';
        Type = "oneshot";
      };
    };
  in
    pkg.wirePassthru build {
      nixosModule = nixosModule;
      streamSet = {
        inherit clientServiceName envPrefix packageDescription serviceName streams;
        servicePartCount = builtins.length serviceParts;
      };
    };

  mkStreamSet = {
    serviceName ? "nats-streams",
    clientServiceName ? serviceName,
    envPrefix ? "NATS_STREAMS",
    packageDescription ? "Ensure configured NATS JetStream streams exist",
    streams ? [],
    serviceParts ? [],
  }:
    mkStreamSetInternal {
      inherit clientServiceName envPrefix packageDescription serviceName serviceParts streams;
      bindModule = true;
    };

  defaultStreamSet = mkStreamSetInternal {
    serviceName = "nats-streams";
    clientServiceName = "nats-streams";
    envPrefix = "NATS_STREAMS";
    packageDescription = "Ensure configured NATS JetStream streams exist";
    streams = [];
    serviceParts = [];
    bindModule = false;
  };
in
  pkg.wirePassthru defaultStreamSet {
    mkStreamSet = mkStreamSet;
  }
