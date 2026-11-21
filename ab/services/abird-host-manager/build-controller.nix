{
  config,
  lib,
  pkgs,
  specialArgs,
  ...
}: let
  manager = config.services.abird-host-manager;
  cfg = manager.buildController;
  executor = config.services.abird-host-agent.buildExecutor;
  local = executor.enable;
  absolute = value:
    builtins.match "/[a-zA-Z0-9_./-]+" value
    != null
    && !(lib.elem ".." (lib.splitString "/" value));
  identifier = value:
    builtins.match "[a-zA-Z0-9_.-]+" value
    != null
    && builtins.stringLength value <= 128
    && !(lib.elem value ["." ".."]);
  accounts = lib.unique (lib.attrNames cfg.callerBootstraps ++ lib.attrNames cfg.controllerStateHomes);
  account = name: config.users.users.${name};
  remoteCallers = lib.filterAttrs (_: caller: !local && caller.sourceRoots != []) cfg.callers;
  bootstraps = lib.mapAttrs (name: caller:
    pkgs.writeText "abird-owned-fleet-${name}.json" (builtins.toJSON {
      version = 1;
      uid = (account name).uid;
      controller = {
        host_id = cfg.hostId;
        fabric_id = cfg.fabricId;
      };
      repository_id = caller.repositoryId;
      inventory = cfg.inventory;
      known_hosts_file = caller.knownHostsFile;
      credentials = caller.credentials;
      nix =
        {substitute = caller.nix.substitute;}
        // lib.optionalAttrs (caller.nix.maxJobs != null) {max_jobs = caller.nix.maxJobs;}
        // lib.optionalAttrs (caller.nix.cores != null) {cores = caller.nix.cores;};
      local_control = local;
      controller_service = false;
      state_home = caller.stateHome;
    }))
  cfg.callers;
in {
  imports = [./capture.nix];
  options.services.abird-host-manager.buildController = {
    enable = lib.mkEnableOption "the owned fleet caller profile (no executor or deployment enablement)";
    inventory = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = specialArgs.repository.inventory or {};
      defaultText = lib.literalExpression "repository.inventory or {}";
      description = "Trusted deployment inventory for bootstrap routing only; source selection/evaluation remains admitted. Reuses the repository inventory supplied to NixOS.";
    };
    hostId = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = "Stable caller host identity; must name the local inventory host for a colocated executor.";
    };
    fabricId = lib.mkOption {
      type = lib.types.str;
      default = "fleet";
      description = "Caller/build request namespace; not an authentication or routing grant.";
    };
    callers = lib.mkOption {
      default = {};
      description = "Typed profiles for existing accounts. Generate immutable bootstraps and matching local-controller or remote-capture bindings; never grant builder admission.";
      type = lib.types.attrsOf (lib.types.submodule ({name, ...}: {
        options = {
          repositoryId = lib.mkOption {
            type = lib.types.str;
            description = "Repository identity approved by the builder's installed policy.";
          };
          stateHome = lib.mkOption {
            type = lib.types.str;
            default = "${(account name).home}/.local/state";
            defaultText = "the declared account's home + /.local/state";
            description = "Original absolute XDG state base; must match the caller environment.";
          };
          sourceRoots = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Explicit allowed local source roots. Empty supports configured-repository CI only, not arbitrary local checkout capture.";
          };
          knownHostsFile = lib.mkOption {
            type = lib.types.str;
            default = "/etc/ssh/ssh_known_hosts";
            description = "Existing root-controlled SSH trust file; no TOFU or generated trust.";
          };
          credentials = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = {};
            description = "Inventory credential reference to existing absolute runtime path; never secret contents.";
          };
          nix = {
            maxJobs = lib.mkOption {
              type = lib.types.nullOr (lib.types.ints.between 1 65535);
              default = null;
              description = "Requested Nix job ceiling; null uses the authenticated builder policy at admission.";
            };
            cores = lib.mkOption {
              type = lib.types.nullOr (lib.types.ints.between 1 65535);
              default = null;
              description = "Requested per-job core ceiling; null uses the authenticated builder policy at admission.";
            };
            substitute = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Allow ordinary signature-checked Nix substitution.";
            };
          };
        };
      }));
    };
    callerBootstraps = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = {};
      internal = true;
      description = "Generated immutable bootstrap JSON; explicit legacy declarations remain supported. Prefer callers.";
    };
    controllerStateHomes = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      internal = true;
      description = "Local controller accounts and consumer/capture authority, keyed by account with absolute XDG state bases. Does not enable detached observers.";
    };
    captureRoots = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = {};
      internal = true;
      description = "Generated local-controller source allowances; no whole-home or implicit repository grant.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.abird-host-manager.buildController = {
      callerBootstraps = bootstraps;
      controllerStateHomes = lib.optionalAttrs local (lib.mapAttrs (_: caller: caller.stateHome) cfg.callers);
      captureRoots = lib.optionalAttrs local (lib.mapAttrs (_: caller: caller.sourceRoots) cfg.callers);
      capture = {
        enable = lib.mkDefault (remoteCallers != {});
        callers =
          lib.mapAttrs (_: caller: {
            stateHome = caller.stateHome;
            roots = caller.sourceRoots;
          })
          remoteCallers;
      };
    };
    assertions = [
      {
        # Bootstrap accounts receive consumer roots, including caller-only hosts.
        # Empty routing profiles and ordinary CI forwarding need no adapter.
        assertion =
          cfg.callerBootstraps
          == {}
          || (
            (manager.package.buildNativeAdapter or null)
            != null
            && (manager.package.buildNativeAdapter.version or null) == "3"
            && (manager.package.buildNativeNix.version or null) == "2.34.9"
            && toString (manager.package.buildNativeNix or "") == toString config.nix.package
          );
        message = "Agent-managed fleet consumers require the manager ABI3 adapter built against this exact config.nix.package (Nix 2.34.9).";
      }
      {
        assertion = lib.all (name:
          builtins.hasAttr name config.users.users
          && builtins.isInt (account name).uid
          && (account name).uid > 0)
        accounts;
        message = "Agent-managed fleet caller metadata requires existing nonroot account UIDs.";
      }
      {
        assertion = cfg.callers == {} || (identifier cfg.hostId && identifier cfg.fabricId && builtins.isAttrs (cfg.inventory.hosts or null) && cfg.inventory.hosts != {} && (!local || builtins.hasAttr cfg.hostId cfg.inventory.hosts));
        message = "Generated fleet callers require valid host/fabric identities and trusted inventory; local control must name its inventory host.";
      }
      {
        assertion = lib.all (name: let
          caller = cfg.callers.${name};
        in
          identifier caller.repositoryId
          && cfg.callerBootstraps.${name} == bootstraps.${name}
          && absolute caller.stateHome
          && absolute caller.knownHostsFile
          && lib.all absolute (lib.attrValues caller.credentials)
          && builtins.length caller.sourceRoots <= 16
          && lib.all absolute caller.sourceRoots
          && (!local || (builtins.hasAttr name executor.principals && builtins.hasAttr caller.repositoryId executor.repositories)))
        (lib.attrNames cfg.callers);
        message = "Generated fleet callers require bounded absolute source/state/trust paths and, when colocated, an existing principal and approved repository.";
      }
      {
        assertion = lib.all (name: let
          caller = cfg.callers.${name};
        in
          if local
          then cfg.controllerStateHomes.${name} == caller.stateHome && cfg.captureRoots.${name} == caller.sourceRoots
          else caller.sourceRoots == [] || (cfg.capture.enable && cfg.capture.callers.${name}.stateHome == caller.stateHome && cfg.capture.callers.${name}.roots == caller.sourceRoots))
        (lib.attrNames cfg.callers);
        message = "Generated fleet caller state/source authority must match its capture/controller binding.";
      }
      {
        assertion =
          lib.all (name: lib.hasPrefix "/nix/store/" (toString cfg.callerBootstraps.${name}))
          (lib.attrNames cfg.callerBootstraps);
        message = "Agent-managed fleet bootstrap must be immutable metadata; never private key contents.";
      }
      {
        assertion = cfg.controllerStateHomes == {} || local;
        message = "Agent-managed local controllers require the colocated agent buildExecutor profile; caller-only routing does not.";
      }
      {
        assertion =
          builtins.length (lib.unique (map (name: (account name).uid) accounts))
          == builtins.length accounts;
        message = "Agent-managed fleet caller accounts must not alias kernel UIDs.";
      }
      {
        assertion = lib.all absolute (lib.attrValues cfg.controllerStateHomes);
        message = "Agent-managed controller state bases must be absolute and nontraversing.";
      }
      {
        assertion =
          lib.all (name: builtins.hasAttr name cfg.controllerStateHomes)
          (lib.attrNames cfg.captureRoots);
        message = "Agent-managed capture roots require a declared local controller account.";
      }
    ];
    environment.systemPackages = [manager.package];
    environment.etc = lib.mapAttrs' (name: source:
      lib.nameValuePair "abird-owned-fleet/${toString (account name).uid}.json" {source = source;})
    cfg.callerBootstraps;
    # Direct consumer roots: one private leaf per declared nonroot account.
    systemd.tmpfiles.rules = lib.optionals (cfg.callerBootstraps != {}) (
      ["d /nix/var/nix/gcroots/abird-owned-fleet 0755 root root -"]
      ++ map (name: "d /nix/var/nix/gcroots/abird-owned-fleet/${toString (account name).uid} 0700 ${name} ${(account name).group} -")
      (lib.attrNames cfg.callerBootstraps)
    );
  };
}
