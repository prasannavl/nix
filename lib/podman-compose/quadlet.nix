{
  lib,
  config,
  pkgs,
}: let
  systemdUtils = import (pkgs.path + "/nixos/lib/utils.nix") {inherit lib config pkgs;};
  backendLabel = "io.abird.podman-compose.backend";
  instanceLabel = "io.abird.podman-compose.instance";
  workingDirLabel = "io.abird.podman-compose.project-working-dir";
  serviceLabel = "io.abird.podman-compose.service";

  primitive = value:
    if builtins.isBool value
    then
      if value
      then "true"
      else "false"
    else toString value;

  isPrimitive = value:
    builtins.isString value
    || builtins.isInt value
    || builtins.isFloat value
    || builtins.isBool value;

  asList = value:
    if builtins.isList value
    then value
    else [value];

  escapeValue = value: let
    rendered = primitive value;
  in
    if builtins.length (lib.splitString "\n" rendered) != 1
    then throw "services.podman-compose: Quadlet values must not contain newlines"
    else lib.replaceStrings ["%" "$"] ["%%" "$$"] rendered;

  renderSection = name: entries:
    lib.optionalString (entries != []) (
      lib.concatStringsSep "\n" (
        ["[${name}]"]
        ++ map (
          entry: "${entry.key}=${
            if entry.preEscaped or false
            then entry.value
            else escapeValue entry.value
          }"
        )
        entries
      )
    );

  renderQuadlet = sections:
    lib.concatStringsSep "\n\n" (
      builtins.filter (section: section != "") (
        map (section: renderSection section.name section.entries) sections
      )
    )
    + "\n";

  normalizeAbsolutePath = path: let
    step = parts: part:
      if part == "" || part == "."
      then parts
      else if part == ".."
      then
        if parts == []
        then throw "services.podman-compose: relative Quadlet path escapes its working directory: ${path}"
        else lib.init parts
      else parts ++ [part];
    parts = builtins.foldl' step [] (lib.splitString "/" path);
  in "/${lib.concatStringsSep "/" parts}";

  resolveRuntimePath = workingDir: path:
    normalizeAbsolutePath (
      if lib.hasPrefix "/" path
      then path
      else "${workingDir}/${path}"
    );

  volumeInfo = workingDir: volume: let
    parts =
      if builtins.isString volume
      then lib.splitString ":" volume
      else [];
    source =
      if parts == []
      then ""
      else builtins.head parts;
    destination =
      if builtins.length parts < 2
      then ""
      else builtins.elemAt parts 1;
    bindSource = lib.hasPrefix "/" source || lib.hasPrefix "." source;
    resolvedSource =
      if bindSource
      then resolveRuntimePath workingDir source
      else source;
    suffix = lib.drop 2 parts;
    optionsSupported = builtins.all (option: builtins.elem option ["ro" "rw"]) (
      lib.concatMap (value: lib.splitString "," value) suffix
    );
  in {
    supported =
      builtins.isString volume
      && builtins.length parts >= 2
      && bindSource
      && lib.hasPrefix "/" destination
      && optionsSupported;
    rendered = lib.concatStringsSep ":" ([resolvedSource destination] ++ suffix);
  };

  userUid = user:
    if user == "root"
    then "0"
    else if builtins.hasAttr user config.users.users && config.users.users.${user}.uid != null
    then toString config.users.users.${user}.uid
    else throw "services.podman-compose: rootless stack user '${user}' must have a numeric uid";

  environmentEntries = environment:
    if builtins.isAttrs environment
    then
      lib.mapAttrsToList (name: value: {
        key = "Environment";
        value = lib.escapeShellArg "${name}=${primitive value}";
      })
      environment
    else
      map (value: {
        key = "Environment";
        value = lib.escapeShellArg value;
      })
      environment;

  commandValue = value:
    systemdUtils.escapeSystemdExecArgs (map primitive value);
in {
  labels = {
    backend = backendLabel;
    instance = instanceLabel;
    workingDir = workingDirLabel;
    service = serviceLabel;
  };

  mkConversion = {
    source,
    service,
    baseService,
    systemdServiceName,
    workingDir,
    envSecretRuntimePaths,
    envSecretTargetServices,
    fileSecretMountsForService,
    fileSecretTargetServices,
    trustedCaEnvironmentForService,
  }: let
    structured = builtins.isAttrs source && builtins.isAttrs (source.services or null);
    serviceNames =
      if structured
      then builtins.attrNames source.services
      else [];
    composeServiceName =
      if builtins.length serviceNames == 1
      then builtins.head serviceNames
      else null;
    rawComposeService =
      if composeServiceName == null
      then {}
      else source.services.${composeServiceName};
    composeService =
      if builtins.isAttrs rawComposeService
      then rawComposeService
      else {};
    supportedKeys = [
      "command"
      "container_name"
      "entrypoint"
      "environment"
      "env_file"
      "image"
      "ports"
      "restart"
      "user"
      "volumes"
      "working_dir"
    ];
    unsupportedTopLevel =
      if structured
      then lib.filter (name: name != "services") (builtins.attrNames source)
      else [];
    unsupportedServiceKeys =
      if builtins.isAttrs composeService
      then lib.filter (name: !(builtins.elem name supportedKeys)) (builtins.attrNames composeService)
      else [];
    ports = composeService.ports or [];
    sourceVolumesRaw = composeService.volumes or [];
    sourceVolumes =
      if builtins.isList sourceVolumesRaw
      then sourceVolumesRaw
      else [];
    secretVolumes =
      if composeServiceName == null
      then []
      else fileSecretMountsForService composeServiceName;
    volumes = sourceVolumes ++ secretVolumes;
    volumeInfos = map (volume: volumeInfo workingDir volume) volumes;
    environment = composeService.environment or {};
    environmentValuesSupported =
      if builtins.isAttrs environment
      then
        builtins.all (name: name != "" && builtins.match "[^=]+" name != null) (builtins.attrNames environment)
        && builtins.all isPrimitive (lib.attrValues environment)
      else
        builtins.isList environment
        && builtins.all (value: builtins.isString value && builtins.match "[^=]+=.*" value != null) environment;
    envFiles = asList (composeService.env_file or []);
    resolvedEnvFiles =
      map (path: resolveRuntimePath workingDir path) (builtins.filter builtins.isString envFiles)
      ++ lib.optional
      (composeServiceName != null && builtins.hasAttr composeServiceName envSecretRuntimePaths)
      envSecretRuntimePaths.${composeServiceName};
    restart = composeService.restart or "no";
    commandSupported = value:
      value == null || (builtins.isList value && builtins.all isPrimitive value);
    stringField = name:
      !(builtins.hasAttr name composeService) || builtins.isString composeService.${name};
    unmatchedEnvSecretTargets = lib.filter (name: name != composeServiceName) envSecretTargetServices;
    unmatchedFileSecretTargets = lib.filter (name: name != composeServiceName) fileSecretTargetServices;
    reasons =
      lib.optionals (!structured) ["source must be a structured attrset with a services attrset"]
      ++ lib.optionals (builtins.length serviceNames != 1) ["phase-1 Quadlet supports exactly one service"]
      ++ lib.optionals (!builtins.isAttrs rawComposeService) ["service must be an attrset"]
      ++ lib.optionals (unsupportedTopLevel != []) ["unsupported top-level keys: ${lib.concatStringsSep ", " unsupportedTopLevel}"]
      ++ lib.optionals (unsupportedServiceKeys != []) ["unsupported service keys: ${lib.concatStringsSep ", " unsupportedServiceKeys}"]
      ++ lib.optionals (!(builtins.isString (composeService.image or null) && composeService.image != "")) ["image must resolve to a nonempty string"]
      ++ lib.optionals (!(builtins.isList ports && builtins.all builtins.isString ports)) ["ports must use short string syntax"]
      ++ lib.optionals (!(builtins.isList sourceVolumesRaw && builtins.all (info: info.supported) volumeInfos)) ["volumes must be absolute or relative bind mounts; named and anonymous volumes are unsupported"]
      ++ lib.optionals (!environmentValuesSupported) ["environment must contain primitive values or KEY=VALUE strings"]
      ++ lib.optionals (!(builtins.all builtins.isString envFiles)) ["env_file must contain string paths"]
      ++ lib.optionals (!(commandSupported (composeService.command or null))) ["command must be a primitive argv list"]
      ++ lib.optionals (!(commandSupported (composeService.entrypoint or null))) ["entrypoint must be a primitive argv list"]
      ++ lib.optionals (!(stringField "container_name" && stringField "user" && stringField "working_dir")) ["container_name, user, and working_dir must be strings"]
      ++ lib.optionals (builtins.hasAttr "container_name" composeService && composeService.container_name == "") ["container_name must not be empty"]
      ++ lib.optionals (
        builtins.hasAttr "working_dir" composeService
        && builtins.isString composeService.working_dir
        && !lib.hasPrefix "/" composeService.working_dir
      ) ["working_dir must be absolute"]
      ++ lib.optionals (!(builtins.isString restart && builtins.elem restart ["no" "always" "unless-stopped" "on-failure"])) ["restart must be no, always, unless-stopped, or on-failure"]
      ++ lib.optionals (service.composeArgs != []) ["composeArgs are Compose-provider specific"]
      ++ lib.optionals (baseService.entryFile != null) ["entryFile is Compose-provider specific"]
      ++ lib.optionals (service.reload.method != "restart") ["signal reload is unsupported"]
      ++ lib.optionals (service.removalPolicy != "delete") ["phase-1 Quadlet requires removalPolicy = \"delete\""]
      ++ lib.optionals service.adopt ["adopt is unsupported for Quadlet"]
      ++ lib.optionals (service.subnet != null) ["custom networks and subnet are unsupported"]
      ++ lib.optionals (!service.longRunning) ["phase-1 Quadlet does not support one-shot/job containers (longRunning = false)"]
      ++ lib.optionals (unmatchedEnvSecretTargets != []) ["envSecrets target other services: ${lib.concatStringsSep ", " unmatchedEnvSecretTargets}"]
      ++ lib.optionals (unmatchedFileSecretTargets != []) ["mounted fileSecrets target other services: ${lib.concatStringsSep ", " unmatchedFileSecretTargets}"];
    trustedEnvironment =
      if composeServiceName == null
      then {}
      else trustedCaEnvironmentForService composeServiceName;
  in {
    supported = reasons == [];
    unsupported = reasons;
    service =
      if composeServiceName == null
      then null
      else {
        name = composeServiceName;
        image = composeService.image or null;
        containerName = composeService.container_name or "${systemdServiceName}-${composeServiceName}";
        command = composeService.command or null;
        entrypoint = composeService.entrypoint or null;
        user = composeService.user or null;
        workingDir = composeService.working_dir or null;
        ports = ports;
        volumes = map (info: info.rendered) volumeInfos;
        environment = environmentEntries environment ++ environmentEntries trustedEnvironment;
        envFiles = resolvedEnvFiles;
      };
  };

  mkArtifacts = {
    user,
    systemdServiceName,
    service,
    conversion,
  }: let
    native = conversion.service;
    containerBase = "${systemdServiceName}-container";
    containerFile = "${containerBase}.container";
    containerUnit = "${containerBase}.service";
    labels = {
      ${backendLabel} = "quadlet";
      ${instanceLabel} = systemdServiceName;
      ${workingDirLabel} = service.resolvedWorkingDir;
      ${serviceLabel} = native.name;
    };
    labelEntries =
      lib.mapAttrsToList (name: value: {
        key = "Label";
        value = "${name}=${value}";
      })
      labels;
    containerText = renderQuadlet [
      {
        name = "Unit";
        entries = [
          {
            key = "Description";
            value = "podman container: ${systemdServiceName}";
          }
        ];
      }
      {
        name = "Container";
        entries =
          [
            {
              key = "Image";
              value = native.image;
            }
            {
              key = "Pull";
              value = "never";
            }
            {
              key = "ContainerName";
              value = native.containerName;
            }
          ]
          ++ map (value: {
            key = "PublishPort";
            inherit value;
          })
          native.ports
          ++ map (value: {
            key = "Volume";
            inherit value;
          })
          native.volumes
          ++ native.environment
          ++ map (value: {
            key = "EnvironmentFile";
            inherit value;
          })
          native.envFiles
          ++ lib.optional (native.command != null) {
            key = "Exec";
            value = commandValue native.command;
            preEscaped = true;
          }
          ++ lib.optional (native.entrypoint != null) {
            key = "Entrypoint";
            value = builtins.toJSON (map primitive native.entrypoint);
          }
          ++ lib.optional (native.user != null) {
            key = "User";
            value = native.user;
          }
          ++ lib.optional (native.workingDir != null) {
            key = "WorkingDir";
            value = native.workingDir;
          }
          ++ labelEntries;
      }
      {
        name = "Service";
        entries = [
          {
            key = "Restart";
            value = "no";
          }
        ];
      }
    ];
    files = {${containerFile} = containerText;};
    etcDir = "containers/systemd/users/${userUid user}";
    sourcePath = "/etc/${etcDir}/${containerFile}";
    etcEntries =
      lib.mapAttrsToList (name: text: {
        name = "${etcDir}/${name}";
        value.text = text;
      })
      files;
    runtimeUnits = [containerUnit];
  in {
    inherit etcEntries files labels runtimeUnits sourcePath;
    containerName = native.containerName;
    containerUnit = containerUnit;
    networkUnit = null;
    metadata = {
      kind = "quadlet";
      quadlet = {
        inherit containerUnit runtimeUnits labels sourcePath;
        containerName = native.containerName;
      };
    };
    expectedContainers = [
      {
        name = native.name;
        owner = systemdServiceName;
        labels = labels;
      }
    ];
  };
}
