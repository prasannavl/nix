{
  hostName,
  tailscaleAuthKeyName ? hostName,
}: {
  config,
  lib,
  ...
}: let
  tailscaleAuthKeyAgeSource =
    if tailscaleAuthKeyName == null || tailscaleAuthKeyName == ""
    then null
    else ../data/secrets + "/tailscale/${tailscaleAuthKeyName}.key.age";
  tailscaleAuthKeyAge =
    if tailscaleAuthKeyAgeSource == null || !builtins.pathExists tailscaleAuthKeyAgeSource
    then null
    else builtins.path {
      path = tailscaleAuthKeyAgeSource;
      name = "tailscale-${tailscaleAuthKeyName}-auth-key.age";
    };
in
  {
    systemd.tmpfiles.rules = [
      "d /var/lib/machine 0700 root root -"
    ];

    services.openssh.hostKeys = [
      {
        path = "/var/lib/machine/ssh_host_ed25519_key";
        type = "ed25519";
      }
      {
        path = "/var/lib/machine/ssh_host_rsa_key";
        type = "rsa";
        bits = 4096;
      }
    ];
  }
  // lib.mkIf (tailscaleAuthKeyAge != null) {
    age.secrets.tailscale-auth-key = {
      file = tailscaleAuthKeyAge;
    };

    services.tailscale.authKeyFile = config.age.secrets.tailscale-auth-key.path;
    services.tailscale.authKeyParameters = {
      ephemeral = false;
      preauthorized = true;
    };
    services.tailscale.extraUpFlags = [
      "--advertise-tags=tag:vm"
    ];
  }
