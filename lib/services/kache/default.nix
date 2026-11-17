# kache service: systemd user daemon plus a declarative config.toml. The package
# is lib/ext/kache; this module replaces upstream's so no flake input is pulled
# in for ~50 lines of wiring.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.kache;
  configFile = (pkgs.formats.toml {}).generate "kache-config" cfg.settings;
  exe = lib.getExe cfg.package;
in {
  options.services.kache = {
    enable = lib.mkEnableOption "the kache compiler cache";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.kache;
      defaultText = lib.literalExpression "pkgs.kache";
      description = "kache package to install and run.";
    };

    rustcWrapper = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Set `RUSTC_WRAPPER` system-wide. Reaches login shells and `nix develop`;
        sandboxed builds derive their own environment.
      '';
    };

    daemon = {
      enable = lib.mkEnableOption "the kache background daemon";
      logLevel = lib.mkOption {
        type = lib.types.str;
        default = "kache=info";
      };
    };

    # Freeform so new upstream keys need no module change. Freeze the type with
    # `nix eval` before widening the option surface.
    settings = lib.mkOption {
      type = (pkgs.formats.toml {}).type;
      default = {};
      description = "Written verbatim to `/etc/kache/config.toml`.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      environment = {
        systemPackages = [cfg.package];
        etc."kache/config.toml".source = configFile;
        variables =
          {KACHE_CONFIG = "${configFile}";}
          // lib.optionalAttrs cfg.rustcWrapper {RUSTC_WRAPPER = exe;};
      };
    })
    (lib.mkIf (cfg.enable && cfg.daemon.enable) {
      systemd.user.services.kache = {
        description = "kache build cache daemon";
        wantedBy = ["default.target"];
        after = ["default.target"];
        serviceConfig = {
          Type = "simple";
          ExecStart = "${exe} daemon run";
          Restart = "on-failure";
          RestartSec = "5s";
        };
        environment = {
          KACHE_LOG = cfg.daemon.logLevel;
          KACHE_CONFIG = "${configFile}";
        };
      };
    })
  ];
}
