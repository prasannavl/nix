{
  config,
  lib,
  ...
}: let
  cfg = config.services.vector-agent;
  hostLabel = cfg.hostLabel;
  hub = cfg.hub;
  hubTls = hub.tls;

  normalizeAddr = a:
    if a == "0.0.0.0"
    then "127.0.0.1"
    else if a == "::"
    then "[::1]"
    else a;

  mkHubTlsConfig =
    {
      enabled = true;
      ca_file = hubTls.caCertPath;
      crt_file = hubTls.clientCertPath;
      key_file = hubTls.clientKeyPath;
      verify_certificate = true;
      verify_hostname = hubTls.verifyHostname;
    }
    // lib.optionalAttrs (hubTls.serverName != "") {
      server_name = hubTls.serverName;
    };

  nodeExporterPort = 9100;
  processExporterPort = 9256;

  mkCanonicalMetricTagsVrl = {
    host,
    job,
  }: ''
    if !exists(.tags) || !is_object(.tags) {
      .tags = {}
    }

    .tags.host = "${host}"
    .tags.instance = "${host}"
    .tags.job = "${job}"
  '';

  mkScrapeSource = {
    name,
    targets,
    metricsPath ? "/metrics",
    scheme ? "http",
    scrapeInterval ? 15,
    extraLabels ? {},
    tls ? null,
  }: {
    "scrape_${name}" =
      {
        type = "prometheus_scrape";
        endpoints = map (t: "${scheme}://${t}${metricsPath}") targets;
        scrape_interval_secs = scrapeInterval;
        instance_tag = "instance";
        endpoint_tag = "endpoint";
        extra_labels = extraLabels;
      }
      // lib.optionalAttrs (tls != null) {
        tls =
          {
            verify_certificate = true;
            verify_hostname = tls.verifyHostname;
          }
          // lib.optionalAttrs (tls.caCertPath != "") {
            ca_file = tls.caCertPath;
          }
          // lib.optionalAttrs (tls.clientCertPath != "") {
            crt_file = tls.clientCertPath;
          }
          // lib.optionalAttrs (tls.clientKeyPath != "") {
            key_file = tls.clientKeyPath;
          }
          // lib.optionalAttrs (tls.serverName != "") {
            server_name = tls.serverName;
          };
      };
  };

  mkScrapeRelabel = {
    name,
    jobName,
  }: {
    "scrape_${name}_relabel" = {
      type = "remap";
      inputs = ["scrape_${name}"];
      source = mkCanonicalMetricTagsVrl {
        host = hostLabel;
        job = jobName;
      };
    };
  };

  mkLocalScrape = {
    name,
    jobName,
    address,
    port,
    metricsPath ? "/metrics",
  }: {
    source = mkScrapeSource {
      inherit name metricsPath;
      targets = ["${normalizeAddr address}:${toString port}"];
    };
    transform = mkScrapeRelabel {
      inherit name jobName;
    };
  };

  builtinScrapes = {
    node = {
      enable = cfg.enableNodeMetrics;
      name = "node";
      job = "node-exporter";
      address = "127.0.0.1";
      port = nodeExporterPort;
    };
    process = {
      enable = cfg.enableProcessMetrics;
      name = "process";
      job = "process-exporter";
      address = "127.0.0.1";
      port = processExporterPort;
    };
    nginx = {
      enable = cfg.nginxExporter.enable;
      name = "nginx_exporter";
      job = "nginx-exporter";
      address = cfg.nginxExporter.listenAddress;
      port = cfg.nginxExporter.port;
    };
    postgres = {
      enable = cfg.postgresExporter.enable;
      name = "postgres_exporter";
      job = "postgres-exporter";
      address = cfg.postgresExporter.listenAddress;
      port = cfg.postgresExporter.port;
    };
    nats = {
      enable = cfg.natsExporter.enable;
      name = "nats_exporter";
      job = "nats-exporter";
      address = cfg.natsExporter.listenAddress;
      port = cfg.natsExporter.port;
    };
  };

  builtinScrapeList = lib.attrValues builtinScrapes;
  localScrapes = map (s:
    mkLocalScrape {
      name = s.name;
      jobName = s.job;
      address = s.address;
      port = s.port;
    }) (lib.filter (s: s.enable) builtinScrapeList);
  localScrapeSources = lib.foldl' (acc: scrape: acc // scrape.source) {} localScrapes;
  localScrapeTransforms = lib.foldl' (acc: scrape: acc // scrape.transform) {} localScrapes;

  extraScrapeSources = lib.foldl' (acc: scrape:
    acc
    // (mkScrapeSource {
      name = scrape.name;
      targets = scrape.targets;
      metricsPath = scrape.metricsPath;
      scheme = scrape.scheme;
      scrapeInterval = lib.toInt (lib.removeSuffix "s" scrape.scrapeInterval);
      extraLabels = scrape.labels;
      tls =
        if scrape.tls.enable
        then scrape.tls
        else null;
    })) {}
  cfg.extraMetricsScrapes;

  extraScrapeRelabels = lib.foldl' (acc: scrape:
    acc
    // (mkScrapeRelabel {
      name = scrape.name;
      jobName =
        if scrape.jobName == ""
        then scrape.name
        else scrape.jobName;
    })) {}
  cfg.extraMetricsScrapes;

  scrapeSources = localScrapeSources // extraScrapeSources;

  scrapeTransforms = localScrapeTransforms // extraScrapeRelabels;

  scrapeRelabelInputs = (lib.attrNames scrapeTransforms) ++ lib.optional cfg.enableSelfMetrics "vector_self_relabel";

  selfSource = lib.optionalAttrs cfg.enableSelfMetrics {
    vector_self = {
      type = "internal_metrics";
      namespace = "vector";
    };
  };

  selfRelabel = lib.optionalAttrs cfg.enableSelfMetrics {
    vector_self_relabel = {
      type = "remap";
      inputs = ["vector_self"];
      source = mkCanonicalMetricTagsVrl {
        host = hostLabel;
        job = "vector";
      };
    };
  };

  otlpSource = lib.optionalAttrs cfg.enableOtlp {
    otlp = {
      type = "opentelemetry";
      grpc.address = "127.0.0.1:4317";
      http.address = "127.0.0.1:4318";
    };
  };

  journalSource = {
    journal = {
      type = "journald";
      current_boot_only = true;
    };
  };

  journalTransform = {
    journal_remap = {
      type = "remap";
      inputs = ["journal"];
      source = ''
        priority_keywords = {
          "0": "emerg",
          "1": "alert",
          "2": "crit",
          "3": "error",
          "4": "warn",
          "5": "notice",
          "6": "info",
          "7": "debug"
        }

        priority = string(.PRIORITY) ?? null
        if priority != null {
          .level = get(priority_keywords, [priority]) ?? "info"
        }

        .host = "${hostLabel}"

        syslog_id = string(.SYSLOG_IDENTIFIER) ?? ""

        unit = string(._SYSTEMD_UNIT) ?? ""
        user_unit = string(._SYSTEMD_USER_UNIT) ?? ""

        srv = parse_regex(syslog_id, r'^srv:(?P<svc>[^:]+)(?::(?P<fam>[^:]+))?$') ?? null
        if srv != null {
          .service = srv.svc
          if exists(srv.fam) {
            .service_family = srv.fam
          }
        }

        if !exists(.service) && user_unit != "" {
          m = parse_regex(user_unit, r'^(?P<svc>[A-Za-z0-9][A-Za-z0-9._-]*)\.service$') ?? null
          if m != null { .service = m.svc }
        }

        if !exists(.service) && unit != "" {
          m = parse_regex(unit, r'^(?P<svc>[A-Za-z0-9][A-Za-z0-9._-]*)\.service$') ?? null
          if m != null { .service = m.svc }
        }

        if !exists(.service) && syslog_id != "" {
          .service = syslog_id
        }

        lvl_match = parse_regex(string(.message) ?? "", r'^(?:[^\t]+\t)?(?P<lvl>(?i)(trace|debug|info|warn|warning|error|err|fatal|panic))\t') ?? null
        if lvl_match != null {
          lvl = downcase!(lvl_match.lvl)
          if lvl == "err" {
            .level = "error"
          } else if lvl == "warning" {
            .level = "warn"
          } else {
            .level = lvl
          }
        }
      '';
    };
  };

  hubLogsInputs = ["journal_remap"] ++ lib.optional cfg.enableOtlp "otlp.logs";
  hubMetricsInputs = scrapeRelabelInputs ++ lib.optional cfg.enableOtlp "otlp.metrics";
  hubTracesInputs = lib.optional cfg.enableOtlp "otlp.traces";

  vectorSettings = {
    data_dir = "/var/lib/vector";

    sources =
      journalSource
      // selfSource
      // otlpSource
      // scrapeSources;

    transforms =
      journalTransform
      // selfRelabel
      // scrapeTransforms;

    sinks =
      {
        hub_logs = {
          type = "vector";
          inputs = hubLogsInputs;
          address = hub.logsAddress;
          tls = mkHubTlsConfig;
        };
      }
      // lib.optionalAttrs (hubMetricsInputs != []) {
        hub_metrics = {
          type = "vector";
          inputs = hubMetricsInputs;
          address = hub.metricsAddress;
          tls = mkHubTlsConfig;
        };
      }
      // lib.optionalAttrs cfg.enableOtlp {
        hub_traces = {
          type = "vector";
          inputs = hubTracesInputs;
          address = hub.tracesAddress;
          tls = mkHubTlsConfig;
        };
      };
  };
in {
  options.services.vector-agent = {
    enable = lib.mkEnableOption "observability Vector agent (journald + node/process exporter scrapes, ships to the central Vector hub)";

    nginxExporter = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether Vector should auto-scrape the local nginx exporter.";
          };
          listenAddress = lib.mkOption {
            type = lib.types.str;
            default = "127.0.0.1";
            description = "Address Vector should use when scraping the local nginx exporter.";
          };
          port = lib.mkOption {
            type = lib.types.port;
            default = 9113;
            description = "Port Vector should expect the local nginx exporter to listen on.";
          };
        };
      };
      default = {};
      description = "Local nginx exporter integration.";
    };

    postgresExporter = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether Vector should auto-scrape the local postgres exporter.";
          };
          listenAddress = lib.mkOption {
            type = lib.types.str;
            default = "127.0.0.1";
            description = "Address Vector should use when scraping the local postgres exporter.";
          };
          port = lib.mkOption {
            type = lib.types.port;
            default = 9187;
            description = "Port Vector should expect the local postgres exporter to listen on.";
          };
        };
      };
      default = {};
      description = "Local postgres exporter integration.";
    };

    natsExporter = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether Vector should auto-scrape the local NATS exporter.";
          };
          listenAddress = lib.mkOption {
            type = lib.types.str;
            default = "127.0.0.1";
            description = "Address Vector should use when scraping the local NATS exporter.";
          };
          port = lib.mkOption {
            type = lib.types.port;
            default = 7777;
            description = "Port Vector should expect the local NATS exporter to listen on.";
          };
        };
      };
      default = {};
      description = "Local NATS exporter integration.";
    };

    enableDefaults = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable opinionated defaults: node/hwmon/process/self metrics, OTLP reception, default hwmon chip include regex.";
    };

    hostLabel = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = "Stable host label attached to emitted telemetry. Defaults to the host's `networking.hostName`.";
    };

    hub = lib.mkOption {
      type = lib.types.submodule {
        options = {
          logsAddress = lib.mkOption {
            type = lib.types.str;
            description = "Address of the central Vector hub log ingress.";
          };

          metricsAddress = lib.mkOption {
            type = lib.types.str;
            description = "Address of the central Vector hub metrics ingress.";
          };

          tracesAddress = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Address of the central Vector hub traces ingress used when OTLP reception is enabled.";
          };

          tls = lib.mkOption {
            type = lib.types.submodule {
              options = {
                enable = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "Whether Vector should use mTLS when talking to the central Vector hub.";
                };
                caCertPath = lib.mkOption {
                  type = lib.types.str;
                  default = "";
                  description = "Runtime path to the CA certificate used to verify the Vector hub server certificate.";
                };
                clientCertPath = lib.mkOption {
                  type = lib.types.str;
                  default = "";
                  description = "Runtime path to the client certificate the Vector agent presents to the hub.";
                };
                clientKeyPath = lib.mkOption {
                  type = lib.types.str;
                  default = "";
                  description = "Runtime path to the client key the Vector agent presents to the hub.";
                };
                serverName = lib.mkOption {
                  type = lib.types.str;
                  default = "";
                  description = "Optional TLS server-name override used for SNI and hostname verification when the hub is reached by IP.";
                };
                verifyHostname = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = "Whether Vector should verify that the hub server certificate matches the requested hostname or configured `serverName`.";
                };
              };
            };
            default = {};
            description = "TLS configuration for the central Vector hub connection.";
          };
        };
      };
      default = {};
      description = "Central Vector hub routing and TLS configuration.";
    };

    extraMetricsScrapes = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "Unique Vector source label for this scrape job.";
          };
          jobName = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Prometheus `job` label for the scrape. Defaults to `name`.";
          };
          targets = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "Static `<host>:<port>` targets for this scrape job.";
          };
          metricsPath = lib.mkOption {
            type = lib.types.str;
            default = "/metrics";
            description = "HTTP path to scrape from each target.";
          };
          scheme = lib.mkOption {
            type = lib.types.str;
            default = "http";
            description = "URL scheme used when scraping each target.";
          };
          scrapeInterval = lib.mkOption {
            type = lib.types.str;
            default = "15s";
            description = "Scrape interval for this target set (e.g. `15s`).";
          };
          labels = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = {};
            description = "Extra static labels attached to scraped samples.";
          };
          tls = lib.mkOption {
            type = lib.types.submodule {
              options = {
                enable = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "Whether Vector should use TLS when scraping this metrics endpoint.";
                };
                caCertPath = lib.mkOption {
                  type = lib.types.str;
                  default = "";
                  description = "Optional CA certificate path used to verify the scraped endpoint.";
                };
                clientCertPath = lib.mkOption {
                  type = lib.types.str;
                  default = "";
                  description = "Optional client certificate path for future mTLS-protected scrape targets.";
                };
                clientKeyPath = lib.mkOption {
                  type = lib.types.str;
                  default = "";
                  description = "Optional client key path for future mTLS-protected scrape targets.";
                };
                serverName = lib.mkOption {
                  type = lib.types.str;
                  default = "";
                  description = "Optional TLS server-name override used for SNI and hostname verification when scraping by IP.";
                };
                verifyHostname = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = "Whether Vector should verify that the scraped endpoint certificate matches the requested hostname or configured `serverName`.";
                };
              };
            };
            default = {};
            description = "Optional TLS settings for this scrape target.";
          };
        };
      });
      default = [];
      description = "Additional Prometheus scrape jobs Vector should collect and send to the central hub.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      description = "System user that runs Vector. Must exist on the host.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      description = "Group for the Vector service.";
    };

    enableNodeMetrics = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to run node_exporter on 127.0.0.1 and have Vector scrape it.";
    };

    enableNodeHwmon = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to enable the node_exporter `hwmon` collector.";
    };

    nodeHwmonChipInclude = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional regex passed via `--collector.hwmon.chip-include` to restrict the `hwmon` collector to stable chip names.";
    };

    enableProcessMetrics = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to run process-exporter on 127.0.0.1 and have Vector scrape it.";
    };

    enableSelfMetrics = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether Vector should expose its own internal metrics through `internal_metrics`.";
    };

    enableOtlp = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to accept OTLP traffic on 127.0.0.1:4317/4318 and forward it to the central Vector hub.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (lib.mkIf cfg.enableDefaults {
        services.vector-agent = {
          enableNodeMetrics = lib.mkDefault true;
          enableNodeHwmon = lib.mkDefault true;
          nodeHwmonChipInclude = lib.mkDefault "^(nvme|amdgpu|acpitz|k10temp)$";
          enableProcessMetrics = lib.mkDefault true;
          enableSelfMetrics = lib.mkDefault true;
          enableOtlp = lib.mkDefault true;
        };
      })
      (lib.mkIf cfg.enableNodeMetrics {
        services.prometheus.exporters.node = {
          enable = true;
          listenAddress = "127.0.0.1";
          port = nodeExporterPort;
          disabledCollectors =
            lib.optional (!cfg.enableNodeHwmon) "hwmon"
            ++ lib.optionals config.boot.isContainer [
              "bonding"
              "fibrechannel"
              "infiniband"
              "ipvs"
              "mdadm"
              "nfs"
              "nfsd"
              "rapl"
              "tapestats"
              "zfs"
            ];
          extraFlags =
            (lib.optional
              (cfg.enableNodeHwmon && cfg.nodeHwmonChipInclude != null)
              "--collector.hwmon.chip-include=${cfg.nodeHwmonChipInclude}")
            ++ lib.optional config.boot.isContainer
            "--collector.filesystem.mount-points-exclude=^/(dev|proc|run/credentials/.+|run/user/.+|sys|var/lib/docker/.+|var/lib/containers/storage/.+|var/lib/lxcfs)($|/)";
        };
      })
      (lib.mkIf cfg.enableProcessMetrics {
        services.prometheus.exporters.process = {
          enable = true;
          listenAddress = "127.0.0.1";
          port = processExporterPort;
          user = "root";
          group = "root";
          extraFlags = [
            "-recheck"
            "-remove-empty-groups"
          ];
          settings.process_names = [
            {
              name = "{{.ExeBase}}";
              cmdline = [".+"];
            }
          ];
        };

        systemd.services.prometheus-process-exporter.serviceConfig.CapabilityBoundingSet = [
          # Required for /proc/<pid> details owned by other users.
          "CAP_DAC_READ_SEARCH"
          "CAP_SYS_PTRACE"
        ];
      })
      {
        services.vector = {
          enable = true;
          journaldAccess = true;
          settings = vectorSettings;
        };

        systemd.services.vector.serviceConfig = {
          DynamicUser = lib.mkForce false;
          User = lib.mkForce cfg.user;
          Group = lib.mkForce cfg.group;
          StateDirectory = lib.mkForce "vector";
          ReadWritePaths = ["/var/lib/vector"];
        };

        assertions = [
          {
            assertion = hub.logsAddress != "";
            message = "services.vector-agent.hub.logsAddress must be set.";
          }
          {
            assertion = hub.metricsAddress != "";
            message = "services.vector-agent.hub.metricsAddress must be set.";
          }
          {
            assertion = !cfg.enableOtlp || hub.tracesAddress != "";
            message = "services.vector-agent.hub.tracesAddress must be set when services.vector-agent.enableOtlp = true.";
          }
          {
            assertion = hubTls.enable;
            message = "services.vector-agent.hub.tls.enable must be true for the central Vector hub transport.";
          }
          {
            assertion = !hubTls.enable || hubTls.caCertPath != "";
            message = "services.vector-agent.hub.tls.caCertPath must be set when services.vector-agent.hub.tls.enable = true.";
          }
          {
            assertion = !hubTls.enable || hubTls.clientCertPath != "";
            message = "services.vector-agent.hub.tls.clientCertPath must be set when services.vector-agent.hub.tls.enable = true.";
          }
          {
            assertion = !hubTls.enable || hubTls.clientKeyPath != "";
            message = "services.vector-agent.hub.tls.clientKeyPath must be set when services.vector-agent.hub.tls.enable = true.";
          }
        ];
      }
    ]
  );
}
