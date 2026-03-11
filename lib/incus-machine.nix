{
  hostName,
  tailscaleAuthKeyName ? hostName,
}: {
  config,
  lib,
  ...
}: let
  tailscaleAuthKeyAge =
    if tailscaleAuthKeyName == null || tailscaleAuthKeyName == ""
    then null
    else ../data/secrets + "/tailscale/${tailscaleAuthKeyName}.key.age";
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
  // lib.mkIf (tailscaleAuthKeyAge != null && builtins.pathExists tailscaleAuthKeyAge) {
    age.secrets.tailscale-auth-key = {
      file = builtins.toPath tailscaleAuthKeyAge;
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
