{
  ab,
  config,
  lib,
  ...
}: {
  imports = [
    (ab.system.profiles.mkWmModule {
      drmDevices =
        "/dev/dri/zcard-default"
        + lib.optionalString
        (builtins.elem config.networking.hostName ["pvl-a1" "pvl-l5"])
        ":/dev/dri/zcard-nvidia";
    })
  ];
}
