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

        if ${lib.getExe pkgs.natscli} "''${nats_args[@]}" stream info "$stream" >/dev/null 2>&1; then
          echo "stream already exists: $stream ($subject)"
          return 0
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
