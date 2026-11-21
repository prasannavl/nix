{
  renderDevice ? "/dev/dri/zrender-default",
  drmDevices ? "/dev/dri/zcard-default",
}: {...}: {
  i18n.inputMethod.ibus.waylandFrontend = true;

  programs.sway = {
    enable = true;
    wrapperFeatures.gtk = true;
    extraOptions = ["--unsupported-gpu"];
    extraSessionCommands = ''
      export XDG_CURRENT_DESKTOP="sway"
      export XDG_SESSION_DESKTOP="sway"
      export DESKTOP_SESSION="sway"
      export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/gcr/ssh"
      export WLR_RENDER_DRM_DEVICE="${renderDevice}"
      export WLR_DRM_DEVICES="${drmDevices}"
    '';
  };
  programs.niri.enable = true;
}
