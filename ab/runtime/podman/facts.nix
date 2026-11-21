{lib}: let
  portFacts = exposedPorts:
    lib.mapAttrsToList (
      name: cfg: {
        inherit name;
        port = cfg.port;
        protocols = cfg.protocols or ["tcp"];
      }
    )
    exposedPorts;

  namesOf = entries: map (entry: entry.name) entries;
in {
  version = 2;

  service = {
    name,
    backend,
    user,
    userUid ? null,
    userHome ? null,
    podmanSocket ? null,
    workingDir,
    exposedPorts ? {},
    hardDependencies ? [],
    softDependencies ? [],
    topologyDependencies ? [],
    primaryUnit,
    readyUnit,
    managedUnit,
    auxiliaryServices ? [],
    auxiliaryTargets ? [],
    gatedUnits ? [],
    containers ? [],
    declaredImages ? [],
    localImages ? {},
    filePaths ? {},
    dirPaths ? {},
    envSecretPaths ? {},
    fileSecretPaths ? {},
    desiredState,
    reconcilePolicy,
    removalPolicy,
    adopt,
    autoStart,
    startConcurrency,
    startPriority,
    longRunning,
    waitForNetwork,
    timeoutReadySeconds,
    timeoutBootstrapSeconds,
    verifyCommand ? [],
    subnet ? null,
    dataPaths ? [],
  }: {
    version = 2;
    inherit
      name
      backend
      user
      workingDir
      ;

    ports = portFacts exposedPorts;

    dependencies = {
      hard = hardDependencies;
      soft = softDependencies;
      topologyServices = topologyDependencies;
    };

    units = {
      primary = primaryUnit;
      ready = readyUnit;
      managed = managedUnit;
      auxiliaryServices = namesOf auxiliaryServices;
      auxiliaryTargets = namesOf auxiliaryTargets;
      gated = gatedUnits;
    };

    inherit containers;

    images = {
      declared = declaredImages;
      local = localImages;
    };

    paths = {
      files = filePaths;
      directories = dirPaths;
      secrets = {
        environment = envSecretPaths;
        files = fileSecretPaths;
      };
    };

    lifecycle = {
      state = desiredState;
      inherit
        reconcilePolicy
        removalPolicy
        adopt
        autoStart
        startConcurrency
        startPriority
        longRunning
        waitForNetwork
        ;
    };

    readiness = {
      unit = readyUnit;
      timeoutSeconds = timeoutReadySeconds;
      bootstrapTimeoutSeconds = timeoutBootstrapSeconds;
      inherit verifyCommand;
    };

    resources = {
      identity = {
        name = user;
        uid = userUid;
        home = userHome;
        rootless = user != "root";
      };

      storage = {
        workingDirectory = workingDir;
        inherit dataPaths;
      };

      network =
        {
          ports = portFacts exposedPorts;
        }
        // lib.optionalAttrs (subnet != null) {
          inherit subnet;
        };

      control = {
        socket = podmanSocket;
      };
    };
  };
}
