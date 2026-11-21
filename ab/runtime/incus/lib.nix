{
  lib,
  config ? null,
}: let
  defaultVideoGid =
    if config == null
    then null
    else config.users.groups.video.gid;
  defaultRenderGid =
    if config == null
    then null
    else config.users.groups.render.gid;

  mkUnixCharDevice = {
    source,
    path ? source,
    gid ? null,
    extraProperties ? {},
  }: {
    type = "unix-char";
    source = source;
    path = path;
    extraProperties =
      lib.optionalAttrs (gid != null) {
        gid = toString gid;
      }
      // extraProperties;
  };

  mkGpuDevices = {
    card ? null,
    render ? null,
    kfd ? false,
    videoGid ? defaultVideoGid,
    renderGid ? defaultRenderGid,
    cardName ?
      if card == null
      then null
      else "dev-dri-card-${toString card}",
    renderName ?
      if render == null
      then null
      else "dev-dri-render-${toString render}",
    kfdName ? "kfd",
  }:
    lib.optionalAttrs (card != null) {
      ${cardName} = mkUnixCharDevice {
        source = "/dev/dri/card${toString card}";
        gid = videoGid;
      };
    }
    // lib.optionalAttrs (render != null) {
      ${renderName} = mkUnixCharDevice {
        source = "/dev/dri/renderD${toString render}";
        gid = renderGid;
      };
    }
    // lib.optionalAttrs kfd {
      ${kfdName} = mkUnixCharDevice {
        source = "/dev/kfd";
        gid = renderGid;
      };
    };

  mkIncusProxy = {
    connectHost,
    listenHost ? "127.0.0.1",
    listenPort ? 8443,
    connectPort ? listenPort,
    bind ? "instance",
    extraProperties ? {},
  }: {
    type = "proxy";
    extraProperties =
      {
        inherit bind;
        listen = "tcp:${listenHost}:${toString listenPort}";
        connect = "tcp:${connectHost}:${toString connectPort}";
      }
      // extraProperties;
  };

  mkCertDelegation = name: {
    type = "disk";
    certDelegation = name;
  };

  mkLxc = {
    name,
    ipv4Address ? null,
    network ? null,
    image ? null,
    startPriority ? null,
    removalPolicy ? null,
    adopt ? null,
    recreateTag ? null,
    privileged ? false,
    nestedContainers ? false,
    interceptMounts ? false,
    interceptMountShift ? true,
    stateVolumeSize ? null,
    limits ? {},
    extraConfig ? {},
    extraDevices ? {},
  }:
    {
      name = name;
      limits = limits;
      config =
        {
          "security.privileged" =
            if privileged
            then "true"
            else "false";
          "security.syscalls.intercept.mknod" = "true";
          "security.syscalls.intercept.setxattr" = "true";
        }
        // lib.optionalAttrs nestedContainers {
          "security.nesting" = "true";
        }
        // lib.optionalAttrs interceptMounts {
          "security.syscalls.intercept.mount" = "true";
        }
        // lib.optionalAttrs (interceptMounts && interceptMountShift) {
          "security.syscalls.intercept.mount.shift" = "true";
        }
        // extraConfig;
      devices =
        {
          state = {
            source = name;
            path = "/var/lib";
            removalPolicy = "keep";
            extraProperties = lib.optionalAttrs (stateVolumeSize != null) {
              size = stateVolumeSize;
            };
          };
        }
        // lib.optionalAttrs nestedContainers {
          fuse = mkUnixCharDevice {
            source = "/dev/fuse";
          };
        }
        // extraDevices;
    }
    // lib.optionalAttrs (ipv4Address != null) {
      ipv4Address = ipv4Address;
    }
    // lib.optionalAttrs (network != null) {
      network = network;
    }
    // lib.optionalAttrs (image != null) {
      image = image;
    }
    // lib.optionalAttrs (startPriority != null) {
      startPriority = startPriority;
    }
    // lib.optionalAttrs (removalPolicy != null) {
      removalPolicy = removalPolicy;
    }
    // lib.optionalAttrs (adopt != null) {
      adopt = adopt;
    }
    // lib.optionalAttrs (recreateTag != null) {
      recreateTag = recreateTag;
    };

  certsForUsers = users: import ./certs.nix {users = users;};

  mkUserCertsForProjects = {
    users,
    root,
    projects,
    certPath,
    keyPath,
    pfxPath,
    extraKeyRecipients ? [],
    keyType ? "ecdsa-p256",
    days ? 3650,
  }: let
    certs = certsForUsers users;
  in
    certs.mkUserCertsForProjects {
      root = root;
      projects = projects;
      mkUserCert = {
        user,
        projects,
      }:
        certs.mkUserCertWithKeys {
          inherit days keyType projects user;
          cert = certPath user;
          inherit extraKeyRecipients;
          key = keyPath user;
          pfx = pfxPath user;
        };
    };
in {
  inherit certsForUsers mkCertDelegation mkGpuDevices mkIncusProxy mkLxc mkUserCertsForProjects;
  certs = import ./certs.nix;
}
