{
  config,
  lib,
  ...
}: let
  inherit (config.networking) hostName;
  wlrDefaults = {
    renderDevice = "/dev/dri/zrender-default";
    drmDevices = "/dev/dri/zcard-default";
  };
  wlrByHost = {
    pvl-a1 = {
      drmDevices = "/dev/dri/zcard-default:/dev/dri/zcard-nvidia";
    };
    pvl-l5 = {
      drmDevices = "/dev/dri/zcard-default:/dev/dri/zcard-nvidia";
    };
  };
  wlrCfg = wlrDefaults // lib.attrByPath [hostName] {} wlrByHost;
in {
  programs.sway = {
    enable = true;
    wrapperFeatures.gtk = true;
    extraOptions = ["--unsupported-gpu"];
    extraSessionCommands = ''
      export XDG_CURRENT_DESKTOP="sway"
      export XDG_SESSION_DESKTOP="sway"
      export DESKTOP_SESSION="sway"
      export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/gcr/ssh"
      export WLR_RENDER_DRM_DEVICE="${wlrCfg.renderDevice}"
      export WLR_DRM_DEVICES="${wlrCfg.drmDevices}"
    '';
  };
  programs.niri.enable = true;
}
