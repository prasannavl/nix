{pkgs}: let
  lib = pkgs.lib;
  declaration = pkgs.writeText "owned-control-test-declaration.json" "{}";
  trustedInventory = {
    hosts = {
      caller = {
        target = "caller.example";
        user = "operator";
      };
      builder = {
        target = "builder.example";
        user = "operator";
      };
    };
    config = {
      controller = "caller";
      transferBroker = "caller";
      builders = ["builder"];
    };
  };
  evaluateWith = extraModules: settings:
    (import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = pkgs.stdenv.hostPlatform.system;
      pkgs = pkgs;
      specialArgs.repository.inventory = trustedInventory;
      modules =
        [
          ../services/abird-host-agent
          {
            boot.loader.grub.devices = ["nodev"];
            fileSystems."/" = {
              device = "none";
              fsType = "tmpfs";
            };
            system.stateVersion = "26.05";
            services.abird-host-agent.buildExecutor.control = settings;
          }
        ]
        ++ extraModules;
    }).config;
  evaluate = evaluateWith [];
  executorDisabled = evaluateWith [] {};
  executorExplicit = evaluateWith [
    {nix.package = pkgs.nixVersions.nix_2_34;}
  ] {};
  explicit = {
    enable = true;
    declarationFile = declaration;
    maxConnections = 4;
    connectionLifetimeSeconds = 15;
  };
  disabled = evaluate {};
  enabled = evaluate explicit;
  moved = evaluate (explicit // {xdgStateHome = "/srv/state";});
  relative = evaluate (explicit // {xdgStateHome = "relative";});
  missingConnections = evaluate (builtins.removeAttrs explicit ["maxConnections"]);
  missingLifetime = evaluate (builtins.removeAttrs explicit ["connectionLifetimeSeconds"]);
  callerOnly = evaluateWith [
    {
      users.groups.operator.gid = 1100;
      users.users.operator = {
        isNormalUser = true;
        uid = 1100;
        group = "operator";
      };
      services.abird-host-manager.buildController = {
        enable = true;
        callerBootstraps.operator = declaration;
      };
    }
  ] {};
  profile = {
    networking.hostName = "caller";
    users.groups.operator.gid = 1100;
    users.users.operator = {
      isNormalUser = true;
      uid = 1100;
      group = "operator";
      home = "/home/operator";
    };
    services.abird-host-manager.buildController = {
      enable = true;
      callers.operator.repositoryId = "repo";
    };
  };
  captureProfile = {
    services.abird-host-manager.buildController = {
      callers.operator.sourceRoots = ["/home/operator/repo"];
      capture = {
        relayUser = "source-relay";
        relayKeyFile = "/run/keys/source-relay";
        memoryMax = 536870912;
        tasksMax = 128;
        cpuPercent = 100;
        maxSeconds = 600;
        sourceLimits = {
          entries = 32768;
          bytes = 67108864;
          depth = 64;
        };
      };
    };
  };
  generated = evaluateWith [profile] {};
  generatedCapture = evaluateWith [profile captureProfile] {};
  withoutAdapter = {
    services.abird-host-manager.package = pkgs.abird-host-manager // {buildNativeAdapter = null;};
  };
  missingConsumerAdapter = evaluateWith [profile withoutAdapter] {};
  legacyMissingAdapter = evaluateWith [
    profile
    withoutAdapter
    {
      services.abird-host-manager.buildController = {
        callers = lib.mkForce {};
        callerBootstraps.operator = declaration;
      };
    }
  ] {};
  missingCaptureAdapter = evaluateWith [profile captureProfile withoutAdapter] {};
  foreignConsumerNix = evaluateWith [
    profile
    {
      services.abird-host-manager.package =
        pkgs.abird-host-manager
        // {
          buildNativeNix = pkgs.nix.overrideAttrs (_: {pname = "foreign-consumer-nix";});
        };
    }
  ] {};
  wrongConsumerAbi = evaluateWith [
    profile
    {
      services.abird-host-manager.package =
        pkgs.abird-host-manager
        // {
          buildNativeAdapter = pkgs.abird-host-manager.buildNativeAdapter // {version = "2";};
        };
    }
  ] {};
  wrongConsumerVersion = evaluateWith [
    profile
    {
      services.abird-host-manager.package =
        pkgs.abird-host-manager
        // {
          buildNativeNix = pkgs.nix // {version = "2.34.10";};
        };
    }
  ] {};
  disabledWithoutAdapter = evaluateWith [profile withoutAdapter {services.abird-host-manager.buildController.enable = lib.mkForce false;}] {};
  routingWithoutAdapter = evaluateWith [profile withoutAdapter {services.abird-host-manager.buildController.callers = lib.mkForce {};}] {};
  generatedDisabled = evaluateWith [profile {services.abird-host-manager.buildController.enable = lib.mkForce false;}] {};
  generatedMoved = evaluateWith [profile {services.abird-host-manager.buildController.callers.operator.stateHome = "/srv/operator-state";}] {};
  invalidInventory = evaluateWith [profile {services.abird-host-manager.buildController.inventory = {};}] {};
  invalidRepository = evaluateWith [profile {services.abird-host-manager.buildController.callers.operator.repositoryId = lib.mkForce "..";}] {};
  invalidSource = evaluateWith [profile captureProfile {services.abird-host-manager.buildController.callers.operator.sourceRoots = lib.mkForce ["relative/source"];}] {};
  mismatchedCapture = evaluateWith [profile captureProfile {services.abird-host-manager.buildController.capture.callers.operator.stateHome = lib.mkForce "/srv/foreign-state";}] {};
  disabledCapture = evaluateWith [profile captureProfile {services.abird-host-manager.buildController.capture.enable = false;}] {};
  replacedBootstrap = evaluateWith [profile {services.abird-host-manager.buildController.callerBootstraps.operator = lib.mkForce declaration;}] {};
  generatedOptions = evaluateWith [
    profile
    {
      services.abird-host-manager.buildController.callers.operator.nix = {
        maxJobs = 2;
        cores = 3;
        substitute = false;
      };
    }
  ] {};
  declaredPrincipals = evaluateWith [
    profile
    {
      users.users.source-relay = {
        isNormalUser = true;
        uid = 1201;
      };
      services.abird-host-agent.buildExecutor = {
        principals.operator = {};
        inputPrincipals.source-relay.issuer = "operator";
      };
    }
  ] {};
  bootstrapValue = value: builtins.fromJSON value.services.abird-host-manager.buildController.callerBootstraps.operator.text;
  generatedValue = bootstrapValue generated;
  valid = value: lib.all (entry: entry.assertion) value.assertions;
  customAgent = pkgs.abird-host-agent.overrideAttrs (_: {pname = "executor-profile-agent";});
  inheritedPackage = evaluateWith [{services.abird-host-agent.package = customAgent;}] explicit;
  service = enabled.systemd.services."abird-owned-build-control@";
  socket = enabled.systemd.sockets.abird-owned-build-control.socketConfig;
in
  assert !(disabled.services ? abird-owned-builder);
  assert !(disabled.services ? abird-owned-build-control);
  assert !disabled.services.abird-host-agent.enable;
  assert !disabled.services.abird-host-manager.enable;
  assert !disabled.services.abird-host-manager.buildController.enable;
  assert !callerOnly.services.abird-host-manager.enable;
  assert !callerOnly.services.abird-host-agent.buildExecutor.enable;
  assert !(callerOnly.systemd.services ? abird-owned-build-supervisor);
  assert !(callerOnly.systemd.sockets ? abird-owned-build-control);
  assert !(callerOnly.environment.etc ? "abird-owned-build/role.json");
  assert callerOnly.environment.etc."abird-owned-fleet/1100.json".source == declaration;
  assert lib.elem pkgs.abird-host-manager callerOnly.environment.systemPackages;
  assert lib.all (entry: entry.assertion) callerOnly.assertions;
  assert valid generated && valid generatedCapture && valid generatedDisabled && valid generatedMoved && valid generatedOptions;
  assert !(valid missingConsumerAdapter) && !(valid missingCaptureAdapter) && !(valid legacyMissingAdapter);
  assert !(valid foreignConsumerNix) && !(valid wrongConsumerAbi) && !(valid wrongConsumerVersion);
  assert valid disabledWithoutAdapter && valid routingWithoutAdapter;
  assert !generated.services.abird-host-agent.buildExecutor.enable;
  assert generated.nix.package.drvPath == disabled.nix.package.drvPath;
  assert !(valid invalidInventory) && !(valid invalidRepository) && !(valid invalidSource);
  assert !(valid mismatchedCapture) && !(valid disabledCapture) && !(valid replacedBootstrap);
  assert generatedValue
  == {
    version = 1;
    uid = 1100;
    controller = {
      host_id = "caller";
      fabric_id = "fleet";
    };
    repository_id = "repo";
    inventory = trustedInventory;
    known_hosts_file = "/etc/ssh/ssh_known_hosts";
    credentials = {};
    nix.substitute = true;
    local_control = false;
    controller_service = false;
    state_home = "/home/operator/.local/state";
  };
  assert (bootstrapValue generatedMoved).state_home == "/srv/operator-state";
  assert (bootstrapValue generatedOptions).nix
  == {
    max_jobs = 2;
    cores = 3;
    substitute = false;
  };
  assert generated.services.abird-host-manager.buildController.controllerStateHomes == {};
  assert !generated.services.abird-host-manager.buildController.capture.enable;
  assert !generated.services.abird-host-agent.buildExecutor.enable;
  assert !(generated.systemd.services ? abird-owned-build-supervisor);
  assert !(generated.systemd.sockets ? abird-owned-build-control);
  assert !(generatedDisabled.environment.etc ? "abird-owned-fleet/1100.json");
  assert generatedDisabled.services.abird-host-manager.buildController.callerBootstraps == {};
  assert !(generatedDisabled.systemd.sockets ? abird-owned-capture-control);
  assert generatedCapture.services.abird-host-manager.buildController.capture.enable;
  assert generatedCapture.services.abird-host-manager.buildController.capture.callers.operator
  == {
    stateHome = "/home/operator/.local/state";
    roots = ["/home/operator/repo"];
  };
  assert generatedCapture.systemd.sockets ? abird-owned-capture-control;
  assert !generatedCapture.services.abird-host-agent.buildExecutor.enable;
  assert declaredPrincipals.services.abird-host-agent.buildExecutor.principals.operator
  == {
    uid = 1100;
    issuer = "operator";
  };
  assert declaredPrincipals.services.abird-host-agent.buildExecutor.inputPrincipals.source-relay
  == {
    uid = 1201;
    issuer = "operator";
  };
  assert lib.hasPrefix "${customAgent}/bin/abird-host-agent _owned-control "
  inheritedPackage.systemd.services."abird-owned-build-control@".serviceConfig.ExecStart;
  assert !executorDisabled.services.abird-host-agent.buildExecutor.enable;
  assert !executorDisabled.services.abird-host-agent.buildExecutor.acceptSubmissions;
  assert !(executorDisabled.systemd.services ? abird-owned-build-supervisor);
  assert !(executorDisabled.environment.etc ? "abird-owned-build/daemon.json");
  assert !(executorDisabled.users.users ? abird-owned-builder);
  assert executorDisabled.nix.package.drvPath == disabled.nix.package.drvPath;
  assert !(executorDisabled.services.abird-host-agent.buildExecutor ? nativePackage);
  assert executorExplicit.nix.package.drvPath == pkgs.nixVersions.nix_2_34.drvPath;
  assert !(executorExplicit.systemd.services ? abird-owned-build-supervisor);
  assert !disabled.services.abird-host-agent.buildExecutor.control.enable;
  assert !(disabled.systemd.sockets ? abird-owned-build-control);
  assert !(disabled.systemd.services ? "abird-owned-build-control@");
  assert !(disabled.users.groups ? abird-owned-control);
  assert !(lib.elem pkgs.abird-host-agent disabled.environment.systemPackages);
  assert lib.elem pkgs.abird-host-agent enabled.environment.systemPackages;
  assert lib.all (entry: entry.assertion) enabled.assertions;
  assert !(lib.all (entry: entry.assertion) relative.assertions);
  assert !(builtins.tryEval missingConnections.systemd.sockets.abird-owned-build-control.socketConfig.MaxConnections).success;
  assert !(builtins.tryEval missingLifetime.systemd.services."abird-owned-build-control@".serviceConfig.RuntimeMaxSec).success;
  assert socket.Accept && socket.MaxConnections == 4 && socket.Backlog == 4;
  assert socket.SocketMode == "0660" && socket.SocketGroup == "abird-owned-control";
  assert socket.ListenStream == "/run/abird/abird-host-agent/owned-build/control.sock";
  assert service.serviceConfig.User == "root" && service.serviceConfig.Slice == "system.slice";
  assert service.serviceConfig.StandardInput == "socket";
  assert service.serviceConfig.StandardOutput == "journal";
  assert service.serviceConfig.Restart == "no" && service.serviceConfig.RuntimeMaxSec == 15;
  assert service.serviceConfig.NoNewPrivileges && service.serviceConfig.ProtectSystem == "strict";
  assert service.serviceConfig.LimitCORE == 0;
  assert !(service.serviceConfig ? StateDirectory);
  assert lib.hasPrefix "${pkgs.abird-host-agent}/bin/abird-host-agent _owned-control --config " service.serviceConfig.ExecStart;
  assert service.environment.XDG_STATE_HOME == "/var/lib";
  assert service.serviceConfig.ReadWritePaths == ["-/var/lib/abird/abird-host-agent/owned-build"];
  assert moved.systemd.services."abird-owned-build-control@".serviceConfig.ReadWritePaths == ["-/srv/state/abird/abird-host-agent/owned-build"];
    pkgs.runCommand "build-executor-control-module-test" {} ''
      test -x ${pkgs.abird-host-manager}/libexec/abird-host-manager
      test -x ${pkgs.abird-host-manager}/bin/abird-host-manager
      for mode in capture source request prepare controller; do
        test ! -e ${pkgs.abird-host-manager}/bin/abird-owned-$mode
      done
      # Same fixed failure through both entrypaths; no caller/public rendering.
      for entry in bin libexec; do
        if ${pkgs.abird-host-manager}/$entry/abird-host-manager \
          _owned-source invalid /private-marker >stdout 2>stderr; then
          exit 1
        fi
        test ! -s stdout
        printf 'owned source operation failed\n' >expected
        cmp expected stderr
        # Canonical controller name and compatibility alias are read-only help.
        ${pkgs.abird-host-manager}/$entry/abird-host-manager \
          fleet build-controller help >controller-help
        ${pkgs.abird-host-manager}/$entry/abird-host-manager \
          fleet owned help >alias-help
        cmp controller-help alias-help
        grep -F 'fleet build-controller submit' controller-help
      done
      touch "$out"
    ''
