{
  hostName,
  tailscaleKey ? hostName,
}: {
  config,
  lib,
  ...
}:
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
// (
  let
    k =
      if tailscaleKey == null || tailscaleKey == ""
      then null
      else ../data/secrets + "/tailscale/${tailscaleKey}.key.age";
  in
    lib.mkIf (k != null && builtins.pathExists k) {
      age.secrets.tailscale-auth-key = {
        file = builtins.path {
          path = k;
          name = "tailscale-${tailscaleKey}-auth-key.age";
        };
      };

      services.tailscale = {
        authKeyFile = config.age.secrets.tailscale-auth-key.path;
        authKeyParameters = {
          ephemeral = false;
          preauthorized = true;
        };
        extraUpFlags = [
          "--advertise-tags=tag:vm"
        ];
      };
    }
)
