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
in {
  inherit mkCertDelegation mkGpuDevices mkIncusProxy;
}
